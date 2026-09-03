import Darwin
import Foundation

enum PipelineStageState: String, Sendable, Equatable {
    case notAttempted
    case succeeded
    case failed
}

struct ScanRunResult: Sendable, Equatable {
    let scan: PipelineStageState
    let normalReport: PipelineStageState
    let shareReport: PipelineStageState

    static let scanFailed = ScanRunResult(
        scan: .failed,
        normalReport: .notAttempted,
        shareReport: .notAttempted
    )

    var scanSucceeded: Bool { scan == .succeeded }
    var reportsSucceeded: Bool {
        normalReport == .succeeded && shareReport == .succeeded
    }
}

struct ScanPipelineProcessRequest: Sendable {
    let executable: String
    let arguments: [String]
    let currentDirectory: URL
    let expectedCurrentDirectoryIdentity: FilesystemIdentity
    let expectedSignedBundleURL: URL?
    let pinnedFiles: [String: Data]
    let environment: [String: String]
}

struct ScanPipelineDependencies: Sendable {
    let prepareExecution: @Sendable (URL) -> RuntimeExecutionContext?
    let runProcess: @Sendable (
        ScanPipelineProcessRequest,
        @escaping @Sendable (String) -> Void
    ) async -> Int32

    static let live = ScanPipelineDependencies(
        prepareExecution: { RuntimeWorkspace.prepareExecution(projectRoot: $0) },
        runProcess: { request, onOutput in
            await LocalProcessRunner.stream(
                executable: request.executable,
                arguments: request.arguments,
                currentDirectory: request.currentDirectory,
                expectedCurrentDirectoryIdentity: request.expectedCurrentDirectoryIdentity,
                expectedSignedBundleURL: request.expectedSignedBundleURL,
                pinnedFiles: request.pinnedFiles,
                environment: request.environment,
                onOutput: onOutput
            )
        }
    )
}

private struct PublishedScanSnapshot: Sendable {
    let data: Data
    let outputRoot: URL
    let outputRootIdentity: FilesystemIdentity
    let canonicalIdentity: FilesystemIdentity
}

enum ScanPipeline {
    static func run(
        projectRoot: URL,
        dependencies: ScanPipelineDependencies = .live,
        onOutput: @escaping @Sendable (String) -> Void
    ) async -> ScanRunResult {
        guard !Task.isCancelled else { return .scanFailed }
        guard let execution = dependencies.prepareExecution(projectRoot) else {
            onOutput("검사 런타임 무결성을 확인하지 못해 실행을 중단했습니다.")
            return .scanFailed
        }
        guard !Task.isCancelled else { return .scanFailed }

        guard let configurationData = configurationSnapshot(at: execution.configurationURL) else {
            onOutput("사용자 설정을 안전하게 읽지 못해 검사를 중단했습니다.")
            return .scanFailed
        }
        guard !Task.isCancelled else { return .scanFailed }
        guard let stagedOutput = try? ScanPublication.prepare(
            in: execution.outputRoot,
            expectedParentIdentity: execution.outputRootIdentity
        ) else {
            onOutput("검증 전 검사 결과를 격리할 작업 공간을 만들지 못했습니다.")
            return .scanFailed
        }
        defer { ScanPublication.discard(stagedOutput) }

        var scannerEnvironment = scanEnvironment(
            configurationData: configurationData
        )
        scannerEnvironment["PCH_PROJECT_DIR"] = execution.outputRoot.path
        let usesSealedRuntime = execution.sealedRuntimeFiles != nil
        let scanWorkingDirectory = usesSealedRuntime
            ? stagedOutput.directoryURL : execution.runtimeRoot
        let scanWorkingIdentity = usesSealedRuntime
            ? stagedOutput.directoryIdentity : execution.runtimeRootIdentity
        let scanOutputArgument = usesSealedRuntime
            ? stagedOutput.scanResultURL.lastPathComponent : stagedOutput.scanResultURL.path
        let rawOutputArgument = usesSealedRuntime
            ? stagedOutput.rawFactsURL.lastPathComponent : stagedOutput.rawFactsURL.path
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
                ("idle_cpu", "scripts/modules/macos/idle_cpu.sh", "PCH_PINNED_IDLE_CPU_MODULE"),
                ("idle_cpu_script", "scripts/idle_cpu.sh", "PCH_PINNED_IDLE_CPU_SCRIPT"),
                ("privacy", "scripts/modules/macos/privacy.sh", "PCH_PINNED_PRIVACY_MODULE"),
                ("devtool_updates", "scripts/modules/macos/devtool_updates.sh", "PCH_PINNED_DEVTOOL_UPDATES_MODULE"),
                ("support_dir", "scripts/modules/support_dir.sh", "PCH_PINNED_SUPPORT_DIR_MODULE"),
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
                    return .scanFailed
                }
                pinnedScannerFiles[resource.name] = contents
                if let environmentName = resource.environment {
                    scannerEnvironment[environmentName] = pinnedPlaceholder(resource.name)
                }
            }
            scannerScript = pinnedPlaceholder("scanner")
        }

        guard !Task.isCancelled else { return .scanFailed }
        let scanner = await dependencies.runProcess(
            ScanPipelineProcessRequest(
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
                environment: scannerEnvironment
            ),
            onOutput
        )
        guard !Task.isCancelled else { return .scanFailed }
        guard scanner == 0 else {
            onOutput("scanner.sh 실패: \(scanner)")
            return .scanFailed
        }
        guard FilesystemIdentity.directory(at: execution.outputRoot) == execution.outputRootIdentity,
              FilesystemIdentity.directory(at: stagedOutput.directoryURL)
                == stagedOutput.directoryIdentity,
              RegularFileGeneration.capture(stagedOutput.scanResultURL) != nil,
              RegularFileGeneration.capture(stagedOutput.rawFactsURL) != nil,
              ScanPublication.outputsAreConsistent(stagedOutput) else {
            onOutput("이번 실행의 새 검사 결과를 확인하지 못해 이전 결과 사용을 차단했습니다.")
            return .scanFailed
        }
        guard !Task.isCancelled else { return .scanFailed }
        guard ScanPublication.publish(
            stagedOutput,
            in: execution.outputRoot,
            expectedParentIdentity: execution.outputRootIdentity
        ) else {
            onOutput("검증한 검사 결과를 신뢰 상태로 승격하지 못했습니다.")
            return .scanFailed
        }

        guard let scanSnapshot = publishedScanSnapshot(
            execution: execution,
            expectedCanonicalIdentity: stagedOutput.directoryIdentity
        ) else {
            onOutput("게시한 검사 결과의 정확한 입력 스냅샷을 고정하지 못했습니다.")
            return ScanRunResult(
                scan: .succeeded,
                normalReport: .failed,
                shareReport: .failed
            )
        }

        guard !Task.isCancelled else {
            return ScanRunResult(
                scan: .succeeded,
                normalReport: .notAttempted,
                shareReport: .notAttempted
            )
        }
        let normalReport = await generateReport(
            projectRoot: projectRoot,
            fileName: "검사결과.html",
            redacted: false,
            label: "일반 리포트",
            scanSnapshot: scanSnapshot,
            dependencies: dependencies,
            onOutput: onOutput
        )
        guard !Task.isCancelled else {
            return ScanRunResult(
                scan: .succeeded,
                normalReport: normalReport,
                shareReport: .notAttempted
            )
        }
        let shareReport = await generateReport(
            projectRoot: projectRoot,
            fileName: "검사결과_공유용.html",
            redacted: true,
            label: "공유용 리포트",
            scanSnapshot: scanSnapshot,
            dependencies: dependencies,
            onOutput: onOutput
        )
        guard !Task.isCancelled else {
            return ScanRunResult(
                scan: .succeeded,
                normalReport: normalReport,
                shareReport: shareReport
            )
        }
        return ScanRunResult(
            scan: .succeeded,
            normalReport: normalReport,
            shareReport: shareReport
        )
    }

    private static func generateReport(
        projectRoot: URL,
        fileName: String,
        redacted: Bool,
        label: String,
        scanSnapshot: PublishedScanSnapshot,
        dependencies: ScanPipelineDependencies,
        onOutput: @escaping @Sendable (String) -> Void
    ) async -> PipelineStageState {
        guard !Task.isCancelled else { return .notAttempted }
        guard let execution = dependencies.prepareExecution(projectRoot) else {
            onOutput("\(label) 런타임 서명을 다시 확인하지 못해 생성을 중단했습니다.")
            return .failed
        }
        guard !Task.isCancelled else { return .notAttempted }
        let status = await runReport(
            execution: execution,
            output: execution.outputRoot.appendingPathComponent(fileName),
            redacted: redacted,
            scanSnapshot: scanSnapshot,
            dependencies: dependencies,
            onOutput: onOutput
        )
        guard !Task.isCancelled else { return .notAttempted }
        guard status == 0 else {
            onOutput("\(label) 생성 실패: \(status)")
            return .failed
        }
        return .succeeded
    }

    private static func runReport(
        execution: RuntimeExecutionContext,
        output: URL,
        redacted: Bool,
        scanSnapshot: PublishedScanSnapshot,
        dependencies: ScanPipelineDependencies,
        onOutput: @escaping @Sendable (String) -> Void
    ) async -> Int32 {
        guard !Task.isCancelled else { return LocalProcessRunner.cancellationStatus }
        let usesSealedRuntime = execution.sealedRuntimeFiles != nil
        let reportWorkingDirectory = usesSealedRuntime
            ? execution.outputRoot : execution.runtimeRoot
        let reportWorkingIdentity = usesSealedRuntime
            ? execution.outputRootIdentity : execution.runtimeRootIdentity
        var environment = [
            "PCH_PROJECT_DIR": execution.outputRoot.path,
        ]
        if redacted {
            environment["PCH_REDACT"] = "true"
        }
        var reportScript = "scripts/report.jxa.js"
        guard let stagedOutput = try? ScanPublication.prepare(
            in: execution.outputRoot,
            expectedParentIdentity: execution.outputRootIdentity
        ) else {
            onOutput("\(redacted ? "공유용" : "일반") 리포트의 임시 작업 공간을 만들지 못했습니다.")
            return -1
        }
        defer { ScanPublication.discard(stagedOutput) }
        let stagedReport = stagedOutput.directoryURL.appendingPathComponent(
            output.lastPathComponent
        )
        environment["PCH_REPORT_OUTPUT"] = usesSealedRuntime
            ? stagedOutput.directoryURL.lastPathComponent + "/" + output.lastPathComponent
            : stagedReport.path
        guard execution.outputRoot.standardizedFileURL
                == scanSnapshot.outputRoot.standardizedFileURL,
              execution.outputRootIdentity == scanSnapshot.outputRootIdentity,
              FilesystemIdentity.directory(at: execution.outputRoot)
                == scanSnapshot.outputRootIdentity,
              ScanPublication.canonicalDirectory(in: execution.outputRoot)?.identity
                == scanSnapshot.canonicalIdentity else {
            onOutput("게시한 검사 결과와 리포트 출력 위치의 연결을 다시 확인하지 못했습니다.")
            return -1
        }
        guard !Task.isCancelled else { return LocalProcessRunner.cancellationStatus }
        var pinnedFiles: [String: Data] = ["scan_result": scanSnapshot.data]
        if let payload = execution.sealedRuntimeFiles {
            guard let reportData = payload["scripts/report.jxa.js"] else {
                onOutput("봉인한 리포트 코드를 읽지 못했습니다.")
                return -1
            }
            pinnedFiles["report"] = reportData
            reportScript = pinnedPlaceholder("report")
        }
        let previousGeneration = RegularFileGeneration.capture(stagedReport)
        let status: Int32
        if usesSealedRuntime {
            environment.removeValue(forKey: "PCH_SCAN")
            status = await dependencies.runProcess(
                ScanPipelineProcessRequest(
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
                    environment: environment
                ),
                onOutput
            )
        } else {
            status = await dependencies.runProcess(
                ScanPipelineProcessRequest(
                    executable: "/bin/bash",
                    arguments: [
                        "-p", "-c",
                        #"umask 077; scan_source="$2"; export PCH_SCAN=/dev/fd/3; exec /usr/bin/osascript -l JavaScript "$1" 3< "$scan_source""#,
                        "--", reportScript, pinnedPlaceholder("scan_result"),
                    ],
                    currentDirectory: reportWorkingDirectory,
                    expectedCurrentDirectoryIdentity: reportWorkingIdentity,
                    expectedSignedBundleURL: execution.signedBundleURL,
                    pinnedFiles: pinnedFiles,
                    environment: environment
                ),
                onOutput
            )
        }
        guard !Task.isCancelled else { return LocalProcessRunner.cancellationStatus }
        guard status == 0,
              FilesystemIdentity.directory(at: execution.outputRoot) == execution.outputRootIdentity,
              FilesystemIdentity.directory(at: stagedOutput.directoryURL)
                == stagedOutput.directoryIdentity,
              ScanPublication.canonicalDirectory(in: execution.outputRoot)?.identity
                == scanSnapshot.canonicalIdentity,
              RegularFileGeneration.capture(stagedReport) != previousGeneration else {
            if status == 0 {
                onOutput("이번 실행의 검사 세대가 바뀌었거나 새 리포트 파일을 확인하지 못했습니다.")
                return -1
            }
            return status
        }
        guard let report = try? SecureLocalFileIO.boundedRead(
            from: stagedReport,
            maximumBytes: 128 * 1_024 * 1_024,
            requireCurrentOwner: true,
            expectedParentIdentity: stagedOutput.directoryIdentity
        ), !report.isEmpty else {
            onOutput("새 리포트를 안전하게 읽지 못했습니다.")
            return -1
        }
        guard !Task.isCancelled else { return LocalProcessRunner.cancellationStatus }
        do {
            try SecureLocalFileIO.atomicWrite(
                report,
                to: output,
                permissions: 0o600,
                expectedParentIdentity: execution.outputRootIdentity
            )
        } catch {
            onOutput("새 리포트를 소유자 전용 파일로 확정하지 못했습니다.")
            return -1
        }
        return 0
    }

    private static func publishedScanSnapshot(
        execution: RuntimeExecutionContext,
        expectedCanonicalIdentity: FilesystemIdentity
    ) -> PublishedScanSnapshot? {
        guard FilesystemIdentity.directory(at: execution.outputRoot)
                == execution.outputRootIdentity,
              let canonical = ScanPublication.canonicalDirectory(in: execution.outputRoot),
              canonical.identity == expectedCanonicalIdentity else {
            return nil
        }
        let scanURL = canonical.url.appendingPathComponent("scan_result.json")
        guard let generation = RegularFileGeneration.capture(scanURL),
              let data = try? ScanResultLoader.boundedData(
                contentsOf: scanURL,
                maximumBytes: ScanResultLoader.maximumScanResultBytes,
                expectedParentIdentity: canonical.identity
              ),
              RegularFileGeneration.capture(scanURL) == generation,
              ScanPublication.canonicalDirectory(in: execution.outputRoot)?.identity
                == canonical.identity else {
            return nil
        }
        return PublishedScanSnapshot(
            data: data,
            outputRoot: execution.outputRoot,
            outputRootIdentity: execution.outputRootIdentity,
            canonicalIdentity: canonical.identity
        )
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

    static func pinnedPlaceholder(_ name: String) -> String {
        "@pch-pinned:\(name)"
    }
}

private struct RegularFileGeneration: Equatable, Sendable {
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
