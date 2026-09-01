import CryptoKit
import Darwin
import Foundation

enum StorageWatchRuntimeState: Equatable, Sendable {
    case absent
    case current
    case stale
}

// A stuck or crashing watch and a disabled one look identical from
// StorageWatchRuntimeState alone: both simply have no fresh
// storage-samples.tsv row. This is the independent signal that actually
// distinguishes them, derived from the heartbeat the WATCH_WRAPPER writes
// on every scheduled fire (see schedule.sh) against the freshest confirmed
// success already available from storage-samples.tsv.
enum StorageWatchHealthState: Equatable, Sendable {
    /// No heartbeat file, or it has no lastAttemptAt: the watch has never
    /// actually fired, regardless of what runtimeState says about the
    /// installed plist.
    case neverAttempted
    /// The most recent attempt is not (yet) followed by a success newer
    /// than it -- either the run just failed/crashed, or it's still in
    /// flight. Both read the same to the user: "something's wrong right now."
    case attemptedThenFailed
    /// The freshest success is within one missed hourly run's grace.
    case recentSuccess
    /// There has been a success at some point, but not recently enough to
    /// trust that the watch is still running -- distinct from
    /// attemptedThenFailed because there's no evidence of a *recent*
    /// attempt either; this is more "gone quiet" than "actively failing."
    case staleSuccess
}

struct StorageWatchStatus: Sendable {
    let enabled: Bool
    let detail: String
    let freeSpaceSamples: [FreeSpaceSample]?
    let healthState: StorageWatchHealthState
}

enum StorageWatchService {
    static func status(projectRoot: URL) async -> StorageWatchStatus {
        let samples = await loadFreeSpaceSamples()
        let health = healthState(freshestSuccessAt: samples.last?.checkedAt)
        guard let execution = await Task.detached(priority: .utility, operation: {
            RuntimeWorkspace.prepareExecution(projectRoot: projectRoot)
        }).value else {
            return StorageWatchStatus(
                enabled: false,
                detail: "서명된 감시 런타임을 확인할 수 없음",
                freeSpaceSamples: samples,
                healthState: health
            )
        }
        guard let invocation = execution.pinnedInvocation(
            relativePath: "scripts/schedule.sh",
            name: "schedule"
        ) else {
            return StorageWatchStatus(
                enabled: false,
                detail: "봉인한 감시 설정 프로그램을 확인할 수 없음",
                freeSpaceSamples: samples,
                healthState: health
            )
        }
        guard let watcherHash = execution.sealedSHA256(
            relativePath: "scripts/storage_watch.sh"
        ) else {
            return StorageWatchStatus(
                enabled: false,
                detail: "봉인한 저장공간 감시 프로그램을 확인할 수 없음",
                freeSpaceSamples: samples,
                healthState: health
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
                "PCH_STORAGE_WATCH_APP_BUNDLE": Bundle.main.bundleURL.path,
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
        } else if enabled {
            switch health {
            case .neverAttempted:
                detail = "매시간 확인 · 20GB 미만 또는 8GB 급감 시 알림 · 아직 실행 전"
            case .attemptedThenFailed:
                detail = "매시간 확인 · 최근 실행이 완료되지 않았습니다"
            case .recentSuccess:
                detail = "매시간 확인 · 20GB 미만 또는 8GB 급감 시 알림"
            case .staleSuccess:
                detail = "매시간 확인 · 최근 실행 기록이 오래됐습니다"
            }
        } else {
            detail = "꺼짐 · 자동 삭제 없음"
        }
        return StorageWatchStatus(
            enabled: enabled,
            detail: detail,
            freeSpaceSamples: samples,
            healthState: health
        )
    }

    static var heartbeatURL: URL {
        StorageHistoryStore.stateDirectory.appendingPathComponent("storage-watch-heartbeat.tsv")
    }

    /// One missed hourly run (StartInterval 3600 in schedule.sh) plus buffer
    /// for the sleep/wake catch-up delay launchd itself introduces.
    static let heartbeatStalenessInterval: TimeInterval = 135 * 60

    static func healthState(
        heartbeatURL: URL = heartbeatURL,
        freshestSuccessAt: Date?,
        now: Date = Date()
    ) -> StorageWatchHealthState {
        guard let parentIdentity = FilesystemIdentity.directory(
            at: heartbeatURL.deletingLastPathComponent()
        ),
              let data = try? SecureLocalFileIO.boundedRead(
                from: heartbeatURL,
                maximumBytes: 4_096,
                requireCurrentOwner: true,
                expectedParentIdentity: parentIdentity
              ),
              let text = String(data: data, encoding: .utf8) else {
            return .neverAttempted
        }
        let values = Self.protocolValues(text)
        guard let attemptString = values["lastAttemptAt"],
              let attemptAt = try? Date.ISO8601FormatStyle().parse(attemptString) else {
            return .neverAttempted
        }
        let exitString = values["lastExitCode"]
        let finishedString = values["lastFinishedAt"]
        if exitString != nil || finishedString != nil {
            guard let exitString,
                  let exitCode = Int(exitString),
                  (0...255).contains(exitCode),
                  let finishedString,
                  (try? Date.ISO8601FormatStyle().parse(finishedString)) != nil,
                  exitCode == 0 else {
                return .attemptedThenFailed
            }
        }
        guard let freshestSuccessAt else {
            return .attemptedThenFailed
        }
        let successAge = now.timeIntervalSince(freshestSuccessAt)
        guard successAge >= -StorageHistoryStore.futureTimestampTolerance else {
            // A clock jump or corrupted future row cannot mask a real current
            // failed attempt or keep the watch healthy indefinitely.
            return .attemptedThenFailed
        }
        if attemptAt > freshestSuccessAt {
            return .attemptedThenFailed
        }
        return successAge <= heartbeatStalenessInterval
            ? .recentSuccess
            : .staleSuccess
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

    /// `expectedAppBundlePath` must match what `schedule.sh` actually writes
    /// into ProgramArguments. That script has emitted a
    /// `PCH_STORAGE_WATCH_APP_BUNDLE=` entry unconditionally since the watch
    /// notification moved under the app's own identity, but this expectation
    /// was never updated to match, so the exact-array comparison below could
    /// never succeed: every freshly installed plist was judged `.stale`, the
    /// toggle reported failure, and the UI showed the watch as off while
    /// launchd had in fact loaded the job.
    static func runtimeState(
        protocolValues: [String: String],
        expectedWatcherURL: URL,
        expectedWatcherSHA256: String? = nil,
        expectedHomeURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        expectedAppBundlePath: String = Bundle.main.bundleURL.path,
        expectedAppExecutableSHA256: String? = nil
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
            .appendingPathComponent("me.heznpc.modore.storage-watch.plist")
        guard let watcherHash = expectedWatcherSHA256 ?? secureSHA256(
            at: expectedWatcherURL,
            maximumBytes: 1_048_576
        ), watcherHash.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else {
            return .stale
        }
        guard let appExecutableHash = expectedAppExecutableSHA256
                ?? appExecutableSHA256(at: URL(fileURLWithPath: expectedAppBundlePath)),
              appExecutableHash.range(
                of: "^[0-9a-f]{64}$",
                options: .regularExpression
              ) != nil else {
            return .stale
        }
        let expectedArguments = [
            "/usr/bin/env",
            "-i",
            "HOME=\(expectedHomeURL.standardizedFileURL.path)",
            "PATH=\(LocalProcessRunner.safeSystemPath)",
            "LANG=en_US.UTF-8",
            "LC_ALL=en_US.UTF-8",
            "PCH_STORAGE_WATCH_APP_BUNDLE=\(expectedAppBundlePath)",
            "PCH_STORAGE_WATCH_APP_EXECUTABLE_SHA256=\(appExecutableHash)",
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
              dictionary["Label"] as? String == "me.heznpc.modore.storage-watch",
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

    static let storageWatchWrapper = #"set -u; script="$2"; expected="$1"; hb="$HOME/Library/Application Support/Modore/storage-watch-heartbeat.tsv"; hbdir="$(/usr/bin/dirname "$hb")"; hb_write() { [[ -d "$hbdir" && ! -L "$hbdir" && ! -L "$hb" ]] || return 0; local tmp="$(/usr/bin/mktemp "$hbdir/.storage-watch-heartbeat.XXXXXX" 2>/dev/null)"; [[ -n "$tmp" ]] || return 0; /usr/bin/printf "%s" "$1" > "$tmp" 2>/dev/null || { /bin/rm -f "$tmp" 2>/dev/null; return 0; }; /bin/chmod 600 "$tmp" 2>/dev/null; /bin/mv -f "$tmp" "$hb" 2>/dev/null || /bin/rm -f "$tmp" 2>/dev/null; }; attempt_at="$(/bin/date -u "+%Y-%m-%dT%H:%M:%SZ")"; hb_write "$(/usr/bin/printf "lastAttemptAt\t%s\n" "$attempt_at")"; [[ -f "$script" && ! -L "$script" ]] || exit 78; size=$(/usr/bin/stat -f "%z" "$script") || exit 78; [[ "$size" -le 1048576 ]] || exit 78; payload=$(/usr/bin/base64 < "$script") || exit 78; digest=$(/usr/bin/printf "%s" "$payload" | /usr/bin/base64 -D | /usr/bin/shasum -a 256) || exit 78; actual="${digest%% *}"; [[ "$actual" == "$expected" ]] || exit 78; /usr/bin/printf "%s" "$payload" | /usr/bin/base64 -D | /bin/bash -p; ec=$?; hb_write "$(/usr/bin/printf "lastAttemptAt\t%s\nlastExitCode\t%s\nlastFinishedAt\t%s\n" "$attempt_at" "$ec" "$(/bin/date -u "+%Y-%m-%dT%H:%M:%SZ")")"; exit "$ec""#

    static func appExecutableSHA256(at bundleURL: URL) -> String? {
        guard let bundle = Bundle(url: bundleURL),
              bundle.bundleIdentifier == "me.heznpc.modore",
              let executableURL = bundle.executableURL,
              !pathContainsSymbolicLink(bundleURL),
              !pathContainsSymbolicLink(executableURL),
              isSecureRegularFile(at: executableURL, allowsRootOwner: true) else {
            return nil
        }
        return secureSHA256(at: executableURL, maximumBytes: 256 * 1_024 * 1_024)
    }

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
