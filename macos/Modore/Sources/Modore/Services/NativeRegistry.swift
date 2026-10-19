import Darwin
import Foundation

/// Shared on-disk contracts use the same lock filename as their source tools.
final class NativeRegistry {
    let root: URL
    init(_ root: URL) { self.root = root }
    func locked<T>(name: String = "lock", _ body: () throws -> T) throws -> T {
        try SecureLocalFileIO.ensurePrivateDirectory(root)
        let fd = open(root.appendingPathComponent(name).path, O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw NativeFileTree.fail("기록 잠금을 열지 못했습니다.") }; defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == geteuid(), info.st_nlink == 1,
              info.st_mode & S_IFMT == S_IFREG, info.st_mode & 0o077 == 0 else { throw NativeFileTree.fail("기록 잠금의 소유권·권한이 올바르지 않습니다.") }
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            guard [EWOULDBLOCK, EAGAIN, EINTR].contains(errno), ProcessInfo.processInfo.systemUptime < deadline else { throw NativeFileTree.fail("다른 작업이 기록을 사용 중입니다. 잠시 후 다시 확인하세요.") }
            usleep(50_000)
        }
        return try body()
    }
    func read(_ name: String, limit: Int = 4_000_000) throws -> [String: Any]? {
        let path = root.appendingPathComponent(name)
        guard NativeFileTree.exists(path) else { return nil }
        let data = try SecureLocalFileIO.boundedRead(from: path, maximumBytes: limit, requireCurrentOwner: true)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw NativeFileTree.fail("기록이 객체 형식이 아닙니다.") }
        return object
    }
    func save(_ object: [String: Any], name: String, limit: Int = 4_000_000) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])
        guard data.count <= limit else { throw NativeFileTree.fail("기록 크기 제한을 초과했습니다.") }
        try SecureLocalFileIO.atomicWrite(data, to: root.appendingPathComponent(name))
    }
}
