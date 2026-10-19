import CryptoKit
import Darwin
import Foundation
import ZIPFoundation

/// A private staging root, pinned file inodes, and a durable journal keep a
/// cancelled restore separate from live state. Publication is one no-replace rename.
final class NativeRestoreTransaction {
    struct Node: Codable {
        let path: String
        let device: Int32
        let inode: UInt64
        let birthSeconds: Int64
        let birthNanos: Int64
        let kind: String
        let guardName: String?
        init(path: String, info: stat, kind: String, guardName: String? = nil) {
            self.path = path; device = info.st_dev; inode = info.st_ino
            birthSeconds = Int64(info.st_birthtimespec.tv_sec); birthNanos = Int64(info.st_birthtimespec.tv_nsec)
            self.kind = kind; self.guardName = guardName
        }
        func matches(_ info: stat) -> Bool {
            device == info.st_dev && inode == info.st_ino
                && birthSeconds == info.st_birthtimespec.tv_sec && birthNanos == info.st_birthtimespec.tv_nsec
        }
    }
    struct Event: Codable {
        let type: String
        var rootName: String?
        var parent: Node?
        var guardNode: Node?
        var root: Node?
        var node: Node?
    }
    let parent: URL
    let rootName: String
    let guardName: String
    let parentFD: Int32
    let guardFD: Int32
    let lockFD: Int32
    let journalFD: Int32
    let rootFD: Int32
    let parentNode: Node
    let guardNode: Node
    let rootNode: Node
    var nodes: [Node] = []
    var directories: [String: Int32] = [:]
    var prepared = false
    var published = false
    var released = false

    private static func info(_ fd: Int32) throws -> stat {
        var info = stat(); guard fstat(fd, &info) == 0 else { throw NativeSessionBackup.failure("cannot inspect restore inode") }; return info
    }
    private static func openDir(_ parent: Int32, _ name: String) throws -> Int32 {
        let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw NativeSessionBackup.failure("restore directory is missing, changed or a link") }; return fd
    }
    private static func ledgerName(_ leaf: String) -> String {
        ".modore-native-restore-v1-" + NativeFileTree.hash(NativeSessionBackup.pathKey(leaf))
    }
    static func recover(parent: URL, name: String) throws -> Int {
        let parentFD = try NativeFileTree.directory(parent); defer { close(parentFD) }
        let guardName = ledgerName(name)
        var named = stat()
        if fstatat(parentFD, guardName, &named, AT_SYMLINK_NOFOLLOW) != 0 {
            guard errno == ENOENT else { throw NativeSessionBackup.failure("restore ledger is unreadable") }; return 0
        }
        let guardFD = try openDir(parentFD, guardName); defer { close(guardFD) }
        guard named.st_uid == geteuid(), named.st_mode & 0o077 == 0 else { throw NativeSessionBackup.failure("restore ledger is not private") }
        let lockFD = openat(guardFD, ".lock", O_RDWR | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard lockFD >= 0 else { throw NativeSessionBackup.failure("restore recovery requires manual review: no private lock") }; defer { close(lockFD) }
        guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else { throw NativeSessionBackup.failure("another restore of this destination is active") }
        let journalFD = openat(guardFD, "journal.jsonl", O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard journalFD >= 0 else { throw NativeSessionBackup.failure("restore recovery requires manual review: no journal") }; defer { close(journalFD) }
        let data = try NativeFileTree.read(journalFD, limit: 16 * 1024 * 1024)
        let lines = data.split(separator: 10)
        let events = try lines.map { try JSONDecoder().decode(Event.self, from: Data($0)) }
        guard let header = events.first, header.type == "header", header.rootName == name,
              let parentNode = header.parent, let guardNode = header.guardNode, let rootNode = header.root,
              parentNode.matches(try info(parentFD)), guardNode.matches(try info(guardFD)) else { throw NativeSessionBackup.failure("restore recovery ledger identity mismatch") }
        let nodes = events.compactMap(\.node)
        guard nodes.count <= NativeSessionBackup.maximumFiles + NativeSessionBackup.maximumDirectories,
              nodes.filter({ $0.kind == "directory" }).count <= NativeSessionBackup.maximumDirectories,
              Set(nodes.map(\.path)).count == nodes.count else { throw NativeSessionBackup.failure("invalid restore recovery journal") }
        for node in nodes { _ = try NativeSessionBackup.relative(node.path) }
        let stageFD = openat(guardFD, ".restore-root", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if stageFD < 0 {
            guard events.contains(where: { $0.type == "prepared" }),
                  fstatat(parentFD, name, &named, AT_SYMLINK_NOFOLLOW) == 0, rootNode.matches(named) else { throw NativeSessionBackup.failure("restore recovery root changed; manual review required") }
            // A fully published root is user data. Recovery releases only guard links.
            try releaseGuardLinks(guardFD: guardFD, nodes: nodes)
        } else {
            defer { close(stageFD) }
            guard rootNode.matches(try info(stageFD)) else { throw NativeSessionBackup.failure("restore recovery root identity mismatch") }
            var opened: [String: Int32] = ["": stageFD]
            defer { opened.filter { !$0.key.isEmpty }.forEach { close($0.value) } }
            for node in nodes.filter({ $0.kind == "directory" }).sorted(by: { $0.path.split(separator: "/").count < $1.path.split(separator: "/").count }) {
                let parts = try NativeSessionBackup.relative(node.path), key = parts.dropLast().joined(separator: "/")
                guard let parent = opened[key] else { throw NativeSessionBackup.failure("invalid restore directory journal") }
                let child = try openDir(parent, parts.last!)
                guard node.matches(try info(child)) else { close(child); throw NativeSessionBackup.failure("restore directory changed; manual review required") }
                opened[node.path] = child
            }
            // Reject unknown names before removing anything. A crash before a
            // creation is journaled is ambiguous and is retained for review.
            let children = Dictionary(grouping: nodes, by: { $0.path.split(separator: "/").dropLast().joined(separator: "/") })
            for (path, fd) in opened {
                let expected = Set((children[path] ?? []).map { URL(fileURLWithPath: $0.path).lastPathComponent })
                guard Set(try NativeFileTree.names(fd)) == expected else { throw NativeSessionBackup.failure("restore recovery found unrecorded data; manual review required") }
            }
            for node in nodes.reversed() where node.kind != "directory" {
                let parts = try NativeSessionBackup.relative(node.path), key = parts.dropLast().joined(separator: "/")
                guard let parent = opened[key], let guardName = node.guardName,
                      guardName.range(of: "^owned-[0-9]+$", options: .regularExpression) != nil else { throw NativeSessionBackup.failure("invalid restore inode guard") }
                var guarded = stat(), current = stat()
                guard fstatat(guardFD, guardName, &guarded, AT_SYMLINK_NOFOLLOW) == 0, node.matches(guarded),
                      fstatat(parent, parts.last!, &current, AT_SYMLINK_NOFOLLOW) == 0, node.matches(current),
                      guarded.st_nlink == 2, current.st_nlink == 2 else { throw NativeSessionBackup.failure("restore recovery file changed; manual review required") }
                guard unlinkat(parent, parts.last!, 0) == 0, unlinkat(guardFD, guardName, 0) == 0 else { throw NativeSessionBackup.failure("restore recovery could not remove its own file") }
            }
            for node in nodes.reversed() where node.kind == "directory" {
                let parts = try NativeSessionBackup.relative(node.path), key = parts.dropLast().joined(separator: "/")
                guard let parent = opened[key], fstatat(parent, parts.last!, &named, AT_SYMLINK_NOFOLLOW) == 0, node.matches(named),
                      unlinkat(parent, parts.last!, AT_REMOVEDIR) == 0 else { throw NativeSessionBackup.failure("restore recovery directory changed") }
            }
            guard unlinkat(guardFD, ".restore-root", AT_REMOVEDIR) == 0 else { throw NativeSessionBackup.failure("restore recovery root is not empty") }
        }
        guard Set(try NativeFileTree.names(guardFD)) == [".lock", "journal.jsonl"] else { throw NativeSessionBackup.failure("restore ledger contains unrecorded data") }
        guard unlinkat(guardFD, "journal.jsonl", 0) == 0, unlinkat(guardFD, ".lock", 0) == 0,
              fstatat(parentFD, guardName, &named, AT_SYMLINK_NOFOLLOW) == 0, guardNode.matches(named),
              unlinkat(parentFD, guardName, AT_REMOVEDIR) == 0 else { throw NativeSessionBackup.failure("restore ledger cleanup failed") }
        _ = fsync(parentFD)
        return 1
    }
    private static func releaseGuardLinks(guardFD: Int32, nodes: [Node]) throws {
        for node in nodes where node.kind != "directory" {
            guard let name = node.guardName, name.range(of: "^owned-[0-9]+$", options: .regularExpression) != nil else { throw NativeSessionBackup.failure("invalid restore guard name") }
            var current = stat()
            let status = fstatat(guardFD, name, &current, AT_SYMLINK_NOFOLLOW)
            if status != 0, errno == ENOENT { continue }
            guard status == 0, node.matches(current), unlinkat(guardFD, name, 0) == 0 else { throw NativeSessionBackup.failure("restore inode guard changed") }
        }
    }
    init(parent: URL, name: String) throws {
        self.parent = parent; rootName = name; guardName = Self.ledgerName(name)
        parentFD = try NativeFileTree.directory(parent)
        var openedGuard: Int32 = -1, openedLock: Int32 = -1, openedJournal: Int32 = -1, openedRoot: Int32 = -1
        do {
            parentNode = Node(path: "", info: try Self.info(parentFD), kind: "directory")
            guard mkdirat(parentFD, guardName, 0o700) == 0 else { throw NativeSessionBackup.failure("restore integrity ledger already exists; review or retry recovery") }
            openedGuard = try Self.openDir(parentFD, guardName)
            guardNode = Node(path: "", info: try Self.info(openedGuard), kind: "directory")
            openedLock = openat(openedGuard, ".lock", O_CREAT | O_EXCL | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard openedLock >= 0, flock(openedLock, LOCK_EX | LOCK_NB) == 0 else { throw NativeSessionBackup.failure("restore lock unavailable") }
            guard mkdirat(openedGuard, ".restore-root", 0o700) == 0 else { throw NativeSessionBackup.failure("cannot create private restore root") }
            openedRoot = try Self.openDir(openedGuard, ".restore-root")
            rootNode = Node(path: "", info: try Self.info(openedRoot), kind: "directory")
            openedJournal = openat(openedGuard, "journal.jsonl", O_WRONLY | O_CREAT | O_EXCL | O_APPEND | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard openedJournal >= 0 else { throw NativeSessionBackup.failure("cannot create restore journal") }
            guardFD = openedGuard; lockFD = openedLock; journalFD = openedJournal; rootFD = openedRoot
            directories[""] = openedRoot
            try append(Event(type: "header", rootName: name, parent: parentNode, guardNode: guardNode, root: rootNode))
        } catch {
            if openedJournal >= 0 { close(openedJournal) }
            if openedRoot >= 0 { close(openedRoot) }
            if openedLock >= 0 { close(openedLock) }
            if openedGuard >= 0 { close(openedGuard) }
            close(parentFD)
            // Partial, unjournaled guards are intentionally retained, never adopted by name.
            throw error
        }
    }
    deinit {
        directories.filter { !$0.key.isEmpty }.forEach { close($0.value) }
        close(rootFD); close(journalFD); close(lockFD); close(guardFD); close(parentFD)
    }
    func append(_ event: Event) throws {
        var data = try JSONEncoder().encode(event); data.append(10)
        try NativeFileTree.write(data, descriptor: journalFD)
    }
    func validateRoot() throws {
        guard NativeSessionBackup.parentStillMatches(parent, fd: parentFD),
              parentNode.matches(try Self.info(parentFD)), guardNode.matches(try Self.info(guardFD)) else { throw NativeSessionBackup.failure("restore parent changed") }
        var named = stat()
        guard fstatat(parentFD, guardName, &named, AT_SYMLINK_NOFOLLOW) == 0, guardNode.matches(named),
              fstatat(published ? parentFD : guardFD, published ? rootName : ".restore-root", &named, AT_SYMLINK_NOFOLLOW) == 0,
              rootNode.matches(named) else { throw NativeSessionBackup.failure("restore root changed") }
    }
    func directory(_ path: String, create: Bool) throws -> Int32 {
        try validateRoot()
        if path.isEmpty { return rootFD }
        let parts = try NativeSessionBackup.relative(path)
        var fd = rootFD, prefix: [String] = []
        for part in parts {
            prefix.append(part); let key = prefix.joined(separator: "/")
            if let recorded = directories[key] {
                var named = stat()
                let held = try Self.info(recorded)
                guard fstatat(fd, part, &named, AT_SYMLINK_NOFOLLOW) == 0,
                      NativeSessionBackup.identity(named) == NativeSessionBackup.identity(held) else { throw NativeSessionBackup.failure("restore directory changed") }
                fd = recorded
            } else {
                guard create, directories.count <= NativeSessionBackup.maximumDirectories,
                      mkdirat(fd, part, 0o700) == 0 else { throw NativeSessionBackup.failure("restore directory conflicts or exceeds limits") }
                let child = try Self.openDir(fd, part), info = try Self.info(child)
                let node = Node(path: key, info: info, kind: "directory")
                directories[key] = child; nodes.append(node)
                try append(Event(type: "node", node: node)); fd = child
            }
        }
        return fd
    }
    func install(_ file: NativeSessionBackup.File, entry: Entry, archive: Archive) throws {
        try NativeSessionBackup.check()
        let parts = try NativeSessionBackup.relative(file.path), leaf = parts.last!, parent = try directory(parts.dropLast().joined(separator: "/"), create: true)
        let guardName = "owned-\(nodes.count)"
        var fd: Int32 = -1, linkData = Data()
        if file.isLink {
            let (size, digest) = try NativeSessionBackup.readEntry(entry, archive: archive, limit: file.size) { linkData.append($0) }
            guard size == file.size, digest == file.sha256, let target = String(data: linkData, encoding: .utf8),
                  !linkData.contains(0), symlinkat(target, parent, leaf) == 0 else { throw NativeSessionBackup.failure("cannot restore verified leaf link") }
        } else {
            fd = openat(parent, leaf, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw NativeSessionBackup.failure("restore file already exists or cannot be created") }
        }
        defer { if fd >= 0 { close(fd) } }
        var info = stat(); guard fstatat(parent, leaf, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw NativeSessionBackup.failure("restored file disappeared") }
        var recorded = false
        defer {
            if !recorded {
                var current = stat()
                if fstatat(parent, leaf, &current, AT_SYMLINK_NOFOLLOW) == 0, NativeSessionBackup.identity(current) == NativeSessionBackup.identity(info) {
                    _ = unlinkat(parent, leaf, 0)
                }
            }
        }
        guard linkat(parent, leaf, guardFD, guardName, 0) == 0 else { throw NativeSessionBackup.failure("cannot pin restored inode") }
        let node = Node(path: file.path, info: info, kind: file.isLink ? "symlink" : "file", guardName: guardName)
        nodes.append(node); recorded = true; try append(Event(type: "node", node: node))
        if !file.isLink {
            let (size, digest) = try NativeSessionBackup.readEntry(entry, archive: archive, limit: file.size) { data in
                try NativeFileTree.write(data, descriptor: fd)
            }
            guard size == file.size, digest == file.sha256 else { throw NativeSessionBackup.failure("backup changed during restore") }
        }
    }
    func validate(_ files: [NativeSessionBackup.File]) throws {
        try validateRoot()
        for file in files {
            try NativeSessionBackup.check()
            guard let node = nodes.first(where: { $0.path == file.path }), let guardName = node.guardName else { throw NativeSessionBackup.failure("restore file has no inode guard") }
            let parts = try NativeSessionBackup.relative(file.path), parent = try directory(parts.dropLast().joined(separator: "/"), create: false)
            var named = stat(), guarded = stat()
            guard fstatat(parent, parts.last!, &named, AT_SYMLINK_NOFOLLOW) == 0, node.matches(named),
                  fstatat(guardFD, guardName, &guarded, AT_SYMLINK_NOFOLLOW) == 0, node.matches(guarded), named.st_nlink == 2,
                  guarded.st_nlink == 2 else { throw NativeSessionBackup.failure("restored file changed before publication") }
            if file.isLink {
                var bytes = [CChar](repeating: 0, count: 1024)
                let count = readlinkat(parent, parts.last!, &bytes, bytes.count)
                guard count == file.size, NativeFileTree.hash(Data(bytes.prefix(max(0, count)).map { UInt8(bitPattern: $0) })) == file.sha256 else { throw NativeSessionBackup.failure("restored link changed before publication") }
            } else {
                let fd = openat(parent, parts.last!, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
                guard fd >= 0 else { throw NativeSessionBackup.failure("restored file is unreadable") }; defer { close(fd) }
                var digest = SHA256(), size: Int64 = 0, buffer = [UInt8](repeating: 0, count: 1024 * 1024)
                while true {
                    try NativeSessionBackup.check()
                    let count = Darwin.read(fd, &buffer, buffer.count)
                    if count == 0 { break }
                    if count < 0 { if errno == EINTR { continue }; throw NativeSessionBackup.failure("restored file read failed") }
                    size += Int64(count); guard size <= file.size else { throw NativeSessionBackup.failure("restored file grew") }
                    digest.update(data: Data(buffer.prefix(count)))
                }
                guard size == file.size, digest.finalize().map({ String(format: "%02x", $0) }).joined() == file.sha256 else { throw NativeSessionBackup.failure("restored file checksum mismatch") }
            }
        }
        try validateRoot()
    }
    func publish() throws {
        try NativeSessionBackup.check(); try validateRoot()
        try append(Event(type: "prepared")); prepared = true
        guard fsync(rootFD) == 0, fsync(guardFD) == 0,
              renameatx_np(guardFD, ".restore-root", parentFD, rootName, UInt32(RENAME_EXCL)) == 0 else { throw NativeSessionBackup.failure("restore destination exists or cannot be published") }
        published = true
        guard fsync(parentFD) == 0 else { throw NativeSessionBackup.failure("restore publication could not be made durable") }
        try append(Event(type: "published"))
    }
    func release() throws {
        try validateRoot()
        try Self.releaseGuardLinks(guardFD: guardFD, nodes: nodes)
        guard Set(try NativeFileTree.names(guardFD)) == [".lock", "journal.jsonl"] else { throw NativeSessionBackup.failure("restore ledger contains unrecorded data") }
        guard unlinkat(guardFD, "journal.jsonl", 0) == 0, unlinkat(guardFD, ".lock", 0) == 0,
              unlinkat(parentFD, guardName, AT_REMOVEDIR) == 0 else { throw NativeSessionBackup.failure("restore ledger release failed") }
        released = true; _ = fsync(parentFD)
    }
    func rollback() {
        guard !published, !released else { return }
        // The open root and guard descriptors pin every inode during active rollback.
        for node in nodes.reversed() {
            let parts = node.path.split(separator: "/").map(String.init), key = parts.dropLast().joined(separator: "/")
            guard let parent = directories[key], let leaf = parts.last else { continue }
            var named = stat()
            guard fstatat(parent, leaf, &named, AT_SYMLINK_NOFOLLOW) == 0, node.matches(named) else { continue }
            if node.kind == "directory" { _ = unlinkat(parent, leaf, AT_REMOVEDIR) }
            else if let guardName = node.guardName {
                var guarded = stat()
                if fstatat(guardFD, guardName, &guarded, AT_SYMLINK_NOFOLLOW) == 0, node.matches(guarded) {
                    _ = unlinkat(parent, leaf, 0); _ = unlinkat(guardFD, guardName, 0)
                }
            }
        }
        var current = stat()
        if fstatat(guardFD, ".restore-root", &current, AT_SYMLINK_NOFOLLOW) == 0, rootNode.matches(current),
           unlinkat(guardFD, ".restore-root", AT_REMOVEDIR) == 0,
           (try? Set(NativeFileTree.names(guardFD))) == [".lock", "journal.jsonl"] {
            _ = unlinkat(guardFD, "journal.jsonl", 0); _ = unlinkat(guardFD, ".lock", 0)
            if fstatat(parentFD, guardName, &current, AT_SYMLINK_NOFOLLOW) == 0, guardNode.matches(current) { _ = unlinkat(parentFD, guardName, AT_REMOVEDIR) }
        }
    }
}
