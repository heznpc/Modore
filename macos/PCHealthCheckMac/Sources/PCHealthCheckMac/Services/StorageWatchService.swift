import CryptoKit
import Darwin
import Foundation

enum StorageWatchRuntimeState: Equatable, Sendable {
    case absent
    case current
    case stale
}

struct StorageWatchStatus: Sendable {
    let enabled: Bool
    let detail: String
    let freeSpaceSamples: [FreeSpaceSample]?
}

enum StorageWatchService {
    static func status(projectRoot: URL) async -> StorageWatchStatus {
        guard let execution = await Task.detached(priority: .utility, operation: {
            RuntimeWorkspace.prepareExecution(projectRoot: projectRoot)
        }).value else {
            return StorageWatchStatus(
                enabled: false,
                detail: "서명된 감시 런타임을 확인할 수 없음",
                freeSpaceSamples: await loadFreeSpaceSamples()
            )
        }
        guard let invocation = execution.pinnedInvocation(
            relativePath: "scripts/schedule.sh",
            name: "schedule"
        ) else {
            return StorageWatchStatus(
                enabled: false,
                detail: "봉인한 감시 설정 프로그램을 확인할 수 없음",
                freeSpaceSamples: nil
            )
        }
        guard let watcherHash = execution.sealedSHA256(
            relativePath: "scripts/storage_watch.sh"
        ) else {
            return StorageWatchStatus(
                enabled: false,
                detail: "봉인한 저장공간 감시 프로그램을 확인할 수 없음",
                freeSpaceSamples: nil
            )
        }
        let result = await LocalProcessRunner.capture(
            executable: "/bin/bash",
            arguments: [invocation.argument, "--status"],
            currentDirectory: execution.runtimeRoot,
            expectedCurrentDirectoryIdentity: execution.runtimeRootIdentity,
            expectedSignedBundleURL: execution.signedBundleURL,
            pinnedFiles: invocation.files,
            environment: [
                "PCH_STORAGE_WATCH_SCRIPT": execution.storageWatchScriptURL.path,
                "PCH_STORAGE_WATCH_SHA256": watcherHash,
            ]
        )
        let values = Self.protocolValues(result.output)
        let harnessEnabled = result.status == 0 && values["enabled"] == "true"
        let runtimeState = Self.runtimeState(
            protocolValues: values,
            expectedWatcherURL: execution.storageWatchScriptURL,
            expectedWatcherSHA256: watcherHash
        )
        let enabled = harnessEnabled && runtimeState == .current
        let detail: String
        if runtimeState == .stale {
            detail = "안전하지 않은 이전 감시 plist가 남았습니다. 감시를 껐다 다시 켜 제거하세요."
        } else {
            detail = enabled
                ? "매시간 확인 · 20GB 미만 또는 8GB 급감 시 알림"
                : "꺼짐 · 자동 삭제 없음"
        }
        return StorageWatchStatus(
            enabled: enabled,
            detail: detail,
            freeSpaceSamples: await loadFreeSpaceSamples()
        )
    }

    static func protocolValues(_ text: String) -> [String: String] {
        var values: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            if parts.count == 2 {
                values[String(parts[0])] = String(parts[1])
            }
        }
        return values
    }

    static func runtimeState(
        protocolValues: [String: String],
        expectedWatcherURL: URL,
        expectedWatcherSHA256: String? = nil,
        expectedHomeURL: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> StorageWatchRuntimeState {
        guard let plistPath = protocolValues["plist"], plistPath.hasPrefix("/") else {
            return .stale
        }
        if protocolValues["loaded"] == "true",
           protocolValues["loadedDefinitionCurrent"] != "true" {
            return .stale
        }
        let plistURL = URL(fileURLWithPath: plistPath)
        let expectedPlistURL = expectedHomeURL
            .appendingPathComponent("Library/LaunchAgents")
            .appendingPathComponent("me.heznpc.pchealthcheck.storage-watch.plist")
        guard let watcherHash = expectedWatcherSHA256 ?? secureSHA256(
            at: expectedWatcherURL,
            maximumBytes: 1_048_576
        ), watcherHash.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else {
            return .stale
        }
        let expectedArguments = [
            "/usr/bin/env",
            "-i",
            "HOME=\(expectedHomeURL.standardizedFileURL.path)",
            "PATH=\(LocalProcessRunner.safeSystemPath)",
            "LANG=en_US.UTF-8",
            "LC_ALL=en_US.UTF-8",
            "/bin/bash",
            "-p",
            "-c",
            storageWatchWrapper,
            "--",
            watcherHash,
            expectedWatcherURL.standardizedFileURL.path,
        ]
        let expectedKeys: Set<String> = [
            "Label",
            "ProgramArguments",
            "RunAtLoad",
            "StandardErrorPath",
            "StandardOutPath",
            "StartInterval",
        ]
        guard pathEntryExists(plistURL) else { return .absent }
        guard plistURL.standardizedFileURL == expectedPlistURL.standardizedFileURL,
              isSecureRegularFile(at: expectedWatcherURL, allowsRootOwner: true),
              secureSHA256(at: expectedWatcherURL, maximumBytes: 1_048_576) == watcherHash,
              isSecureRegularFile(at: plistURL, allowsRootOwner: false),
              !pathContainsSymbolicLink(plistURL.deletingLastPathComponent()),
              !pathContainsSymbolicLink(expectedWatcherURL.deletingLastPathComponent()),
              let data = try? SecureLocalFileIO.boundedRead(
                from: plistURL,
                maximumBytes: 65_536
              ),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dictionary = plist as? [String: Any],
              Set(dictionary.keys) == expectedKeys,
              dictionary["Label"] as? String == "me.heznpc.pchealthcheck.storage-watch",
              let arguments = dictionary["ProgramArguments"] as? [String],
              arguments == expectedArguments,
              (dictionary["StartInterval"] as? NSNumber)?.intValue == 3600,
              (dictionary["RunAtLoad"] as? NSNumber)?.boolValue == true,
              dictionary["StandardOutPath"] as? String == "/dev/null",
              dictionary["StandardErrorPath"] as? String == "/dev/null" else {
            return .stale
        }
        return .current
    }

    static let storageWatchWrapper = #"set -u; script="$2"; expected="$1"; [[ -f "$script" && ! -L "$script" ]] || exit 78; size=$(/usr/bin/stat -f "%z" "$script") || exit 78; [[ "$size" -le 1048576 ]] || exit 78; payload=$(/usr/bin/base64 < "$script") || exit 78; digest=$(/usr/bin/printf "%s" "$payload" | /usr/bin/base64 -D | /usr/bin/shasum -a 256) || exit 78; actual="${digest%% *}"; [[ "$actual" == "$expected" ]] || exit 78; /usr/bin/printf "%s" "$payload" | /usr/bin/base64 -D | /bin/bash -p"#

    private static func loadFreeSpaceSamples() async -> [FreeSpaceSample] {
        await Task.detached(priority: .utility) {
            StorageHistoryStore.loadFreeSpaceSamples()
        }.value
    }

    private static func pathEntryExists(_ url: URL) -> Bool {
        var value = stat()
        return url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return false }
            return Darwin.lstat(path, &value) == 0
        }
    }

    private static func isSecureRegularFile(
        at url: URL,
        allowsRootOwner: Bool
    ) -> Bool {
        var value = stat()
        let status = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return Darwin.lstat(path, &value)
        }
        let allowedOwner = value.st_uid == Darwin.geteuid()
            || (allowsRootOwner && value.st_uid == 0)
        return status == 0
            && value.st_mode & S_IFMT == S_IFREG
            && allowedOwner
            && value.st_mode & mode_t(S_IWGRP | S_IWOTH) == 0
    }

    private static func pathContainsSymbolicLink(_ url: URL) -> Bool {
        let standardized = url.standardizedFileURL
        guard standardized.path.hasPrefix("/") else { return true }
        var current = URL(fileURLWithPath: "/", isDirectory: true)
        for component in standardized.pathComponents.dropFirst() {
            current.appendPathComponent(component)
            if current.path == "/var" || current.path == "/tmp" {
                continue
            }
            var value = stat()
            let status = current.withUnsafeFileSystemRepresentation { path in
                guard let path else { return Int32(-1) }
                return Darwin.lstat(path, &value)
            }
            if status == 0, value.st_mode & S_IFMT == S_IFLNK { return true }
        }
        return false
    }

    private static func secureSHA256(
        at url: URL,
        maximumBytes: Int
    ) -> String? {
        guard let data = try? SecureLocalFileIO.boundedRead(
            from: url,
            maximumBytes: maximumBytes
        ) else {
            return nil
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
