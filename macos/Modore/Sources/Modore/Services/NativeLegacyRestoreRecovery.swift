import Darwin
import Foundation

/// Recover the provable private stage of the former Python schema-3 writer.
/// Incomplete plans, published legacy roots and foreign data stay visible for
/// review. No Python interpreter participates in this migration.
enum NativeLegacyRestoreRecovery {
    static func candidates(parent: URL, name: String) throws -> [URL] {
        let exact = parent.appendingPathComponent(".modore-restore-ledger-v3-" + NativeFileTree.hash(NativeSessionBackup.pathKey(name)))
        var found: [URL] = NativeFileTree.exists(exact) ? [exact] : []
        let fd = try NativeFileTree.directory(parent); defer { close(fd) }
        // Old random ledger names are discoverable only within a finite parent
        // inventory. Never silently skip a saturated recovery namespace.
        for candidate in try NativeFileTree.names(fd, limit: 4096) where candidate != exact.lastPathComponent && candidate.range(of: #"^\.modore-restore-ledger-(?:v3-[0-9a-f]{64}|[0-9]+-[0-9a-f]{16})$"#, options: .regularExpression) != nil {
            guard found.count < 32 else { throw NativeFileTree.fail("복원 기록 탐색 제한 초과 · 원본 기록을 보존합니다.") }
            let path = parent.appendingPathComponent(candidate)
            let guardFD = openat(fd, candidate, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard guardFD >= 0 else { continue }; defer { close(guardFD) }
            let journal = openat(guardFD, "journal.jsonl", O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
            guard journal >= 0 else { continue }; defer { close(journal) }
            guard let data = try? NativeFileTree.read(journal, limit: 16 * 1024 * 1024),
                  let first = data.split(separator: 10).first,
                  let header = (try? JSONSerialization.jsonObject(with: Data(first))) as? [String: Any],
                  let rootName = header["rootName"] as? String, NativeSessionBackup.pathKey(rootName) == NativeSessionBackup.pathKey(name) else { continue }
            found.append(path)
        }
        return found
    }
    static func recover(parent: URL, name: String, ledger: URL, manifest: NativeSessionBackup.Manifest, dryRun: Bool) throws -> Int {
        let parentFD = try NativeFileTree.directory(parent); defer { close(parentFD) }
        let guardFD = openat(parentFD, ledger.lastPathComponent, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard guardFD >= 0 else { throw NativeFileTree.fail("이전 복원 기록을 열지 못했습니다.") }; defer { close(guardFD) }
        func info(_ fd: Int32) throws -> stat { var s = stat(); guard fstat(fd, &s) == 0 else { throw NativeFileTree.fail("복원 기록 식별 확인 실패") }; return s }
        func pair(_ s: stat) -> [Int64] { [Int64(s.st_dev), Int64(bitPattern: s.st_ino)] }
        let guardInfo = try info(guardFD)
        guard guardInfo.st_uid == geteuid(), guardInfo.st_mode & 0o077 == 0, guardInfo.st_dev == (try info(parentFD)).st_dev else { throw NativeFileTree.fail("이전 복원 기록의 소유권·권한이 바뀌었습니다.") }
        let journal = openat(guardFD, "journal.jsonl", O_RDWR | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard journal >= 0 else { throw NativeFileTree.fail("이전 복원 저널을 열지 못했습니다.") }; defer { close(journal) }
        let journalInfo = try info(journal)
        guard journalInfo.st_mode & S_IFMT == S_IFREG, journalInfo.st_uid == geteuid(), journalInfo.st_nlink == 1,
              journalInfo.st_mode & 0o077 == 0, flock(journal, LOCK_EX | LOCK_NB) == 0 else { throw NativeFileTree.fail("이전 복원 작업이 실행 중이거나 기록이 안전하지 않습니다.") }
        let data = try NativeFileTree.read(journal, limit: 16 * 1024 * 1024)
        guard data.last == 10 else { throw NativeFileTree.fail("이전 복원 기록의 마지막 쓰기가 중단되었습니다. 수동 확인이 필요합니다.") }
        let events = try data.split(separator: 10).map { line -> [String: Any] in
            guard let event = try JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { throw NativeFileTree.fail("복원 저널 형식 오류") }; return event
        }
        guard events.count <= 2 * NativeSessionBackup.maximumFiles + 2 * NativeSessionBackup.maximumDirectories + 5,
              let header = events.first, header["type"] as? String == "header", header["schema"] as? Int == 3,
              header["rootName"] as? String == name, header["parentIdentity"] as? [Int64] == pair(try info(parentFD)),
              let rootIdentity = header["rootIdentity"] as? [Int64], rootIdentity.count == 2 else { throw NativeFileTree.fail("이전 복원 기록의 대상·형식을 검증하지 못했습니다.") }
        let root = openat(guardFD, ".restore-root", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard root >= 0 else { throw NativeFileTree.fail("공개된 이전 복원 폴더는 자동으로 변경하지 않습니다. 보존 위치에서 파일을 확인하세요.") }; defer { close(root) }
        let rootInfo = try info(root)
        guard pair(rootInfo) == rootIdentity, rootInfo.st_uid == geteuid(), rootInfo.st_mode & 0o077 == 0, rootInfo.st_dev == guardInfo.st_dev else { throw NativeFileTree.fail("이전 복원의 임시 폴더 식별이 바뀌었습니다.") }
        let plans = events.filter { $0["type"] as? String == "plan" }, proofs = events.filter { $0["type"] as? String == "directory" }
        let intents = events.filter { $0["type"] as? String == "directory-intent" }, commits = events.filter { $0["type"] as? String == "plan-commit" }
        guard plans.count == manifest.files.count, proofs.count <= NativeSessionBackup.maximumDirectories,
              commits.count == 1, commits[0]["plans"] as? Int == plans.count, commits[0]["directories"] as? Int == proofs.count,
              events.filter({ $0["type"] as? String == "intent-commit" }).count == 1,
              events.allSatisfy({ ["header", "plan", "directory-intent", "intent-commit", "directory", "plan-commit", "release", "release-commit"].contains($0["type"] as? String ?? "") }) else { throw NativeFileTree.fail("이전 복원의 계획 기록이 완성되지 않았습니다. 수동 확인이 필요합니다.") }
        let files = Dictionary(uniqueKeysWithValues: manifest.files.map { ($0.path, $0) })
        var expectedDirectories = Set<String>(), planPaths = Set<String>(), normalized: [(path: String, parent: String, leaf: String, guardName: String, link: Bool)] = []
        for (index, plan) in plans.enumerated() {
            guard let parent = plan["parent"] as? String, let leaf = plan["name"] as? String,
                  let guardName = plan["guard"] as? String, guardName == String(format: "%08x", index) else { throw NativeFileTree.fail("이전 복원 파일 계획 식별 오류") }
            let path = parent.isEmpty ? leaf : parent + "/" + leaf, parts = try NativeSessionBackup.relative(path)
            guard parts.last == leaf, let file = files[path], planPaths.insert(path).inserted,
                  plan["size"] as? Int64 == file.size, plan["digest"] as? String == file.sha256,
                  (plan["kind"] as? String ?? "file") == (file.isLink ? "symlink" : "file") else { throw NativeFileTree.fail("선택한 백업과 이전 복원 계획이 다릅니다.") }
            for count in 1..<parts.count { expectedDirectories.insert(parts.prefix(count).joined(separator: "/")) }
            normalized.append((path, parent, leaf, guardName, file.isLink))
        }
        guard Set(proofs.compactMap { $0["path"] as? String }) == expectedDirectories,
              Set(intents.compactMap { $0["path"] as? String }) == expectedDirectories,
              proofs.count == expectedDirectories.count, intents.count == expectedDirectories.count else { throw NativeFileTree.fail("이전 복원 폴더 계획이 불완전합니다.") }
        var directories: [String: Int32] = ["": root], directoryInfo: [String: stat] = [:]
        defer { directories.filter { !$0.key.isEmpty }.forEach { close($0.value) } }
        for proof in proofs.sorted(by: { ($0["path"] as? String ?? "").count < ($1["path"] as? String ?? "").count }) {
            let path = proof["path"] as! String, parts = try NativeSessionBackup.relative(path), parentPath = parts.dropLast().joined(separator: "/"), leaf = parts.last!
            guard proof["parent"] as? String == parentPath, proof["name"] as? String == leaf,
                  let parent = directories[parentPath] else { throw NativeFileTree.fail("이전 복원 폴더 연결 오류") }
            let fd = openat(parent, leaf, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw NativeFileTree.fail("이전 복원 폴더가 없어졌거나 바뀌었습니다.") }
            let actual = try info(fd)
            guard proof["identity"] as? [Int64] == pair(actual), actual.st_uid == geteuid(), actual.st_mode & 0o077 == 0,
                  actual.st_dev == rootInfo.st_dev else { close(fd); throw NativeFileTree.fail("이전 복원 폴더 식별이 바뀌었습니다.") }
            directories[path] = fd; directoryInfo[path] = actual
        }
        var owned: [(Int32, String, String, stat)] = [], allowed: [String: Set<String>] = [:]
        for directory in expectedDirectories {
            let parts = directory.split(separator: "/"); allowed[parts.dropLast().joined(separator: "/"), default: []].insert(String(parts.last!))
        }
        for plan in normalized {
            guard let parent = directories[plan.parent] else { throw NativeFileTree.fail("이전 복원 파일의 상위 폴더 없음") }
            var named = stat(), guarded = stat()
            let namedStatus = fstatat(parent, plan.leaf, &named, AT_SYMLINK_NOFOLLOW), namedError = errno
            let guardStatus = fstatat(guardFD, plan.guardName, &guarded, AT_SYMLINK_NOFOLLOW), guardError = errno
            if namedStatus != 0, namedError == ENOENT, guardStatus != 0, guardError == ENOENT { continue }
            guard namedStatus == 0, guardStatus == 0, pair(named) == pair(guarded), named.st_nlink == 2, guarded.st_nlink == 2,
                  named.st_uid == geteuid(), named.st_dev == rootInfo.st_dev, named.st_mode & 0o077 == 0 || plan.link,
                  named.st_mode & S_IFMT == (plan.link ? S_IFLNK : S_IFREG) else { throw NativeFileTree.fail("이전 복원 파일의 소유 근거가 바뀌었습니다. 보존합니다.") }
            allowed[plan.parent, default: []].insert(plan.leaf); owned.append((parent, plan.leaf, plan.guardName, named))
        }
        for (path, fd) in directories { guard Set(try NativeFileTree.names(fd)) == allowed[path, default: []] else { throw NativeFileTree.fail("이전 복원 폴더에 기록되지 않은 파일이 있습니다. 보존합니다.") } }
        guard Set(try NativeFileTree.names(guardFD)) == Set(["journal.jsonl", ".restore-root"] + owned.map { $0.2 }) else { throw NativeFileTree.fail("이전 복원 보관 위치에 기록되지 않은 파일이 있습니다.") }
        if dryRun { return owned.count }
        func validateRoot() throws {
            var named = stat()
            guard NativeSessionBackup.parentStillMatches(parent, fd: parentFD),
                  fstatat(parentFD, ledger.lastPathComponent, &named, AT_SYMLINK_NOFOLLOW) == 0, pair(named) == pair(guardInfo),
                  fstatat(guardFD, ".restore-root", &named, AT_SYMLINK_NOFOLLOW) == 0, pair(named) == rootIdentity else { throw NativeFileTree.fail("복구 중 이전 복원 경로가 바뀌었습니다.") }
        }
        for (parent, leaf, guardName, expected) in owned.reversed() {
            try validateRoot(); var named = stat(), guarded = stat()
            guard fstatat(parent, leaf, &named, AT_SYMLINK_NOFOLLOW) == 0, pair(named) == pair(expected),
                  fstatat(guardFD, guardName, &guarded, AT_SYMLINK_NOFOLLOW) == 0, pair(guarded) == pair(expected),
                  unlinkat(parent, leaf, 0) == 0, unlinkat(guardFD, guardName, 0) == 0 else { throw NativeFileTree.fail("이전 복원 파일 복구 중단") }
        }
        for path in expectedDirectories.sorted(by: { $0.count > $1.count }) {
            let parts = path.split(separator: "/"), parentPath = parts.dropLast().joined(separator: "/"), leaf = String(parts.last!)
            var named = stat(); try validateRoot()
            guard let parent = directories[parentPath], let expected = directoryInfo[path],
                  fstatat(parent, leaf, &named, AT_SYMLINK_NOFOLLOW) == 0, pair(named) == pair(expected),
                  unlinkat(parent, leaf, AT_REMOVEDIR) == 0 else { throw NativeFileTree.fail("이전 복원 폴더 복구 중단") }
        }
        try validateRoot()
        guard unlinkat(guardFD, ".restore-root", AT_REMOVEDIR) == 0,
              Set(try NativeFileTree.names(guardFD)) == ["journal.jsonl"], unlinkat(guardFD, "journal.jsonl", 0) == 0,
              unlinkat(parentFD, ledger.lastPathComponent, AT_REMOVEDIR) == 0, fsync(parentFD) == 0 else { throw NativeFileTree.fail("이전 복원 기록 정리를 확인하지 못했습니다.") }
        return owned.count
    }
}
