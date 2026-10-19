import Darwin
import Foundation

extension NativeSessionBackup {
    static func verifyRestored(_ destination: URL, manifest: Manifest) throws {
        let root = try NativeFileTree.directory(destination); defer { close(root) }
        var rootInfo = stat(); guard fstat(root, &rootInfo) == 0, rootInfo.st_uid == geteuid(), rootInfo.st_mode & 0o077 == 0 else { throw failure("복원 폴더의 소유권·권한을 확인하지 못했습니다.") }
        var directories: [String: String] = [:], children: [String: Set<String>] = [:]
        for file in manifest.files {
            let parts = try relative(file.path)
            for count in parts.indices { children[parts.prefix(count).joined(separator: "/"), default: []].insert(parts[count]) }
        }
        func walk(_ fd: Int32, _ prefix: String, _ depth: Int) throws {
            guard depth <= 128 else { throw failure("복원 폴더 깊이 제한 초과") }
            let names = Set(try NativeFileTree.names(fd))
            guard names == children[prefix, default: []] else { throw failure("복원 폴더에 기록되지 않은 파일 또는 누락된 파일이 있습니다.") }
            for name in names {
                let path = prefix.isEmpty ? name : prefix + "/" + name
                if children[path] != nil {
                    let child = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    guard child >= 0 else { throw failure("복원 폴더의 경로가 바뀌었습니다.") }; defer { close(child) }
                    var info = stat(); guard fstat(child, &info) == 0, info.st_uid == geteuid(), info.st_dev == rootInfo.st_dev, info.st_mode & 0o077 == 0 else { throw failure("복원 폴더의 소유 범위가 바뀌었습니다.") }
                    if let previous = directories[path], previous != identity(info) { throw failure("복원 폴더가 검사 중 교체되었습니다.") }
                    directories[path] = identity(info); try walk(child, path, depth + 1)
                }
            }
        }
        try walk(root, "", 0)
        for file in manifest.files {
            try check()
            let (parent, leaf) = try openParent(root, path: file.path, directories: &directories, record: false); defer { close(parent) }
            var info = stat(); guard fstatat(parent, leaf, &info, AT_SYMLINK_NOFOLLOW) == 0,
                  info.st_uid == geteuid(), info.st_dev == rootInfo.st_dev, [1, 2].contains(info.st_nlink),
                  info.st_mode & S_IFMT == (file.isLink ? S_IFLNK : S_IFREG), file.isLink || info.st_mode & 0o077 == 0 else { throw failure("복원 파일의 식별·권한이 바뀌었습니다.") }
            let (size, digest) = try streamSource(Source(path: file.path, metadata: info, link: file.isLink), homeFD: root, directories: directories)
            guard size == file.size, digest == file.sha256 else { throw failure("복원 파일과 선택한 백업의 SHA-256이 다릅니다.") }
        }
        try walk(root, "", 0)
        guard parentStillMatches(destination, fd: root) else { throw failure("복원 폴더 경로가 검사 중 바뀌었습니다.") }
    }
    static func recoveryInspection(destination original: URL, home: URL, manifest: Manifest) throws -> [String: Any] {
        let parent = try NativeFileTree.resolved(original.deletingLastPathComponent()), name = original.lastPathComponent
        guard try relative(name).count == 1 else { throw failure("invalid restore destination") }
        let destination = parent.appendingPathComponent(name)
        try rejectLiveDestination(destination, homes: [home, FileManager.default.homeDirectoryForCurrentUser])
        let native = parent.appendingPathComponent(NativeRestoreTransaction.ledgerName(name))
        var inspection: [String: Any] = ["status": "none", "canResume": false, "destination": destination.path,
            "ledger": NSNull(), "completedFiles": 0, "totalFiles": manifest.files.count, "reason": "중단된 복원 기록이 없습니다."]
        do {
            let legacy = try NativeLegacyRestoreRecovery.candidates(parent: parent, name: name)
            guard legacy.count + (NativeFileTree.exists(native) ? 1 : 0) <= 1 else { throw failure("동일한 대상의 복원 기록이 여러 개 있습니다. 보존 위치에서 확인하세요.") }
            if NativeFileTree.exists(native) {
                inspection["ledger"] = native.path
                _ = try NativeRestoreTransaction.recover(parent: parent, name: name, dryRun: true)
                let published = !NativeFileTree.exists(native.appendingPathComponent(".restore-root"))
                if published { try verifyRestored(destination, manifest: manifest) }
                let journal = try NativeFileTree.read(native.appendingPathComponent("journal.jsonl"), limit: 16 * 1024 * 1024, nofollow: true)
                let events = try journal.split(separator: 10).map { try JSONDecoder().decode(NativeRestoreTransaction.Event.self, from: Data($0)) }
                inspection["completedFiles"] = events.compactMap(\.node).filter { $0.kind != "directory" }.count
                inspection["status"] = published ? "published" : "native"
                inspection["reason"] = published ? "완성된 복원 폴더의 SHA-256을 확인했습니다. 남은 보관 기록을 정리할 수 있습니다." : "임시 파일의 소유 근거를 확인했습니다. 해당 파일을 정리한 뒤 선택한 백업을 새로 복원할 수 있습니다."
                inspection["canResume"] = true
            } else if let ledger = legacy.first {
                inspection["ledger"] = ledger.path
                inspection["completedFiles"] = try NativeLegacyRestoreRecovery.recover(parent: parent, name: name, ledger: ledger, manifest: manifest, dryRun: true)
                inspection["status"] = "legacy"
                inspection["reason"] = "이전 버전의 복원 계획과 임시 파일 소유 근거를 확인했습니다. 기록된 임시 파일만 정리한 뒤 다시 복원할 수 있습니다."
                inspection["canResume"] = true
            } else if NativeFileTree.exists(destination) {
                throw failure("이미 존재하는 폴더입니다. 다른 이름을 선택하세요.")
            }
        } catch {
            inspection["status"] = "manual"; inspection["canResume"] = false
            inspection["reason"] = error.localizedDescription
        }
        return inspection
    }
    static func inspectRecovery(archive path: URL, destination: URL, home: URL) throws -> [String: Any] {
        try withArchive(path) { fd in
            let manifest = try verify(fd: fd)
            var receipt = try result(archive: path, manifest: manifest)
            receipt["status"] = "recovery"; receipt["recovery"] = try recoveryInspection(destination: destination, home: home, manifest: manifest)
            return receipt
        }
    }
    static func resume(archive path: URL, destination original: URL, home: URL) throws -> [String: Any] {
        try withArchive(path) { fd in
            let manifest = try verify(fd: fd), inspection = try recoveryInspection(destination: original, home: home, manifest: manifest)
            guard inspection["canResume"] as? Bool == true, let target = inspection["destination"] as? String else { throw failure(inspection["reason"] as? String ?? "복구할 작업을 확인하지 못했습니다.") }
            let destination = URL(fileURLWithPath: target), parent = destination.deletingLastPathComponent(), name = destination.lastPathComponent
            if inspection["status"] as? String == "published" {
                try verifyRestored(destination, manifest: manifest)
                _ = try NativeRestoreTransaction.recover(parent: parent, name: name)
                try verifyRestored(destination, manifest: manifest)
                return try result(archive: path, manifest: manifest, restored: destination)
            }
            if inspection["status"] as? String == "legacy", let ledger = inspection["ledger"] as? String {
                _ = try NativeLegacyRestoreRecovery.recover(parent: parent, name: name, ledger: URL(fileURLWithPath: ledger), manifest: manifest, dryRun: false)
            }
            return try restore(archive: path, destination: destination, home: home, verifiedDescriptor: fd)
        }
    }
}
