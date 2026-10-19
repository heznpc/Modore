import CryptoKit
import Darwin
import Foundation

/// Bounded, descriptor-relative snapshots shared by native inventories and backups.
/// Hash encoding deliberately matches the existing Python manifests.
enum NativeFileTree {
    static let maximumBytes = 64 * 1024 * 1024
    static let maximumEntries = 10_000

    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func hash(_ text: String) -> String { hash(Data(text.utf8)) }
    static func fail(_ message: String) -> RetirementError { RetirementError(message) }
    static func metadata(_ path: URL) throws -> stat {
        var value = stat()
        guard lstat(path.path, &value) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return value
    }
    static func exists(_ path: URL) -> Bool { (try? metadata(path)) != nil }
    static func resolved(_ path: URL) throws -> URL {
        guard let result = realpath(path.path, nil) else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { free(result) }
        return URL(fileURLWithPath: String(cString: result))
    }
    static func link(_ path: URL) throws -> String {
        var bytes = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        let count = readlink(path.path, &bytes, bytes.count - 1)
        guard count >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return String(decoding: bytes.prefix(count).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
    static func stable(_ a: stat, _ b: stat) -> Bool {
        a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_mode == b.st_mode && a.st_size == b.st_size
            && a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec
            && a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec
    }
    static func read(_ path: URL, limit: Int = 2 * 1024 * 1024, nofollow: Bool = false) throws -> Data {
        let descriptor = open(path.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC | (nofollow ? O_NOFOLLOW : 0))
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(descriptor) }
        return try read(descriptor, limit: limit)
    }
    static func read(_ descriptor: Int32, limit: Int, expected: stat? = nil) throws -> Data {
        var before = stat()
        guard fstat(descriptor, &before) == 0, before.st_mode & S_IFMT == S_IFREG else { throw fail("일반 파일이 아닙니다.") }
        guard before.st_size >= 0, before.st_size <= limit else { throw fail("파일 읽기 크기 제한 초과") }
        if let expected, !stable(before, expected) { throw fail("읽는 중 파일이 바뀌었습니다.") }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = Darwin.read(descriptor, &buffer, min(buffer.count, limit - data.count + 1))
            if count == 0 { break }
            if count < 0 { if errno == EINTR { continue }; throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            data.append(contentsOf: buffer.prefix(count))
            guard data.count <= limit else { throw fail("파일 읽기 크기 제한 초과") }
        }
        var after = stat()
        guard fstat(descriptor, &after) == 0, stable(before, after) else { throw fail("읽는 중 파일이 바뀌었습니다.") }
        return data
    }
    static func pythonJSON(_ value: Any, sortedKeys: Bool = false) throws -> String {
        if let array = value as? [Any] { return "[" + (try array.map { try pythonJSON($0, sortedKeys: sortedKeys) }).joined(separator: ", ") + "]" }
        if let object = value as? [String: Any] {
            let keys = sortedKeys ? object.keys.sorted() : Array(object.keys)
            return "{" + (try keys.map { try pythonJSON($0) + ": " + pythonJSON(object[$0]!, sortedKeys: sortedKeys) }).joined(separator: ", ") + "}"
        }
        let encoded = try JSONSerialization.data(withJSONObject: [value], options: [.withoutEscapingSlashes, .fragmentsAllowed])
        return String(decoding: encoded.dropFirst().dropLast(), as: UTF8.self)
    }
    static func names(_ descriptor: Int32, limit: Int = 20_000) throws -> [String] {
        let duplicate = dup(descriptor)
        guard duplicate >= 0, let directory = fdopendir(duplicate) else {
            if duplicate >= 0 { close(duplicate) }; throw fail("폴더를 열지 못했습니다.")
        }
        defer { closedir(directory) }
        rewinddir(directory)
        var result: [String] = []
        while true {
            errno = 0
            guard let entry = readdir(directory) else {
                guard errno == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }; break
            }
            let decoded = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) { String(validatingCString: $0) }
            }
            guard let name = decoded else { throw fail("UTF-8로 확인할 수 없는 파일 이름이 있어 보존합니다.") }
            if name != "." && name != ".." {
                guard result.count < limit else { throw fail("폴더 항목 수 제한 초과") }
                result.append(name)
            }
        }
        return result.sorted()
    }
    static func directory(_ path: URL) throws -> Int32 {
        guard path.path.hasPrefix("/"), !path.pathComponents.contains("..") else { throw fail("이동 경로가 올바르지 않습니다.") }
        var descriptor = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw fail("상위 폴더를 열지 못했습니다.") }
        do {
            for part in path.pathComponents.dropFirst() {
                let child = openat(descriptor, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard child >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                close(descriptor); descriptor = child
            }
            return descriptor
        } catch { close(descriptor); throw error }
    }
    static func renameExclusive(_ source: URL, _ target: URL) throws {
        let sourceFD = try directory(source.deletingLastPathComponent())
        defer { close(sourceFD) }
        let targetFD = try directory(target.deletingLastPathComponent())
        defer { close(targetFD) }
        guard renameatx_np(sourceFD, source.lastPathComponent, targetFD, target.lastPathComponent, UInt32(RENAME_EXCL)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
    static func fingerprint(_ path: URL, follow: Bool = true) throws -> String {
        var entries: [[Any]] = [], bytes = 0, count = 0
        var ancestors = Set<String>()
        func visit(_ path: URL, _ name: String) throws {
            count += 1
            guard count <= maximumEntries else { throw fail("스킬 파일 수 제한 초과 (10,000개)") }
            let info = try metadata(path), mode = Int(info.st_mode & 0o7777)
            switch info.st_mode & S_IFMT {
            case S_IFLNK:
                entries.append([name, mode, "link", try link(path)])
                if follow { try visit(resolved(path), name + "/@target") }
            case S_IFDIR:
                let identity = "\(info.st_dev):\(info.st_ino)"
                guard ancestors.insert(identity).inserted else { throw fail("순환 링크가 있습니다.") }
                defer { ancestors.remove(identity) }
                let fd = open(path.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                defer { close(fd) }
                var before = stat(); guard fstat(fd, &before) == 0, stable(info, before) else { throw fail("폴더가 바뀌었습니다.") }
                entries.append([name, mode, "dir"])
                for child in try names(fd) { try visit(path.appendingPathComponent(child), name + "/" + child) }
                var after = stat(); guard fstat(fd, &after) == 0, stable(before, after) else { throw fail("폴더가 바뀌었습니다.") }
            case S_IFREG:
                let data = try read(path, limit: maximumBytes - bytes, nofollow: true)
                guard stable(info, try metadata(path)) else { throw fail("읽는 중 파일이 바뀌었습니다.") }
                bytes += data.count; entries.append([name, mode, "file", hash(data)])
            default: throw fail("일반 파일·폴더·링크가 아닌 항목입니다.")
            }
        }
        try visit(path, ".")
        return hash(try pythonJSON(entries))
    }
    static func copy(_ source: URL, to target: URL) throws {
        var bytes = 0, count = 0
        func visit(_ sourceFD: Int32, _ output: URL) throws {
            var before = stat(); guard fstat(sourceFD, &before) == 0 else { throw fail("원본 폴더를 확인하지 못했습니다.") }
            guard mkdir(output.path, 0o700) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            for name in try names(sourceFD) {
                count += 1
                guard count <= maximumEntries else { throw fail("스킬 파일 수 제한 초과 (10,000개)") }
                var info = stat()
                guard fstatat(sourceFD, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw fail("백업 중 파일이 바뀌었습니다.") }
                let kind = info.st_mode & S_IFMT
                guard kind != S_IFLNK else { throw fail("내부 심볼릭 링크가 있는 스킬은 안전한 복구를 지원하지 않습니다.") }
                guard kind == S_IFDIR || kind == S_IFREG else { throw fail("일반 파일·폴더가 아닌 스킬 항목입니다.") }
                let fd = openat(sourceFD, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC | (kind == S_IFDIR ? O_DIRECTORY : 0))
                guard fd >= 0 else { throw fail("백업 중 파일을 열지 못했습니다.") }
                defer { close(fd) }
                var opened = stat(); guard fstat(fd, &opened) == 0, stable(info, opened) else { throw fail("백업 중 파일이 바뀌었습니다.") }
                let destination = output.appendingPathComponent(name)
                if kind == S_IFDIR { try visit(fd, destination) }
                else {
                    let data = try read(fd, limit: maximumBytes - bytes, expected: info); bytes += data.count
                    let out = open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
                    guard out >= 0 else { throw fail("백업 파일을 만들지 못했습니다.") }
                    defer { close(out) }
                    try write(data, descriptor: out)
                    guard fchmod(out, info.st_mode & 0o7777) == 0 else { throw fail("백업 권한을 기록하지 못했습니다.") }
                    var times = [info.st_atimespec, info.st_mtimespec]
                    guard futimens(out, &times) == 0 else { throw fail("백업 시각을 기록하지 못했습니다.") }
                }
            }
            var after = stat(); guard fstat(sourceFD, &after) == 0, stable(before, after) else { throw fail("백업 중 폴더가 바뀌었습니다.") }
            guard chmod(output.path, before.st_mode & 0o7777) == 0 else { throw fail("백업 폴더 권한을 기록하지 못했습니다.") }
            var times = [before.st_atimespec, before.st_mtimespec]
            guard utimensat(AT_FDCWD, output.path, &times, AT_SYMLINK_NOFOLLOW) == 0 else { throw fail("백업 폴더 시각을 기록하지 못했습니다.") }
        }
        let fd = try directory(resolved(source)); defer { close(fd) }
        try visit(fd, target)
    }
    static func write(_ data: Data, descriptor: Int32) throws {
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0 { if errno == EINTR { continue }; throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                guard count > 0 else { throw fail("파일 쓰기가 중단되었습니다.") }; offset += count
            }
        }
        guard fsync(descriptor) == 0 else { throw fail("파일 저장을 확인하지 못했습니다.") }
    }
}
