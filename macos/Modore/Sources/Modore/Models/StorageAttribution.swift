import Darwin
import Foundation

/// Metadata evidence only. File ages are candidates, never measured growth or reclaimable bytes.
enum StorageAttribution {
    struct Identity: Codable, Hashable { let device: Int32; let inode: UInt64 }
    struct Candidate: Codable { let path: String; var createdBytes: Int64 = 0; var modifiedBytes: Int64 = 0 }
    struct Row: Codable {
        let label: String
        let path: String
        var allocatedBytes: Int64 = 0
        var createdBytes: Int64 = 0
        var modifiedBytes: Int64 = 0
        var files = 0
        var errors = 0
        var complete = true
        var status = "measured"
        var candidates: [Candidate] = []
        var previousMeasuredAt: String?
        var recentDeltaBytes: Int64?
        var measuredAt: String?
        var baselineBytes: Int64?
        var measuredDeltaBytes: Int64?
    }
    struct Request: Codable {
        let label: String
        let path: String
        let since: TimeInterval
        let now: TimeInterval
        let seen: Set<Identity>
    }
    struct Response: Codable { var row: Row; let identities: Set<Identity> }
    struct Report: Codable {
        var version = 1
        let capturedAt: String
        let scanStartedAt: String
        let since: String
        let baselineFreeBytes: Int64?
        let freeBytes: Int64
        let freeDropBytes: Int64?
        let rows: [Row]
        var coverage = "선택한 경로의 파일 메타데이터 측정. 심볼릭 링크·다른 볼륨은 제외. 접근 실패는 항목별 표시."
        var interpretation = "생성 후 남은 파일의 현재 할당량은 증가 원인 후보입니다. 수정된 기존 파일의 크기는 증가량이 아닙니다. APFS 공유 블록·삭제·동시 쓰기 때문에 합계를 여유 공간 감소량이나 회수 가능량으로 간주하지 않습니다."
    }
    struct Measurement { let at: TimeInterval; let bytes: Int64 }

    static func timestamp(_ value: String) -> TimeInterval? {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = parser.date(from: value) { return date.timeIntervalSince1970 }
        parser.formatOptions = [.withInternetDateTime]
        return parser.date(from: value)?.timeIntervalSince1970
    }
    static func iso(_ value: TimeInterval) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date(timeIntervalSince1970: value))
    }

    static func roots(home: URL) -> [(String, String)] {
        let entries = [
            ("Codex 대화·실행 데이터", ".codex"), ("Claude 데이터", ".claude"),
            ("문서·AI 작업 결과", "Documents"), ("개발 프로젝트", "IdeaProjects"),
            ("시뮬레이터 기기", "Library/Developer/CoreSimulator/Devices"),
            ("시뮬레이터 런타임", "/System/Library/AssetsV2/com_apple_MobileAsset_iOSSimulatorRuntime"),
            ("시뮬레이터 공유 캐시", "/Library/Developer/CoreSimulator/Caches/dyld"),
            ("Xcode 데이터", "Library/Developer/Xcode"), ("npm 캐시", ".npm"),
            ("개발 실행환경", ".local"), ("추가 캐시", ".cache"), ("사용자 캐시", "Library/Caches"),
            ("앱 지원 데이터", "Library/Application Support"), ("메시지 데이터", "Library/Messages"),
            ("다운로드", "Downloads"), ("설치 앱", "/Applications"), ("Homebrew", "/opt/homebrew"),
            ("임시 빌드", "/private/tmp"), ("시스템 임시 데이터", "/private/var/folders"),
            ("스왑 볼륨", "/System/Volumes/VM"), ("절전 이미지", "/private/var/vm")]
        return entries.map { ($0.0, $0.1.hasPrefix("/") ? $0.1 : home.appendingPathComponent($0.1).path) }
    }

    /// Runs in a killable worker: a blocked filesystem syscall must not hold the application open.
    /// O_NOFOLLOW and descriptor-relative traversal also protect against directory replacement races.
    static func scan(_ request: Request) -> Response {
        var row = Row(label: request.label, path: request.path)
        var seen = request.seen
        var buckets: [String: Candidate] = [:]
        var root = stat()
        guard lstat(request.path, &root) == 0 else {
            let missing = errno == ENOENT
            row.status = missing ? "missing" : "inaccessible"
            row.complete = missing; row.errors = missing ? 0 : 1
            return Response(row: row, identities: [])
        }
        func visit(_ parent: Int32, _ name: String, _ relative: [String]) {
            var metadata = stat()
            guard fstatat(parent, name, &metadata, AT_SYMLINK_NOFOLLOW) == 0 else { row.errors += 1; return }
            guard metadata.st_dev == root.st_dev else { return }
            let kind = metadata.st_mode & S_IFMT
            if kind == S_IFDIR {
                let descriptor = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard descriptor >= 0 else { row.errors += 1; return }
                var opened = stat()
                guard fstat(descriptor, &opened) == 0, opened.st_dev == metadata.st_dev,
                      opened.st_ino == metadata.st_ino else { close(descriptor); row.errors += 1; return }
                guard let directory = fdopendir(descriptor) else { close(descriptor); row.errors += 1; return }
                defer { closedir(directory) }
                row.allocatedBytes += Int64(opened.st_blocks) * 512
                while true {
                    errno = 0
                    guard let entry = readdir(directory) else {
                        if errno != 0 { row.errors += 1 }
                        break
                    }
                    let child = withUnsafePointer(to: &entry.pointee.d_name) {
                        $0.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) { String(cString: $0) }
                    }
                    if child != "." && child != ".." { visit(descriptor, child, relative + [child]) }
                }
            } else if kind == S_IFREG {
                if metadata.st_nlink > 1 {
                    let identity = Identity(device: metadata.st_dev, inode: metadata.st_ino)
                    guard seen.insert(identity).inserted else { return }
                }
                let bytes = Int64(metadata.st_blocks) * 512
                row.allocatedBytes += bytes; row.files += 1
                let birth = Double(metadata.st_birthtimespec.tv_sec) + Double(metadata.st_birthtimespec.tv_nsec) / 1e9
                let modified = Double(metadata.st_mtimespec.tv_sec) + Double(metadata.st_mtimespec.tv_nsec) / 1e9
                let created = request.since <= birth && birth <= request.now
                let changed = request.since <= modified && modified <= request.now
                if created { row.createdBytes += bytes } else if changed { row.modifiedBytes += bytes }
                if created || changed {
                    let prefix = relative.prefix(min(2, max(1, relative.count - 1)))
                    let path = prefix.reduce(URL(fileURLWithPath: request.path)) { $0.appendingPathComponent($1) }.path
                    var bucket = buckets[path] ?? Candidate(path: path)
                    if created { bucket.createdBytes += bytes } else { bucket.modifiedBytes += bytes }
                    buckets[path] = bucket
                }
            }
        }
        visit(AT_FDCWD, request.path, [])
        row.complete = row.errors == 0
        row.status = row.complete ? "measured" : "partial"
        row.candidates = buckets.values.sorted {
            let a = $0.createdBytes + $0.modifiedBytes, b = $1.createdBytes + $1.modifiedBytes
            return a == b ? $0.path < $1.path : a > b
        }
        return Response(row: row, identities: seen.subtracting(request.seen))
    }

    static func baseline(text: String, since: TimeInterval?, now: TimeInterval) -> (TimeInterval, Int64?) {
        let samples: [Measurement] = text.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count >= 2, let at = timestamp(String(fields[0])),
                  let kb = Int64(fields[1]), kb >= 0, kb <= Int64.max / 1024,
                  now - 30 * 86400 <= at, at <= now else { return nil }
            return Measurement(at: at, bytes: kb * 1024)
        }
        if let since {
            return (since, samples.filter { abs($0.at - since) <= 300 }
                .min { abs($0.at - since) < abs($1.at - since) }?.bytes)
        }
        let peak = samples.max { $0.bytes == $1.bytes ? $0.at < $1.at : $0.bytes < $1.bytes }
        return (peak?.at ?? now - 7 * 86400, peak?.bytes)
    }

    static func pastMeasurements(state: URL, since: TimeInterval, maxAge: TimeInterval = 300) -> [String: Measurement] {
        var found: [String: Measurement] = [:]
        func add(_ path: String, _ at: TimeInterval, _ bytes: Int64) {
            guard since - maxAge <= at, at <= since, bytes >= 0 else { return }
            let key = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
            if found[key] == nil || at > found[key]!.at { found[key] = Measurement(at: at, bytes: bytes) }
        }
        let files = (try? FileManager.default.contentsOfDirectory(at: state, includingPropertiesForKeys: nil)) ?? []
        for file in files.sorted(by: { $0.path < $1.path }) where file.lastPathComponent.hasPrefix("storage-evidence-") && file.pathExtension == "tsv" {
            guard let data = try? SecureLocalFileIO.boundedRead(from: file, maximumBytes: 8_000_000, requireCurrentOwner: true),
                  let text = String(data: data, encoding: .utf8) else { continue }
            for line in text.split(whereSeparator: \.isNewline) {
                let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
                guard fields.count >= 6, fields[0] == "path", fields[3] == "ok",
                      let at = timestamp(String(fields[1])), let kb = Int64(fields[2]),
                      kb >= 0, kb <= Int64.max / 1024 else { continue }
                add(String(fields[5]), at, kb * 1024)
            }
        }
        let history = (try? FileManager.default.contentsOfDirectory(at: state.appendingPathComponent("storage-explanations"), includingPropertiesForKeys: nil)) ?? []
        for file in history.sorted(by: { $0.path < $1.path }) where file.pathExtension == "json" {
            guard let data = try? SecureLocalFileIO.boundedRead(from: file, maximumBytes: 8_000_000, requireCurrentOwner: true),
                  let report = try? JSONDecoder().decode(Report.self, from: data),
                  let at = timestamp(report.capturedAt) else { continue }
            for row in report.rows where row.complete { add(row.path, at, row.allocatedBytes) }
        }
        return found
    }
}
