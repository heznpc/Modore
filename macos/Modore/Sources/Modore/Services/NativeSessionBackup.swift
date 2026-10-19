import CryptoKit
import Darwin
import Foundation
import ZIPFoundation

/// Original session backups keep the existing version-1 ZIP format.
/// All archive payload names are data, never paths passed to a ZIP extraction API.
enum NativeSessionBackup {
    static let maximumBytes: Int64 = 2 * 1024 * 1024 * 1024
    static let maximumFiles = 10_000
    static let maximumDirectories = 192
    static let manifestLimit = 4 * 1024 * 1024
    static let desktopPrefix = "Library/Application Support/Claude/local-agent-mode-sessions/"
    struct File: Codable, Equatable {
        let path: String
        let size: Int64
        let sha256: String
        let category: String
        var kind: String?
        var isLink: Bool { kind == "symlink" }
    }
    struct Manifest: Codable, Equatable {
        let schemaVersion: Int
        let provider: String
        let scope: String?
        let sourceRelative: String
        let createdAt: String?
        var files: [File]
    }
    struct Scope {
        let provider: String
        let name: String
        let roots: [String]
    }
    struct Source {
        let path: String
        let metadata: stat
        let link: Bool
    }
    struct Inventory {
        var files: [Source] = []
        var directories: [String: String] = [:]
    }
    static func check() throws { try NativeBackupCancellation.shared.check() }
    static func failure(_ text: String) -> RetirementError { NativeFileTree.fail(text) }
    static func identity(_ info: stat) -> String { "\(info.st_dev):\(info.st_ino)" }
    static func relative(_ path: String) throws -> [String] {
        let parts = path.components(separatedBy: "/")
        guard !path.isEmpty, !path.contains("\\"), !path.utf8.contains(0), parts.count <= 128,
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.utf16.count <= 255 }) else { throw failure("unsafe archive path") }
        return parts
    }
    static func scope(_ source: String) throws -> Scope {
        let parts = try relative(source), url = URL(fileURLWithPath: source)
        if parts.count == 4, parts[0] == ".claude", parts[1] == "projects", url.pathExtension == "jsonl" {
            let session = url.deletingPathExtension().lastPathComponent, parent = parts.dropLast().joined(separator: "/")
            return Scope(provider: "Claude", name: "claude-code-session", roots:
                [parent + "/" + session + "/subagents", parent + "/" + session + "/tool-results"]
                    + ["file-history", "image-cache", "uploads"].map { ".claude/" + $0 + "/" + session })
        }
        if parts.count >= 3, parts[0] == ".codex", ["sessions", "archived_sessions"].contains(parts[1]), url.pathExtension == "jsonl" {
            return Scope(provider: "Codex", name: "codex-session", roots: [])
        }
        if source.hasPrefix(desktopPrefix), parts.count >= 7, url.pathExtension == "json",
           url.deletingPathExtension().lastPathComponent.range(of: "^local_[A-Za-z0-9_-]+$", options: .regularExpression) != nil {
            return Scope(provider: "Claude Desktop", name: "claude-desktop-conversation-unit", roots: [String(source.dropLast(5))])
        }
        throw failure("only Claude projects, Claude Desktop conversation units, and Codex session stores are supported")
    }
    static func category(_ scope: Scope, source: String, path: String) -> String {
        if scope.provider == "Claude Desktop" {
            if path == source { return "metadata" }
            let inside = String(path.dropFirst(scope.roots[0].count + 1)), parts = inside.split(separator: "/")
            if inside == "audit.jsonl" { return "audit" }
            if parts.contains("subagents") { return "subagents" }
            if parts.contains("sessions"), path.hasSuffix(".jsonl") { return "queue" }
            if path.hasSuffix(".jsonl") { return "transcript" }
            if parts.first == "uploads" { return "uploads" }
            if parts.first == "outputs" { return "outputs" }
            return "sidecar"
        }
        if path == source { return "transcript" }
        for (index, root) in scope.roots.enumerated() where path == root || path.hasPrefix(root + "/") {
            return ["subagents", "tool-results", "file-history", "image-cache", "uploads"][index]
        }
        return "sidecar"
    }
    static func openParent(_ root: Int32, path: String, directories: inout [String: String], record: Bool) throws -> (Int32, String) {
        let parts = try relative(path)
        var fd = dup(root), prefix: [String] = []
        guard fd >= 0 else { throw failure("cannot open backup root") }
        do {
            for part in parts.dropLast() {
                prefix.append(part)
                let child = openat(fd, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard child >= 0 else {
                    if errno == ENOENT { throw POSIXError(.ENOENT) }
                    throw failure("symlinks or unreadable session directories are not supported")
                }
                var info = stat(); guard fstat(child, &info) == 0 else { close(child); throw failure("cannot inspect session directory") }
                let key = prefix.joined(separator: "/"), id = identity(info)
                if let expected = directories[key] { guard expected == id else { close(child); throw failure("session path changed during backup") } }
                else if record { directories[key] = id }
                else { close(child); throw failure("session directory was not inventoried") }
                close(fd); fd = child
            }
            return (fd, parts.last!)
        } catch { close(fd); throw error }
    }
    static func inventory(homeFD: Int32, source: String) throws -> Inventory {
        let scope = try scope(source)
        var result = Inventory(), sourceDevice: dev_t?, total: Int64 = 0
        func add(_ path: String, allowLink: Bool = false) throws {
            let (parent, name) = try openParent(homeFD, path: path, directories: &result.directories, record: true)
            defer { close(parent) }
            var info = stat()
            guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw failure("session source changed or is unreadable") }
            let kind = info.st_mode & S_IFMT
            guard kind == S_IFREG || (allowLink && kind == S_IFLNK), info.st_uid == geteuid(), info.st_nlink == 1 else { throw failure("session backups require owned regular files or supported leaf links") }
            if sourceDevice == nil { sourceDevice = info.st_dev }
            guard info.st_dev == sourceDevice, info.st_size >= 0, info.st_size <= maximumBytes - total else { throw failure("session scope exceeds size or filesystem limits") }
            total += info.st_size
            result.files.append(Source(path: path, metadata: info, link: kind == S_IFLNK))
            guard result.files.count <= maximumFiles else { throw failure("session backup has too many files") }
        }
        func walk(_ path: String) throws {
            try check()
            let openedParent: (Int32, String)
            do { openedParent = try openParent(homeFD, path: path, directories: &result.directories, record: true) }
            catch let error as POSIXError where error.code == .ENOENT { return }
            let (parent, name) = openedParent
            defer { close(parent) }
            let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if fd < 0, errno == ENOENT { return }
            guard fd >= 0 else { throw failure("session sidecar directory is unreadable or a link") }
            defer { close(fd) }
            var info = stat(); guard fstat(fd, &info) == 0, info.st_dev == sourceDevice else { throw failure("session scope crosses a filesystem boundary") }
            result.directories[path] = identity(info)
            guard result.directories.count <= maximumFiles else { throw failure("session backup has too many directories") }
            for child in try NativeFileTree.names(fd) {
                let childPath = path + "/" + child
                _ = try relative(childPath)
                var metadata = stat()
                guard fstatat(fd, child, &metadata, AT_SYMLINK_NOFOLLOW) == 0 else { throw failure("session files changed during inventory") }
                if metadata.st_mode & S_IFMT == S_IFDIR { try walk(childPath) }
                else { try add(childPath, allowLink: scope.provider == "Claude Desktop") }
            }
        }
        try add(source)
        for root in scope.roots { try walk(root) }
        guard result.directories.values.allSatisfy({ $0.hasPrefix("\(sourceDevice!):") }) else {
            throw failure("session scope crosses a filesystem boundary")
        }
        result.files.sort { $0.path < $1.path }
        var restoreDirectories = Set<String>()
        for file in result.files {
            let parts = try relative(file.path)
            for count in 1..<parts.count { restoreDirectories.insert(parts.prefix(count).joined(separator: "/")) }
        }
        guard restoreDirectories.count <= maximumDirectories else { throw failure("backup has too many restore directories") }
        return result
    }
    @discardableResult static func streamSource(_ entry: Source, homeFD: Int32, directories: [String: String],
                                               consumer: ((Data) throws -> Void)? = nil) throws -> (Int64, String) {
        var directories = directories
        let (parent, name) = try openParent(homeFD, path: entry.path, directories: &directories, record: false)
        defer { close(parent) }
        var before = stat()
        guard fstatat(parent, name, &before, AT_SYMLINK_NOFOLLOW) == 0, NativeFileTree.stable(entry.metadata, before) else { throw failure("session files changed during backup") }
        if entry.link {
            var bytes = [CChar](repeating: 0, count: 1024)
            let count = readlinkat(parent, name, &bytes, bytes.count)
            guard count > 0, count <= 1023 else { throw failure("backup symlink target is invalid") }
            let data = Data(bytes.prefix(count).map { UInt8(bitPattern: $0) })
            guard !data.contains(0), String(data: data, encoding: .utf8) != nil else { throw failure("backup symlink target is invalid") }
            var after = stat(); guard fstatat(parent, name, &after, AT_SYMLINK_NOFOLLOW) == 0, NativeFileTree.stable(before, after) else { throw failure("session link changed during backup") }
            try consumer?(data); return (Int64(data.count), NativeFileTree.hash(data))
        }
        let fd = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw failure("session file is unreadable") }
        defer { close(fd) }
        var opened = stat(); guard fstat(fd, &opened) == 0, NativeFileTree.stable(before, opened) else { throw failure("session file changed during backup") }
        var size: Int64 = 0, digest = SHA256(), buffer = [UInt8](repeating: 0, count: 1024 * 1024)
        while true {
            try check()
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count == 0 { break }
            if count < 0 { if errno == EINTR { continue }; throw failure("session file read failed") }
            size += Int64(count)
            guard size <= entry.metadata.st_size else { throw failure("session file grew during backup") }
            let data = Data(buffer.prefix(count)); digest.update(data: data); try consumer?(data)
        }
        var after = stat(), named = stat()
        guard fstat(fd, &after) == 0, fstatat(parent, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
              NativeFileTree.stable(before, after), NativeFileTree.stable(before, named), size == before.st_size else { throw failure("session file changed during backup") }
        return (size, digest.finalize().map { String(format: "%02x", $0) }.joined())
    }
    static func result(archive: URL, manifest: Manifest, restored: URL? = nil) throws -> [String: Any] {
        let scope = try scope(manifest.sourceRelative)
        return ["schemaVersion": 1, "status": restored == nil ? "verified" : "restored", "archive": archive.path,
            "provider": manifest.provider, "scope": manifest.scope ?? scope.name, "sourceRelative": manifest.sourceRelative,
            "fileCount": manifest.files.count, "totalBytes": manifest.files.reduce(Int64(0)) { $0 + $1.size },
            "categories": Set(manifest.files.map(\.category)).sorted(),
            "excluded": manifest.provider == "Claude Desktop" ? ["other-conversation-units", "external-referenced-files"]
                : ["workspace-code", "project-memory", "settings-and-credentials", "other-sessions", "external-referenced-files"],
            "masked": false, "encrypted": false, "restoredRoot": restored?.path as Any? ?? NSNull(),
            "restoredSource": restored?.appendingPathComponent(manifest.sourceRelative).path as Any? ?? NSNull()]
    }
    static func validateDesktop(_ data: Data, manifest: Manifest) throws {
        guard data.count <= manifestLimit,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw failure("invalid Claude Desktop conversation metadata") }
        let sourceName = URL(fileURLWithPath: manifest.sourceRelative).deletingPathExtension().lastPathComponent
        guard object["sessionId"] as? String == sourceName, sourceName.count <= 256,
              let cli = object["cliSessionId"] as? String, cli.count <= 256,
              cli.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil,
              let cwd = object["cwd"] as? String, !cwd.isEmpty, cwd.count <= 4096,
              let selected = object["userSelectedFolders"] as? [String], selected.count <= 64,
              selected.allSatisfy({ !$0.isEmpty && $0.count <= 4096 }) else { throw failure("invalid Claude Desktop conversation metadata") }
        for key in ["createdAt", "lastActivityAt"] {
            guard let number = object[key] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue >= 0, number.doubleValue <= 4_102_444_800_000,
                  number.doubleValue.rounded(.towardZero) == number.doubleValue else { throw failure("invalid Claude Desktop conversation timestamp") }
        }
        if let title = object["title"], !(title is NSNull) {
            guard let title = title as? String, title.count <= 4096 else { throw failure("invalid Claude Desktop conversation title") }
        }
        let root = String(manifest.sourceRelative.dropLast(5)) + "/"
        guard manifest.files.filter({ !$0.isLink && $0.path.hasPrefix(root) && URL(fileURLWithPath: $0.path).lastPathComponent == cli + ".jsonl" }).count == 1 else { throw failure("Claude Desktop backup has no unique primary transcript") }
    }
    static func readEntry(_ entry: Entry, archive: Archive, limit: Int64, consumer: ((Data) throws -> Void)? = nil) throws -> (Int64, String) {
        var size: Int64 = 0, digest = SHA256()
        let crc = try archive.extract(entry, bufferSize: 1024 * 1024) { data in
            try check(); size += Int64(data.count)
            guard size <= limit else { throw failure("session backup exceeds the size limit") }
            digest.update(data: data); try consumer?(data)
        }
        guard crc == entry.checksum else { throw failure("backup ZIP checksum mismatch") }
        return (size, digest.finalize().map { String(format: "%02x", $0) }.joined())
    }
    static func entryCount(_ fd: Int32) throws -> Int {
        // ZIPFoundation's iterator stops on an unsupported/encrypted entry. Check
        // the complete directory count independently so hidden tails cannot pass verification.
        var info = stat(); guard fstat(fd, &info) == 0, info.st_size >= 22 else { throw failure("invalid backup ZIP") }
        let size = min(Int64(65_557), info.st_size), offset = info.st_size - size
        var bytes = [UInt8](repeating: 0, count: Int(size))
        guard pread(fd, &bytes, bytes.count, offset) == bytes.count else { throw failure("invalid backup ZIP") }
        func word(_ i: Int) -> Int { Int(bytes[i]) | Int(bytes[i + 1]) << 8 }
        for i in stride(from: bytes.count - 22, through: 0, by: -1) where Array(bytes[i..<i+4]) == [0x50, 0x4b, 0x05, 0x06] {
            guard i + 22 + word(i + 20) == bytes.count else { continue }
            let count = word(i + 10)
            guard word(i + 4) == 0, word(i + 6) == 0, word(i + 8) == count, count > 0, count <= maximumFiles + 1 else { throw failure("invalid archive file count or volume") }
            return count
        }
        throw failure("invalid backup ZIP directory")
    }
    static func verify(fd: Int32) throws -> Manifest {
        var before = stat(); guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG else { throw failure("backup must be a regular file") }
        let count = try entryCount(fd), archive = try Archive(url: URL(fileURLWithPath: "/dev/fd/\(fd)"), accessMode: .read)
        var entries: [String: Entry] = [:]
        for entry in archive {
            _ = try relative(entry.path)
            guard entry.type == .file, entries[entry.path] == nil, entries.count < maximumFiles + 1,
                  entry.uncompressedSize <= maximumBytes else { throw failure("unsupported or duplicate archive entry") }
            entries[entry.path] = entry
        }
        guard entries.count == count, let manifestEntry = entries["manifest.json"], manifestEntry.uncompressedSize <= manifestLimit else { throw failure("missing backup manifest or unsupported archive entries") }
        var data = Data()
        _ = try readEntry(manifestEntry, archive: archive, limit: Int64(manifestLimit)) { data.append($0) }
        let manifest = try JSONDecoder().decode(Manifest.self, from: data), scope = try scope(manifest.sourceRelative)
        guard manifest.schemaVersion == 1, manifest.provider == scope.provider, (manifest.scope ?? scope.name) == scope.name,
              !manifest.files.isEmpty, manifest.files.count <= maximumFiles else { throw failure("unsupported backup manifest") }
        var expected: Set<String> = ["manifest.json"], paths = Set<String>(), ancestors = Set<String>(), directories = Set<String>(), total: Int64 = 0
        for file in manifest.files {
            let parts = try relative(file.path)
            guard file.path == manifest.sourceRelative || scope.roots.contains(where: { file.path.hasPrefix($0 + "/") }) else { throw failure("backup entry is outside this session's scope") }
            let parents = Set((1..<parts.count).map { parts.prefix($0).joined(separator: "/") })
            guard !paths.contains(file.path), !ancestors.contains(file.path), paths.isDisjoint(with: parents) else { throw failure("backup payload paths have an ancestor conflict") }
            paths.insert(file.path); ancestors.formUnion(parents); directories.formUnion(parents)
            guard directories.count <= maximumDirectories else { throw failure("backup has too many restore directories") }
            let name = "payload/" + file.path
            guard expected.insert(name).inserted, let entry = entries[name], file.size >= 0, file.size <= maximumBytes - total,
                  entry.uncompressedSize == file.size, file.sha256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
                  file.kind == nil || file.kind == "file" || file.isLink,
                  file.category == category(scope, source: manifest.sourceRelative, path: file.path) else { throw failure("invalid backup file metadata") }
            total += file.size
            if file.isLink {
                guard scope.provider == "Claude Desktop", file.path != manifest.sourceRelative, file.size > 0, file.size <= 1023 else { throw failure("unsupported backup symlink") }
            }
        }
        guard expected == Set(entries.keys), paths.contains(manifest.sourceRelative) else { throw failure("backup has unexpected files or no primary transcript") }
        var desktopMetadata = Data()
        for file in manifest.files {
            var link = Data()
            let (size, digest) = try readEntry(entries["payload/" + file.path]!, archive: archive, limit: file.size) { data in
                if file.isLink { link.append(data) }
                if scope.provider == "Claude Desktop", file.path == manifest.sourceRelative {
                    guard desktopMetadata.count + data.count <= manifestLimit else { throw failure("invalid Claude Desktop metadata size") }; desktopMetadata.append(data)
                }
            }
            guard size == file.size, digest == file.sha256 else { throw failure("backup checksum mismatch") }
            if file.isLink { guard !link.contains(0), String(data: link, encoding: .utf8) != nil else { throw failure("invalid backup symlink target") } }
        }
        if scope.provider == "Claude Desktop" { try validateDesktop(desktopMetadata, manifest: manifest) }
        var after = stat(); guard fstat(fd, &after) == 0, NativeFileTree.stable(before, after) else { throw failure("backup ZIP changed during verification") }
        return manifest
    }
    static func withArchive<T>(_ path: URL, _ body: (Int32) throws -> T) throws -> T {
        let fd = open(path.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw failure("cannot open backup archive") }; defer { close(fd) }
        var before = stat(); guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG else { throw failure("backup must be a regular file") }
        let result = try body(fd)
        var after = stat(); guard fstat(fd, &after) == 0, NativeFileTree.stable(before, after) else { throw failure("backup ZIP changed during operation") }
        return result
    }
}

/// Only this worker installs signal handling. A cancellation requests rollback;
/// the managed parent still enforces the existing finite cleanup deadline.
final class NativeBackupCancellation: @unchecked Sendable {
    static let shared = NativeBackupCancellation()
    private let lock = NSLock()
    private var cancelled = false
    private var sources: [DispatchSourceSignal] = []
    func install() {
        for number in [SIGTERM, SIGINT] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global(qos: .utility))
            source.setEventHandler { self.lock.lock(); self.cancelled = true; self.lock.unlock() }
            sources.append(source); source.resume()
        }
    }
    func check() throws {
        lock.lock(); let value = cancelled; lock.unlock()
        if value { throw CancellationError() }
    }
}
