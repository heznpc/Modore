import Darwin
import Foundation

enum ScanPipeline {
    static func run(
        projectRoot: URL,
        onOutput: @escaping @Sendable (String) -> Void
    ) async -> Bool {
        guard let execution = RuntimeWorkspace.prepareExecution(projectRoot: projectRoot) else {
            onOutput("검사 런타임 무결성을 확인하지 못해 실행을 중단했습니다.")
            return false
        }

        guard let configurationData = configurationSnapshot(at: execution.configurationURL) else {
            onOutput("사용자 설정을 안전하게 읽지 못해 검사를 중단했습니다.")
            return false
        }
        var scannerEnvironment = scanEnvironment(
            configurationData: configurationData
        )
        scannerEnvironment["PCH_PROJECT_DIR"] = execution.outputRoot.path
        let usesSealedRuntime = execution.sealedRuntimeFiles != nil
        let scanWorkingDirectory = usesSealedRuntime
            ? execution.outputRoot : execution.runtimeRoot
        let scanWorkingIdentity = usesSealedRuntime
            ? execution.outputRootIdentity : execution.runtimeRootIdentity
        let scanOutputArgument = usesSealedRuntime
            ? execution.scanResultURL.lastPathComponent : execution.scanResultURL.path
        let rawOutputArgument = usesSealedRuntime
            ? execution.rawFactsURL.lastPathComponent : execution.rawFactsURL.path
        var scannerScript = "scripts/scanner.sh"
        var pinnedScannerFiles: [String: Data] = ["configuration": configurationData]
        scannerEnvironment["PCH_CONFIG_PATH"] = pinnedPlaceholder("configuration")
        scannerEnvironment["PCH_PINNED_CONFIG"] = pinnedPlaceholder("configuration")
        if let payload = execution.sealedRuntimeFiles {
            let resources: [(name: String, path: String, environment: String?)] = [
                ("scanner", "scripts/scanner.sh", nil),
                ("cpu", "scripts/modules/macos/cpu.sh", "PCH_PINNED_CPU_MODULE"),
                ("network", "scripts/modules/macos/network.sh", "PCH_PINNED_NETWORK_MODULE"),
                ("autoruns", "scripts/modules/macos/autoruns.sh", "PCH_PINNED_AUTORUNS_MODULE"),
                ("security", "scripts/modules/macos/security.sh", "PCH_PINNED_SECURITY_MODULE"),
                ("storage", "scripts/modules/macos/storage.sh", "PCH_PINNED_STORAGE_MODULE"),
                ("helper", "scripts/scanner_helper.jxa.js", "PCH_PINNED_SCANNER_HELPER"),
                ("whitelist", "data/whitelist.json", "PCH_PINNED_WHITELIST"),
                ("rule_autoruns", "rules/autoruns.json", "PCH_PINNED_RULE_AUTORUNS"),
                ("rule_defender", "rules/defender.json", "PCH_PINNED_RULE_DEFENDER"),
                ("rule_installs", "rules/installs.json", "PCH_PINNED_RULE_INSTALLS"),
                ("rule_network", "rules/network.json", "PCH_PINNED_RULE_NETWORK"),
                ("rule_process", "rules/process.json", "PCH_PINNED_RULE_PROCESS"),
            ]
            for resource in resources {
                guard let contents = payload[resource.path] else {
                    onOutput("서명 시점에 봉인한 검사 리소스가 없어 실행을 중단했습니다: \(resource.path)")
                    return false
                }
                pinnedScannerFiles[resource.name] = contents
                if let environmentName = resource.environment {
                    scannerEnvironment[environmentName] = pinnedPlaceholder(resource.name)
                }
            }
            scannerScript = pinnedPlaceholder("scanner")
        }

        let previousScanGeneration = RegularFileGeneration.capture(execution.scanResultURL)
        let previousRawGeneration = RegularFileGeneration.capture(execution.rawFactsURL)
        let scanner = await LocalProcessRunner.stream(
            executable: "/bin/bash",
            arguments: [
                scannerScript,
                "--output", scanOutputArgument,
                "--raw", rawOutputArgument,
            ],
            currentDirectory: scanWorkingDirectory,
            expectedCurrentDirectoryIdentity: scanWorkingIdentity,
            expectedSignedBundleURL: execution.signedBundleURL,
            pinnedFiles: pinnedScannerFiles,
            environment: scannerEnvironment,
            onOutput: onOutput
        )
        guard scanner == 0 else {
            onOutput("scanner.sh 실패: \(scanner)")
            return false
        }
        guard FilesystemIdentity.directory(at: execution.outputRoot) == execution.outputRootIdentity,
              RegularFileGeneration.capture(execution.scanResultURL) != previousScanGeneration,
              RegularFileGeneration.capture(execution.rawFactsURL) != previousRawGeneration,
              scanOutputsAreConsistent(
                scanResultURL: execution.scanResultURL,
                rawFactsURL: execution.rawFactsURL,
                expectedParentIdentity: execution.outputRootIdentity
              ) else {
            onOutput("이번 실행의 새 검사 결과를 확인하지 못해 이전 결과 사용을 차단했습니다.")
            return false
        }

        guard let normalReportExecution = RuntimeWorkspace.prepareExecution(projectRoot: projectRoot) else {
            onOutput("리포트 런타임 서명을 다시 확인하지 못해 생성을 중단했습니다.")
            return false
        }
        let normal = await runReport(
            execution: normalReportExecution,
            output: normalReportExecution.outputRoot.appendingPathComponent("검사결과.html"),
            redacted: false,
            onOutput: onOutput
        )
        guard normal == 0 else {
            onOutput("일반 리포트 생성 실패: \(normal)")
            return false
        }

        guard let shareReportExecution = RuntimeWorkspace.prepareExecution(projectRoot: projectRoot) else {
            onOutput("공유용 리포트 런타임 서명을 다시 확인하지 못해 생성을 중단했습니다.")
            return false
        }
        let share = await runReport(
            execution: shareReportExecution,
            output: shareReportExecution.outputRoot.appendingPathComponent("검사결과_공유용.html"),
            redacted: true,
            onOutput: onOutput
        )
        guard share == 0 else {
            onOutput("공유용 리포트 생성 실패: \(share)")
            return false
        }
        return true
    }

    private static func runReport(
        execution: RuntimeExecutionContext,
        output: URL,
        redacted: Bool,
        onOutput: @escaping @Sendable (String) -> Void
    ) async -> Int32 {
        let usesSealedRuntime = execution.sealedRuntimeFiles != nil
        let reportWorkingDirectory = usesSealedRuntime
            ? execution.outputRoot : execution.runtimeRoot
        let reportWorkingIdentity = usesSealedRuntime
            ? execution.outputRootIdentity : execution.runtimeRootIdentity
        var environment = [
            "PCH_PROJECT_DIR": execution.outputRoot.path,
            "PCH_REPORT_OUTPUT": usesSealedRuntime ? output.lastPathComponent : output.path
        ]
        if redacted {
            environment["PCH_REDACT"] = "true"
        }
        var reportScript = "scripts/report.jxa.js"
        var pinnedFiles: [String: Data] = [:]
        if let payload = execution.sealedRuntimeFiles {
            guard let reportData = payload["scripts/report.jxa.js"],
                  let scanData = try? ScanResultLoader.boundedData(
                    contentsOf: execution.scanResultURL,
                    maximumBytes: ScanResultLoader.maximumScanResultBytes,
                    expectedParentIdentity: execution.outputRootIdentity
                  ) else {
                onOutput("봉인한 리포트 코드 또는 이번 검사 결과를 읽지 못했습니다.")
                return -1
            }
            pinnedFiles["report"] = reportData
            pinnedFiles["scan_result"] = scanData
            reportScript = pinnedPlaceholder("report")
            environment["PCH_SCAN"] = pinnedPlaceholder("scan_result")
        }
        let previousGeneration = RegularFileGeneration.capture(output)
        let status: Int32
        if usesSealedRuntime {
            environment.removeValue(forKey: "PCH_SCAN")
            status = await LocalProcessRunner.stream(
                executable: "/bin/bash",
                arguments: [
                    "-p", "-c",
                    #"umask 077; report_source="$1"; scan_source="$2"; export PCH_SCAN=/dev/fd/3; /usr/bin/osascript -l JavaScript - < "$report_source" 3< "$scan_source""#,
                    "--", reportScript, pinnedPlaceholder("scan_result"),
                ],
                currentDirectory: reportWorkingDirectory,
                expectedCurrentDirectoryIdentity: reportWorkingIdentity,
                expectedSignedBundleURL: execution.signedBundleURL,
                pinnedFiles: pinnedFiles,
                environment: environment,
                onOutput: onOutput
            )
        } else {
            status = await LocalProcessRunner.stream(
                executable: "/bin/bash",
                arguments: [
                    "-p", "-c",
                    #"umask 077; exec /usr/bin/osascript -l JavaScript "$1""#,
                    "--", reportScript,
                ],
                currentDirectory: reportWorkingDirectory,
                expectedCurrentDirectoryIdentity: reportWorkingIdentity,
                expectedSignedBundleURL: execution.signedBundleURL,
                pinnedFiles: pinnedFiles,
                environment: environment,
                onOutput: onOutput
            )
        }
        guard status == 0,
              FilesystemIdentity.directory(at: execution.outputRoot) == execution.outputRootIdentity,
              RegularFileGeneration.capture(output) != previousGeneration else {
            if status == 0 {
                onOutput("이번 실행의 새 리포트 파일을 확인하지 못했습니다.")
                return -1
            }
            return status
        }
        guard finalizeGeneratedReport(
            at: output,
            expectedParentIdentity: execution.outputRootIdentity
        ) else {
            onOutput("새 리포트를 소유자 전용 파일로 확정하지 못했습니다.")
            return -1
        }
        return 0
    }

    /// Re-publishes generated HTML through the same dirfd-bound atomic writer
    /// used for other private local state. The report generator is signed, but
    /// its default process umask can still create a 0644 file.
    static func finalizeGeneratedReport(
        at output: URL,
        expectedParentIdentity: FilesystemIdentity
    ) -> Bool {
        guard let report = try? SecureLocalFileIO.boundedRead(
            from: output,
            maximumBytes: 128 * 1_024 * 1_024,
            requireCurrentOwner: true,
            expectedParentIdentity: expectedParentIdentity
        ), !report.isEmpty else {
            return false
        }
        do {
            try SecureLocalFileIO.atomicWrite(
                report,
                to: output,
                permissions: 0o600,
                expectedParentIdentity: expectedParentIdentity
            )
            return true
        } catch {
            return false
        }
    }

    static func scanEnvironment(
        configurationURL: URL,
        processEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        guard let configurationData = configurationSnapshot(at: configurationURL) else {
            return scanEnvironment(
                configurationData: Data(),
                processEnvironment: processEnvironment
            )
        }
        return scanEnvironment(
            configurationData: configurationData,
            processEnvironment: processEnvironment
        )
    }

    private static func scanEnvironment(
        configurationData: Data,
        processEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var result = [
            "PCH_STORAGE_DU_TIMEOUT": "8",
            "PCH_STORAGE_TOTAL_DU_BUDGET": "32",
        ]

        // An ambient key is treated only as secret material. Network lookup still
        // requires the user's config to say enabled=true explicitly.
        if virusTotalIsExplicitlyEnabled(in: configurationData),
           let key = processEnvironment["VT_API_KEY"]?.trimmingCharacters(
            in: .whitespacesAndNewlines
           ),
           !key.isEmpty {
            result["VT_API_KEY"] = key
        }

        for name in ["ANDROID_HOME", "ANDROID_SDK_ROOT"] {
            guard let rawPath = processEnvironment[name],
                  let path = validatedDirectoryPath(rawPath) else { continue }
            result[name] = path
        }
        return result
    }

    private static func configurationSnapshot(at configurationURL: URL) -> Data? {
        guard let parentIdentity = FilesystemIdentity.directory(
            at: configurationURL.deletingLastPathComponent()
        ),
              let data = try? SecureLocalFileIO.boundedRead(
                from: configurationURL,
                maximumBytes: 1_048_576,
                requireCurrentOwner: true,
                expectedParentIdentity: parentIdentity
              ) else {
            return nil
        }
        return data
    }

    private static func virusTotalIsExplicitlyEnabled(in data: Data) -> Bool {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let configuration = root["virustotal"] as? [String: Any] else {
            return false
        }
        return configuration["enabled"] as? Bool == true
    }

    private static func validatedDirectoryPath(_ rawPath: String) -> String? {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/"), !trimmed.utf8.contains(0) else { return nil }
        let candidate = URL(fileURLWithPath: trimmed, isDirectory: true).standardizedFileURL
        guard candidate.resolvingSymlinksInPath().standardizedFileURL == candidate,
              let values = try? candidate.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
              ),
              values.isDirectory == true,
              values.isSymbolicLink != true else {
            return nil
        }
        return candidate.path
    }

    private static func scanOutputsAreConsistent(
        scanResultURL: URL,
        rawFactsURL: URL,
        expectedParentIdentity: FilesystemIdentity
    ) -> Bool {
        func scannedAt(_ url: URL) -> String? {
            guard let data = try? ScanResultLoader.boundedData(
                contentsOf: url,
                maximumBytes: ScanResultLoader.maximumScanResultBytes,
                expectedParentIdentity: expectedParentIdentity
            ),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  root["schemaVersion"] != nil,
                  let value = root["scannedAt"] as? String,
                  !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            return value
        }
        guard let scanTimestamp = scannedAt(scanResultURL),
              let rawTimestamp = scannedAt(rawFactsURL) else { return false }
        return scanTimestamp == rawTimestamp
    }

    static func pinnedPlaceholder(_ name: String) -> String {
        "@pch-pinned:\(name)"
    }
}

private struct RegularFileGeneration: Equatable {
    let device: UInt64
    let inode: UInt64
    let size: Int64
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64

    static func capture(_ url: URL) -> RegularFileGeneration? {
        var value = stat()
        let status = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return Darwin.lstat(path, &value)
        }
        guard status == 0, value.st_mode & S_IFMT == S_IFREG else { return nil }
        return RegularFileGeneration(
            device: UInt64(bitPattern: Int64(value.st_dev)),
            inode: UInt64(value.st_ino),
            size: Int64(value.st_size),
            modifiedSeconds: Int64(value.st_mtimespec.tv_sec),
            modifiedNanoseconds: Int64(value.st_mtimespec.tv_nsec)
        )
    }
}
