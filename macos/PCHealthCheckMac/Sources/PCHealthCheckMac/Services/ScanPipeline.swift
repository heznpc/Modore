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

        let scanner = await LocalProcessRunner.stream(
            executable: "/bin/bash",
            arguments: [
                execution.scannerScriptURL.path,
                "--output", execution.scanResultURL.path,
                "--raw", execution.rawFactsURL.path,
            ],
            currentDirectory: execution.runtimeRoot,
            environment: [
                "PCH_CONFIG_PATH": execution.configurationURL.path,
                "PCH_STORAGE_DU_TIMEOUT": "8",
                "PCH_STORAGE_TOTAL_DU_BUDGET": "32"
            ],
            onOutput: onOutput
        )
        guard scanner == 0 else {
            onOutput("scanner.sh 실패: \(scanner)")
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
        var environment = [
            "PCH_PROJECT_DIR": execution.outputRoot.path,
            "PCH_REPORT_OUTPUT": output.path
        ]
        if redacted {
            environment["PCH_REDACT"] = "true"
        }
        return await LocalProcessRunner.stream(
            executable: "/usr/bin/osascript",
            arguments: ["-l", "JavaScript", execution.reportScriptURL.path],
            currentDirectory: execution.runtimeRoot,
            environment: environment,
            onOutput: onOutput
        )
    }
}
