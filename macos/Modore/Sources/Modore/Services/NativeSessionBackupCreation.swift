import CryptoKit
import Darwin
import Foundation
import ZIPFoundation

extension NativeSessionBackup {
    static func parentStillMatches(_ path: URL, fd: Int32) -> Bool {
        guard let named = try? NativeFileTree.metadata(path) else { return false }
        var opened = stat()
        return fstat(fd, &opened) == 0 && named.st_mode & S_IFMT == S_IFDIR && identity(named) == identity(opened)
    }
    static func removeOwned(parent: Int32, name: String, fd: Int32) {
        var named = stat(), opened = stat()
        if fstat(fd, &opened) == 0, fstatat(parent, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
           identity(named) == identity(opened), named.st_mode & S_IFMT == S_IFREG {
            _ = unlinkat(parent, name, 0)
        }
    }
    static func liveRoots(home: URL) -> [URL] {
        [home.appendingPathComponent(".claude"), home.appendingPathComponent(".codex"),
         home.appendingPathComponent(quotaPieProfilesPrefix),
         home.appendingPathComponent("Library/Application Support/Claude/local-agent-mode-sessions")]
    }
    static func pathKey(_ path: String) -> String {
        path.decomposedStringWithCanonicalMapping.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
    static func rejectLiveDestination(_ path: URL, homes: [URL]) throws {
        // Spelling checks also cover a not-yet-existing leaf on case-insensitive APFS.
        // Identity checks catch symlink/volume aliases with unrelated spellings.
        var identities = Set<String>()
        var ancestor = path.deletingLastPathComponent()
        while true {
            if let info = try? NativeFileTree.metadata(ancestor), info.st_mode & S_IFMT == S_IFDIR { identities.insert(identity(info)) }
            let parent = ancestor.deletingLastPathComponent(); if parent.path == ancestor.path { break }; ancestor = parent
        }
        var candidates = [path]
        if let resolved = try? NativeFileTree.resolved(path) { candidates.append(resolved) }
        for home in homes {
            for root in liveRoots(home: home) {
                var roots = [root]
                if let resolved = try? NativeFileTree.resolved(root) { roots.append(resolved) }
                for root in roots {
                    let key = pathKey(root.path)
                    if candidates.contains(where: { pathKey($0.path) == key || pathKey($0.path).hasPrefix(key + "/") }) { throw failure("restore destination must be outside live AI session stores") }
                    if let info = try? NativeFileTree.metadata(root), info.st_mode & S_IFMT == S_IFDIR, identities.contains(identity(info)) { throw failure("restore destination aliases a live AI session store") }
                }
            }
        }
    }
    static func addSource(_ entry: Source, homeFD: Int32, directories: [String: String], archive: Archive) throws -> File {
        let (_, bytesDigest) = try streamSource(entry, homeFD: homeFD, directories: directories)
        var recorded = directories
        let (parent, name) = try openParent(homeFD, path: entry.path, directories: &recorded, record: false)
        defer { close(parent) }
        if entry.link {
            var data = Data()
            let (size, digest) = try streamSource(entry, homeFD: homeFD, directories: directories) { data.append($0) }
            guard digest == bytesDigest else { throw failure("session link changed during backup") }
            try archive.addEntry(with: "payload/" + entry.path, type: .file, uncompressedSize: size, permissions: 0o600,
                                 compressionMethod: .deflate, bufferSize: 1024 * 1024) { position, count in
                try check(); return data.subdata(in: Int(position)..<Int(position) + count)
            }
            return File(path: entry.path, size: size, sha256: digest, category: "", kind: "symlink")
        }
        let fd = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw failure("session file is unreadable") }; defer { close(fd) }
        var before = stat(); guard fstat(fd, &before) == 0, NativeFileTree.stable(before, entry.metadata) else { throw failure("session file changed during backup") }
        var position: Int64 = 0, hash = SHA256()
        try archive.addEntry(with: "payload/" + entry.path, type: .file, uncompressedSize: before.st_size,
                             permissions: 0o600, compressionMethod: .deflate, bufferSize: 1024 * 1024) { offset, count in
            try check()
            guard offset == position, count >= 0, offset <= before.st_size, Int64(count) <= before.st_size - offset else { throw failure("invalid backup stream position") }
            var bytes = [UInt8](repeating: 0, count: count)
            guard pread(fd, &bytes, count, offset) == count else { throw failure("session file changed during backup") }
            let data = Data(bytes); hash.update(data: data); position += Int64(count); return data
        }
        let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
        var after = stat(), named = stat()
        guard fstat(fd, &after) == 0, fstatat(parent, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
              NativeFileTree.stable(before, after), NativeFileTree.stable(before, named), digest == bytesDigest else { throw failure("session file changed during backup") }
        return File(path: entry.path, size: before.st_size, sha256: digest, category: "", kind: "file")
    }
    static func create(source: URL, home originalHome: URL, destination originalDestination: URL, includeSensitive: Bool) throws -> [String: Any] {
        guard includeSensitive else { throw failure("raw backup includes private content; --include-sensitive is required") }
        let home = try NativeFileTree.resolved(originalHome)
        let prefix = source.path.hasPrefix(home.path + "/") ? home.path + "/" : originalHome.path + "/"
        guard source.path.hasPrefix(prefix) else { throw failure("session source is outside the supported home") }
        let relative = String(source.path.dropFirst(prefix.count)), scope = try scope(relative)
        let parent = try NativeFileTree.resolved(originalDestination.deletingLastPathComponent())
        let name = originalDestination.lastPathComponent; guard try self.relative(name).count == 1 else { throw failure("invalid backup filename") }
        let destination = parent.appendingPathComponent(name)
        try rejectLiveDestination(destination, homes: [home, FileManager.default.homeDirectoryForCurrentUser])
        let homeFD = try NativeFileTree.directory(home); defer { close(homeFD) }
        let parentFD = try NativeFileTree.directory(parent); defer { close(parentFD) }
        var existing = stat()
        guard fstatat(parentFD, name, &existing, AT_SYMLINK_NOFOLLOW) != 0, errno == ENOENT else { throw failure("backup destination already exists; choose a new filename") }
        let inventory = try inventory(homeFD: homeFD, source: relative)
        let temporary = ".modore-native-backup-" + UUID().uuidString.lowercased()
        let fd = openat(parentFD, temporary, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw failure("cannot allocate private backup file") }; defer { close(fd) }
        var published = false, completed = false
        defer {
            removeOwned(parent: parentFD, name: temporary, fd: fd)
            if published && !completed { removeOwned(parent: parentFD, name: name, fd: fd) }
        }
        // Seed an empty ZIP on the held inode, then let ZIPFoundation update a
        // duplicate descriptor. Its private FILE never reopens a mutable path.
        try NativeFileTree.write(Data([0x50, 0x4b, 0x05, 0x06] + Array(repeating: 0, count: 18)), descriptor: fd)
        var manifest = Manifest(schemaVersion: 1, provider: scope.provider, scope: scope.name, sourceRelative: relative,
                                createdAt: ISO8601DateFormatter().string(from: Date()), files: [])
        do {
            let archive = try Archive(url: URL(fileURLWithPath: "/dev/fd/\(fd)"), accessMode: .update)
            for entry in inventory.files {
                try check()
                let file = try addSource(entry, homeFD: homeFD, directories: inventory.directories, archive: archive)
                manifest.files.append(File(path: file.path, size: file.size, sha256: file.sha256,
                    category: category(scope, source: relative, path: file.path), kind: file.kind))
            }
            let current = try self.inventory(homeFD: homeFD, source: relative)
            guard current.directories == inventory.directories, current.files.count == inventory.files.count,
                  zip(current.files, inventory.files).allSatisfy({ $0.path == $1.path && $0.link == $1.link && NativeFileTree.stable($0.metadata, $1.metadata) }) else { throw failure("session files changed during backup; retry when idle") }
            for (entry, file) in zip(inventory.files, manifest.files) {
                let (size, digest) = try streamSource(entry, homeFD: homeFD, directories: inventory.directories)
                guard size == file.size, digest == file.sha256 else { throw failure("session changed during backup; retry when idle") }
            }
            let data = try JSONEncoder().encode(manifest)
            guard data.count <= manifestLimit else { throw failure("backup manifest exceeds the size limit") }
            try archive.addEntry(with: "manifest.json", type: .file, uncompressedSize: Int64(data.count), permissions: 0o600) { position, count in
                data.subdata(in: Int(position)..<Int(position) + count)
            }
        }
        guard fsync(fd) == 0, try verify(fd: fd) == manifest else { throw failure("backup verification failed") }
        try check()
        var named = stat(), opened = stat()
        guard parentStillMatches(parent, fd: parentFD), fstat(fd, &opened) == 0,
              fstatat(parentFD, temporary, &named, AT_SYMLINK_NOFOLLOW) == 0,
              identity(named) == identity(opened), named.st_nlink == 1 else { throw failure("backup temporary file changed before publish") }
        guard linkat(parentFD, temporary, parentFD, name, 0) == 0 else { throw failure("backup destination already exists or cannot be published") }
        published = true
        guard fsync(parentFD) == 0, fstatat(parentFD, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
              identity(named) == identity(opened), named.st_nlink == 2,
              try verify(fd: fd) == manifest, parentStillMatches(parent, fd: parentFD) else { throw failure("published backup changed during verification") }
        removeOwned(parent: parentFD, name: temporary, fd: fd)
        guard fstat(fd, &opened) == 0, opened.st_nlink == 1 else { throw failure("published backup link identity mismatch") }
        completed = true
        return try result(archive: destination, manifest: manifest)
    }
}
