import Darwin
import Foundation

extension NativeArtifactEvidence {
    /// Descriptor-relative removal of an already sealed, explicitly selected
    /// product. Every name must still refer to the inventoried inode.
    static func remove(_ path: URL, expected: Seal, identity expectedIdentity: [Int64]) throws {
        guard try identity(path) == expectedIdentity else { throw NativeFileTree.fail("회수 직전 내용·식별 변경 · 보존") }
        let parentPath = path.deletingLastPathComponent(), parent = try NativeFileTree.directory(parentPath)
        defer { close(parent) }
        let initial = try owned(path)
        let root = openat(parent, path.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC | (initial.st_mode & S_IFMT == S_IFDIR ? O_DIRECTORY : 0))
        guard root >= 0 else { throw NativeFileTree.fail("회수 대상 열기 실패") }; defer { close(root) }
        var opened = stat(); guard fstat(root, &opened) == 0, NativeFileTree.stable(initial, opened) else { throw NativeFileTree.fail("회수 대상 식별 변경") }
        let tree = try inventory(root, initial: opened, deadline: ProcessInfo.processInfo.systemUptime + 120)
        guard try seal(path) == expected else { throw NativeFileTree.fail("회수 직전 내용 변경 · 보존") }
        let byPath = Dictionary(uniqueKeysWithValues: tree.entries.map { ($0.path, $0.info) })
        let children = Dictionary(grouping: tree.entries.filter { $0.path != "." }, by: { entry -> String in
            let parts = entry.path.split(separator: "/"); return parts.dropLast().joined(separator: "/")
        })
        func same(_ a: stat, _ b: stat) -> Bool {
            a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_birthtimespec.tv_sec == b.st_birthtimespec.tv_sec
                && a.st_birthtimespec.tv_nsec == b.st_birthtimespec.tv_nsec && a.st_mode == b.st_mode
        }
        func checkRoot() throws {
            var named = stat()
            guard NativeSessionBackup.parentStillMatches(parentPath, fd: parent),
                  fstatat(parent, path.lastPathComponent, &named, AT_SYMLINK_NOFOLLOW) == 0, same(initial, named) else { throw NativeFileTree.fail("회수 경로가 이동·교체되었습니다.") }
        }
        func visit(_ fd: Int32, _ prefix: String, _ ancestry: [(Int32, String, stat)]) throws {
            try checkRoot()
            for (ancestor, name, info) in ancestry {
                var named = stat()
                guard fstatat(ancestor, name, &named, AT_SYMLINK_NOFOLLOW) == 0, same(info, named) else { throw NativeFileTree.fail("회수 중 폴더가 이동·교체되었습니다.") }
            }
            let expected = children[prefix] ?? []
            let names = Set(expected.map { URL(fileURLWithPath: $0.path).lastPathComponent })
            guard Set(try NativeFileTree.names(fd)) == names else { throw NativeFileTree.fail("회수 중 새로운 파일이 나타났습니다.") }
            for entry in expected {
                try checkRoot()
                for (ancestor, name, info) in ancestry {
                    var named = stat()
                    guard fstatat(ancestor, name, &named, AT_SYMLINK_NOFOLLOW) == 0, same(info, named) else { throw NativeFileTree.fail("회수 중 폴더가 이동·교체되었습니다.") }
                }
                let name = URL(fileURLWithPath: entry.path).lastPathComponent
                var current = stat()
                guard fstatat(fd, name, &current, AT_SYMLINK_NOFOLLOW) == 0, NativeFileTree.stable(entry.info, current) else { throw NativeFileTree.fail("회수 중 파일이 바뀌었습니다.") }
                if current.st_mode & S_IFMT == S_IFDIR {
                    let child = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    guard child >= 0 else { throw NativeFileTree.fail("회수 폴더를 열지 못했습니다.") }; defer { close(child) }
                    var actual = stat(); guard fstat(child, &actual) == 0, same(current, actual) else { throw NativeFileTree.fail("회수 폴더 식별 변경") }
                    try visit(child, entry.path, ancestry + [(fd, name, current)])
                    guard fstatat(fd, name, &actual, AT_SYMLINK_NOFOLLOW) == 0, same(current, actual),
                          unlinkat(fd, name, AT_REMOVEDIR) == 0 else { throw NativeFileTree.fail("회수 폴더 제거 중단") }
                } else {
                    guard current.st_mode & S_IFMT == S_IFLNK || (current.st_mode & S_IFMT == S_IFREG && current.st_nlink == 1),
                          unlinkat(fd, name, 0) == 0 else { throw NativeFileTree.fail("회수 파일 제거 중단") }
                }
            }
        }
        if initial.st_mode & S_IFMT == S_IFDIR { try visit(root, "", []) }
        else { guard let captured = byPath["."], NativeFileTree.stable(captured, try NativeFileTree.metadata(path)) else { throw NativeFileTree.fail("회수 파일 식별 변경") } }
        try checkRoot()
        guard unlinkat(parent, path.lastPathComponent, initial.st_mode & S_IFMT == S_IFDIR ? AT_REMOVEDIR : 0) == 0,
              fsync(parent) == 0 else { throw NativeFileTree.fail("회수 결과를 확인하지 못했습니다.") }
    }
}
