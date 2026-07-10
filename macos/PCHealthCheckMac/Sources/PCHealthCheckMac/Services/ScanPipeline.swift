import Foundation

enum ScanPipeline {
    static func run(
        projectRoot: URL,
        onOutput: @escaping @Sendable (String) -> Void
    ) async -> Bool {
        let scanner = await LocalProcessRunner.stream(
            executable: "/bin/bash",
            arguments: ["./scripts/scanner.sh"],
            currentDirectory: projectRoot,
            environment: [
                "PCH_STORAGE_DU_TIMEOUT": "8",
                "PCH_STORAGE_TOTAL_DU_BUDGET": "32"
            ],
            onOutput: onOutput
        )
        guard scanner == 0 else {
            onOutput("scanner.sh 실패: \(scanner)")
            return false
        }

        let normal = await runReport(
            projectRoot: projectRoot,
            output: projectRoot.appendingPathComponent("검사결과.html"),
            redacted: false,
            onOutput: onOutput
        )
        guard normal == 0 else {
            onOutput("일반 리포트 생성 실패: \(normal)")
            return false
        }

        let share = await runReport(
            projectRoot: projectRoot,
            output: projectRoot.appendingPathComponent("검사결과_공유용.html"),
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
        projectRoot: URL,
        output: URL,
        redacted: Bool,
        onOutput: @escaping @Sendable (String) -> Void
    ) async -> Int32 {
        var environment = [
            "PCH_PROJECT_DIR": projectRoot.path,
            "PCH_REPORT_OUTPUT": output.path
        ]
        if redacted {
            environment["PCH_REDACT"] = "true"
        }
        return await LocalProcessRunner.stream(
            executable: "/usr/bin/osascript",
            arguments: ["-l", "JavaScript", projectRoot.appendingPathComponent("scripts/report.jxa.js").path],
            currentDirectory: projectRoot,
            environment: environment,
            onOutput: onOutput
        )
    }
}
