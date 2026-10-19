import Darwin
import Foundation
import ZIPFoundation

extension NativeSessionBackup {
    static func restore(archive path: URL, destination original: URL,
                        home: URL = FileManager.default.homeDirectoryForCurrentUser, verifiedDescriptor: Int32? = nil) throws -> [String: Any] {
        let parent = try NativeFileTree.resolved(original.deletingLastPathComponent()), name = original.lastPathComponent
        guard try relative(name).count == 1 else { throw failure("invalid restore destination") }
        let destination = parent.appendingPathComponent(name)
        try rejectLiveDestination(destination, homes: [home, FileManager.default.homeDirectoryForCurrentUser])
        guard try NativeLegacyRestoreRecovery.candidates(parent: parent, name: name).isEmpty else {
            throw failure("이전 버전에서 중단된 복원 작업이 있습니다. 복원 기록을 확인한 뒤 검증 후 다시 복원을 실행하세요.")
        }
        let body: (Int32) throws -> [String: Any] = { fd in
            var before = stat(); guard fstat(fd, &before) == 0 else { throw failure("cannot inspect backup archive") }
            let manifest = try verify(fd: fd)
            let recovered = try NativeRestoreTransaction.recover(parent: parent, name: name)
            guard !NativeFileTree.exists(destination) else { throw failure("restore destination already exists; choose a new directory") }
            let transaction = try NativeRestoreTransaction(parent: parent, name: name)
            defer { transaction.rollback() }
            do {
                let archive = try Archive(url: URL(fileURLWithPath: "/dev/fd/\(fd)"), accessMode: .read)
                for file in manifest.files.sorted(by: { !$0.isLink && $1.isLink }) {
                    guard let entry = archive["payload/" + file.path] else { throw failure("backup changed during restore") }
                    try transaction.install(file, entry: entry, archive: archive)
                }
            }
            try transaction.validate(manifest.files)
            var after = stat()
            guard fstat(fd, &after) == 0, NativeFileTree.stable(before, after) else { throw failure("backup ZIP changed during restore") }
            try transaction.publish()
            try transaction.release()
            var receipt = try result(archive: path, manifest: manifest, restored: destination)
            receipt["staleRecovery"] = ["recovered": recovered, "incomplete": false, "scope": "destination"]
            return receipt
        }
        if let verifiedDescriptor { return try body(verifiedDescriptor) }
        return try withArchive(path, body)
    }
    static func dispatch(_ request: [String: Any]) throws -> [String: Any] {
        guard let arguments = request["arguments"] as? [String], arguments.count >= 2 else { throw failure("invalid session backup request") }
        func option(_ name: String) -> String? {
            guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1) else { return nil }
            return arguments[index + 1]
        }
        let home = option("--home").map { URL(fileURLWithPath: $0) } ?? FileManager.default.homeDirectoryForCurrentUser
        let source = URL(fileURLWithPath: arguments[1])
        switch arguments[0] {
        case "backup":
            guard let destination = option("--out") else { throw failure("backup output is required") }
            return try create(source: source, home: home, destination: URL(fileURLWithPath: destination), includeSensitive: arguments.contains("--include-sensitive"))
        case "backup-verify":
            return try withArchive(source) { try result(archive: source, manifest: verify(fd: $0)) }
        case "backup-recovery", "backup-resume":
            guard let destination = option("--out") else { throw failure("restore output is required") }
            return try arguments[0] == "backup-recovery" ? inspectRecovery(archive: source, destination: URL(fileURLWithPath: destination), home: home)
                : resume(archive: source, destination: URL(fileURLWithPath: destination), home: home)
        case "backup-restore":
            guard let destination = option("--out") else { throw failure("restore output is required") }
            return try restore(archive: source, destination: URL(fileURLWithPath: destination), home: home)
        default: throw failure("unsupported session backup operation")
        }
    }
}
