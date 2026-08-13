import Foundation

/// Runs idle_cpu.sh and network_watch.sh concurrently over the same window,
/// on demand -- see the two scripts' own header comments for why this is a
/// bounded, user-triggered observation rather than a scheduled background
/// watch like storage_watch.sh. storage_watch.sh's launchd job is entirely
/// hardcoded to one script/label/plist (schedule.sh has no generic multi-job
/// concept), and CPU/network are fast, bursty signals where a fixed hourly
/// sample would almost always just catch them idle -- unlike free disk
/// space, which genuinely changes slowly enough for that cadence to make
/// sense. Windows' own scripts/monitor.ps1 is the cross-platform precedent
/// for this shape: synchronous, foreground, user-triggered, never scheduled.
enum ObservationOutcome {
    case ready(ObservationResult)
    case failure(String)
}

enum ObservationService {
    /// Pure and independently testable: idle_cpu.sh's own TSV protocol,
    /// `process\t{percent}\t{pid}\t{name}\t{ownerPid}\t{ownerName}\t{startedFromShell}`.
    static func parseProcessRows(_ output: String) -> [ObservedProcessRow] {
        output.split(separator: "\n").compactMap { line -> ObservedProcessRow? in
            let fields = line.components(separatedBy: "\t")
            guard fields.count == 7, fields[0] == "process",
                  let percent = Double(fields[1]), let pid = Int(fields[2]),
                  let ownerPid = Int(fields[4]) else { return nil }
            return ObservedProcessRow(
                percent: percent,
                pid: pid,
                name: fields[3],
                ownerPid: ownerPid,
                ownerName: fields[5],
                startedFromShell: fields[6] == "true"
            )
        }
    }

    /// Pure and independently testable: network_watch.sh's own TSV protocol,
    /// `established|listen\t{process}\t{pid}\t{address}`.
    static func parseConnectionRows(_ output: String) -> [ObservedConnectionRow] {
        output.split(separator: "\n").compactMap { line -> ObservedConnectionRow? in
            let fields = line.components(separatedBy: "\t")
            guard fields.count == 4, fields[0] == "established" || fields[0] == "listen",
                  let pid = Int(fields[2]) else { return nil }
            return ObservedConnectionRow(kind: fields[0], process: fields[1], pid: pid, address: fields[3])
        }
    }

    static func observe(projectRoot: URL, windowSeconds: Int) async -> ObservationOutcome {
        guard let execution = await Task.detached(priority: .userInitiated, operation: {
            RuntimeWorkspace.prepareExecution(projectRoot: projectRoot)
        }).value else {
            return .failure("서명된 실행 런타임을 확인하지 못해 실행하지 않았습니다.")
        }
        guard let cpuInvocation = execution.pinnedInvocation(relativePath: "scripts/idle_cpu.sh", name: "idle_cpu"),
              let networkInvocation = execution.pinnedInvocation(
                relativePath: "scripts/network_watch.sh",
                name: "network_watch"
              ) else {
            return .failure("봉인한 관찰 스크립트를 확인하지 못해 실행하지 않았습니다.")
        }

        let timeout = TimeInterval(windowSeconds + 20)
        async let cpuOutcome = run(
            argument: cpuInvocation.argument,
            files: cpuInvocation.files,
            arguments: ["--window", String(windowSeconds)],
            execution: execution,
            timeout: timeout
        )
        async let networkOutcome = run(
            argument: networkInvocation.argument,
            files: networkInvocation.files,
            arguments: ["--window", String(windowSeconds)],
            execution: execution,
            timeout: timeout
        )
        let (cpuResult, networkResult) = await (cpuOutcome, networkOutcome)

        guard case .success(let cpuOutput) = cpuResult else {
            if case .failure(let message) = cpuResult { return .failure(message) }
            return .failure("CPU 관찰을 실행하지 못했습니다.")
        }
        guard case .success(let networkOutput) = networkResult else {
            if case .failure(let message) = networkResult { return .failure(message) }
            return .failure("네트워크 관찰을 실행하지 못했습니다.")
        }

        let networkValues = StorageWatchService.protocolValues(networkOutput)
        return .ready(ObservationResult(
            windowSeconds: windowSeconds,
            processRows: parseProcessRows(cpuOutput),
            newConnectionRows: parseConnectionRows(networkOutput),
            networkUnavailable: networkValues["error"] != nil
        ))
    }

    private enum RawOutcome {
        case success(String)
        case failure(String)
    }

    private static func run(
        argument: String,
        files: [String: Data],
        arguments: [String],
        execution: RuntimeExecutionContext,
        timeout: TimeInterval
    ) async -> RawOutcome {
        let result = await LocalProcessRunner.capture(
            executable: "/bin/bash",
            arguments: [argument] + arguments,
            currentDirectory: execution.runtimeRoot,
            expectedCurrentDirectoryIdentity: execution.runtimeRootIdentity,
            expectedSignedBundleURL: execution.signedBundleURL,
            pinnedFiles: files,
            environment: [:],
            timeout: timeout
        )
        guard result.status == 0, result.endState == .exited else {
            return .failure("관찰 스크립트 실행이 실패했습니다 (status \(result.status)).")
        }
        return .success(result.output)
    }
}

extension ScanModel {
    func observeNow(windowSeconds: Int) {
        guard !observationInFlight else { return }
        observationInFlight = true
        observationErrorMessage = nil
        let root = projectRoot
        Task {
            defer { observationInFlight = false }
            switch await ObservationService.observe(projectRoot: root, windowSeconds: windowSeconds) {
            case .ready(let result):
                observationResult = result
            case .failure(let message):
                observationErrorMessage = message
            }
        }
    }
}
