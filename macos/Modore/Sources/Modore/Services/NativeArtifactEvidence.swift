import CryptoKit
import Darwin
import Foundation
import Security

enum NativeArtifactEvidence {
    struct Seal: Codable, Equatable { let digest: String; let bytes: Int64; let evidence: Bool }
    struct Entry { let path: String; let info: stat }
    struct Tree { let entries: [Entry]; let directories: [String: String]; let root: stat }
    static func safe(_ path: URL) throws -> URL {
        guard path.path.hasPrefix("/"), !path.pathComponents.contains(".."), try NativeFileTree.resolved(path).path == path.path else { throw NativeFileTree.fail("경로에 링크 또는 불명확한 구성요소가 있습니다.") }
        return path
    }
    static func owned(_ path: URL) throws -> stat {
        let info = try NativeFileTree.metadata(path)
        guard info.st_uid == geteuid(), info.st_mode & 0o022 == 0, info.st_mode & S_IFMT != S_IFLNK else { throw NativeFileTree.fail("생성물 소유권·권한을 확인하지 못했습니다.") }; return info
    }
    static func identity(_ path: URL) throws -> [Int64] { let s = try owned(path); return [Int64(s.st_dev), Int64(bitPattern: s.st_ino)] }
    static func asciiJSON(_ value: Any) throws -> String {
        try NativeFileTree.pythonJSON(value, sortedKeys: true).unicodeScalars.map { scalar -> String in
            if scalar.value < 128 { return String(scalar) }
            if scalar.value <= 0xffff { return String(format: "\\u%04x", scalar.value) }
            let code = scalar.value - 0x10000
            return String(format: "\\u%04x\\u%04x", 0xd800 + (code >> 10), 0xdc00 + (code & 0x3ff))
        }.joined()
    }
    static func applicationHash(_ path: URL) -> String? {
        var code: SecStaticCode?
        guard path.path.hasPrefix("/"), !path.path.utf8.contains(0), SecStaticCodeCreateWithPath(path as CFURL, SecCSFlags(), &code) == errSecSuccess, let code else { return nil }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate)
        guard SecStaticCodeCheckValidity(code, flags, nil) == errSecSuccess else { return nil }
        var dictionary: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &dictionary) == errSecSuccess,
              let values = dictionary as? [String: Any], values[kSecCodeInfoIdentifier as String] as? String == "me.heznpc.modore",
              let digest = values[kSecCodeInfoUnique as String] as? Data else { return nil }
        return digest.map { String(format: "%02x", $0) }.joined()
    }
    static func processIdentity(_ pid: Int32) -> String? {
        guard let value = try? NativeCommand.run("/bin/ps", ["-p", String(pid), "-o", "lstart="], timeout: 5, limit: 8192,
            environment: ["LC_ALL": "C", "LANG": "C"]), value.status == 0 else { return nil }
        let text = value.text.trimmingCharacters(in: .whitespacesAndNewlines); return text.isEmpty ? nil : text
    }
    static func usage() -> [String]? {
        guard let value = try? NativeCommand.run("/usr/sbin/lsof", ["-nP", "-a", "-u", String(geteuid()), "-F0pn"], timeout: 20),
              [0, 1].contains(value.status), value.errorText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value.output.split(separator: 0).compactMap { bytes in
            guard bytes.first == 110 else { return nil }
            let path = String(decoding: bytes.dropFirst(), as: UTF8.self); return path.hasPrefix("/") ? path : nil
        }
    }
    static func fileHash(_ path: URL) throws -> String {
        _ = try safe(path)
        let fd = open(path.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw NativeFileTree.fail("해시 파일을 열지 못했습니다.") }; defer { close(fd) }
        let before = try info(fd); guard before.st_mode & S_IFMT == S_IFREG else { throw NativeFileTree.fail("일반 파일이 아닙니다.") }
        var digest = SHA256(); try stream(fd, deadline: ProcessInfo.processInfo.systemUptime + 120) { digest.update(data: $0) }
        guard NativeFileTree.stable(before, try info(fd)), NativeFileTree.stable(before, try NativeFileTree.metadata(path)) else { throw NativeFileTree.fail("파일이 바뀌었습니다.") }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
    private static func info(_ fd: Int32) throws -> stat {
        var s = stat(); guard fstat(fd, &s) == 0 else { throw NativeFileTree.fail("생성물 식별 확인 실패") }; return s
    }
    private static func stream(_ fd: Int32, deadline: TimeInterval, consume: (Data) throws -> Void) throws {
        var bytes = [UInt8](repeating: 0, count: 1024 * 1024)
        while true {
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw NativeFileTree.fail("생성물 검증 시간 초과 · 보존") }
            let count = Darwin.read(fd, &bytes, bytes.count)
            if count == 0 { break }
            if count < 0 { if errno == EINTR { continue }; throw NativeFileTree.fail("생성물 읽기 실패") }
            try consume(Data(bytes.prefix(count)))
        }
    }
    static func inventory(_ rootFD: Int32, initial: stat, deadline: TimeInterval) throws -> Tree {
        var entries = [Entry(path: ".", info: initial)], directories: [String: String] = [:]
        func walk(_ fd: Int32, _ prefix: String, _ depth: Int) throws {
            guard depth <= 96, ProcessInfo.processInfo.systemUptime < deadline else { throw NativeFileTree.fail("생성물 탐색 제한 초과 · 보존") }
            for name in try NativeFileTree.names(fd) {
                let path = prefix.isEmpty ? name : prefix + "/" + name
                var s = stat(); guard fstatat(fd, name, &s, AT_SYMLINK_NOFOLLOW) == 0, s.st_dev == initial.st_dev, s.st_uid == geteuid() else { throw NativeFileTree.fail("생성물 범위·식별 변경") }
                entries.append(Entry(path: path, info: s))
                guard entries.count <= 200_000 else { throw NativeFileTree.fail("생성물 항목 수 제한 초과 · 보존") }
                if s.st_mode & S_IFMT == S_IFDIR {
                    let child = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    guard child >= 0 else { throw NativeFileTree.fail("생성물 폴더가 바뀌었습니다.") }; defer { close(child) }
                    guard NativeFileTree.stable(s, try info(child)) else { throw NativeFileTree.fail("생성물 폴더 식별 변경") }
                    directories[path] = NativeSessionBackup.identity(s); try walk(child, path, depth + 1)
                }
            }
        }
        if initial.st_mode & S_IFMT == S_IFDIR { try walk(rootFD, "", 0) }
        return Tree(entries: entries, directories: directories, root: initial)
    }
    static func seal(_ path: URL) throws -> Seal {
        _ = try safe(path); let initial = try owned(path), deadline = ProcessInfo.processInfo.systemUptime + 120
        let root = open(path.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC | (initial.st_mode & S_IFMT == S_IFDIR ? O_DIRECTORY : 0))
        guard root >= 0 else { throw NativeFileTree.fail("생성물을 열지 못했습니다.") }; defer { close(root) }
        guard NativeFileTree.stable(initial, try info(root)) else { throw NativeFileTree.fail("생성물 식별 변경") }
        let tree = try inventory(root, initial: initial, deadline: deadline)
        var directories = tree.directories, digest = SHA256(), bytes: Int64 = 0, evidence = false
        let sorted = tree.entries.sorted {
            if $0.path == "." { return $1.path != "." }; if $1.path == "." { return false }
            return $0.path.unicodeScalars.lexicographicallyPrecedes($1.path.unicodeScalars)
        }
        for entry in sorted {
            let s = entry.info, suffix = (entry.path == "." ? path : URL(fileURLWithPath: entry.path)).pathExtension
            evidence = evidence || ["xcresult", "logarchive", "trace", "mov", "mp4", "log"].contains(suffix)
            let (seconds, overflow) = Int64(s.st_mtimespec.tv_sec).multipliedReportingOverflow(by: 1_000_000_000)
            let (nanos, addedOverflow) = seconds.addingReportingOverflow(Int64(s.st_mtimespec.tv_nsec))
            guard !overflow, !addedOverflow else { throw NativeFileTree.fail("생성물 시각 범위 확인 실패") }
            digest.update(data: Data(try asciiJSON([entry.path, Int(s.st_mode), s.st_size, nanos]).utf8))
            let parent: Int32, name: String
            if entry.path == "." { parent = -1; name = "" }
            else { (parent, name) = try NativeSessionBackup.openParent(root, path: entry.path, directories: &directories, record: false) }
            defer { if parent >= 0 { close(parent) } }
            switch s.st_mode & S_IFMT {
            case S_IFLNK:
                var target = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
                let count = readlinkat(parent, name, &target, target.count)
                guard count > 0, count < target.count else { throw NativeFileTree.fail("생성물 링크 읽기 실패") }
                digest.update(data: Data(target.prefix(count).map { UInt8(bitPattern: $0) }))
            case S_IFREG:
                guard s.st_nlink == 1 else { throw NativeFileTree.fail("공유 하드링크가 있어 보존합니다.") }
                let fd = entry.path == "." ? dup(root) : openat(parent, name, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
                guard fd >= 0 else { throw NativeFileTree.fail("생성물 파일 열기 실패") }; defer { close(fd) }
                guard NativeFileTree.stable(s, try info(fd)) else { throw NativeFileTree.fail("생성물 파일 식별 변경") }
                try stream(fd, deadline: deadline) { digest.update(data: $0) }
                guard NativeFileTree.stable(s, try info(fd)) else { throw NativeFileTree.fail("생성물 내용 변경") }
                bytes += Int64(s.st_blocks) * 512
            case S_IFDIR: break
            default: throw NativeFileTree.fail("특수 파일이 있어 보존합니다.")
            }
        }
        // Rewalk every entry after hashing, not only the root directory.
        let after = try inventory(root, initial: info(root), deadline: deadline)
        let old = Dictionary(uniqueKeysWithValues: tree.entries.map { ($0.path, $0.info) })
        guard after.entries.count == old.count, after.entries.allSatisfy({ entry in old[entry.path].map { NativeFileTree.stable($0, entry.info) } ?? false }),
              NativeFileTree.stable(initial, try NativeFileTree.metadata(path)) else { throw NativeFileTree.fail("검증 중 생성물이 바뀌었습니다.") }
        return Seal(digest: digest.finalize().map { String(format: "%02x", $0) }.joined(), bytes: bytes, evidence: evidence)
    }
}
