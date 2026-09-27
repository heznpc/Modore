import Foundation

struct SessionRecoveryItem: Decodable, Identifiable {
    let id, provider, label, source, kind: String
    let bytes: Int64
    let fileCount: Int
    let available: Bool
    let reason: String
}

struct SessionRecoveryCoverage: Decodable, Identifiable {
    var id: String { provider }
    let provider: String
    let recordCount, gitLinkedCount, folderLinkedCount, unassignedCount: Int
    let resumeSupport: String
}

struct SessionRecoveryPlan: Decodable {
    let schemaVersion: Int
    let status: String
    let items: [SessionRecoveryItem]
    let warnings, excluded: [String]
    let coverage: [SessionRecoveryCoverage]

    var availableIDs: Set<String> { Set(items.filter(\.available).map(\.id)) }

    func selectedBytes(_ ids: Set<String>) -> Int64 {
        items.filter { $0.available && ids.contains($0.id) }.reduce(0) { sum, item in
            let result = sum.addingReportingOverflow(item.bytes)
            return result.overflow ? Int64.max : result.partialValue
        }
    }

    var isValid: Bool {
        schemaVersion == 1 && status == "planned"
            && Set(items.map(\.id)).count == items.count
            && items.allSatisfy { !$0.id.isEmpty && $0.source.hasPrefix("/") && $0.bytes >= 0 && $0.fileCount >= 0 }
            && Set(coverage.map(\.provider)).count == coverage.count
            && coverage.allSatisfy {
                $0.recordCount >= 0 && $0.gitLinkedCount >= 0
                    && $0.folderLinkedCount >= 0 && $0.unassignedCount >= 0
            }
    }
}

struct SessionRecoveryReceipt: Decodable {
    let schemaVersion: Int
    let status, bundle: String
    let fileCount: Int
    let totalBytes: Int64
    let providers, warnings: [String]
    let restoredRoot: String?

    var summary: String {
        L10n.format("%@개 파일 · %@ · SHA-256 일치", String(fileCount),
                    ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file))
    }
}

enum SessionRecoveryOperation {
    case plan
    case backup(destination: URL, itemIDs: [String])
    case verify(bundle: URL)
    case restore(bundle: URL, destination: URL)

    func arguments(homeOverride: URL? = nil) throws -> [String] {
        var result: [String]
        switch self {
        case .plan: result = ["plan"]
        case .backup(let destination, let ids):
            guard !ids.isEmpty, Set(ids).count == ids.count, ids.allSatisfy({ !$0.isEmpty }) else {
                throw SessionRecoveryFailure(message: L10n.text("보관할 원본을 선택하세요."))
            }
            let data = try JSONEncoder().encode(ids)
            result = ["backup", "--destination", destination.path, "--items-json",
                      String(decoding: data, as: UTF8.self), "--include-sensitive"]
        case .verify(let bundle): result = ["verify", bundle.path]
        case .restore(let bundle, let destination):
            result = ["restore", bundle.path, "--destination", destination.path]
        }
        if let homeOverride {
            switch self {
            case .plan, .backup: result += ["--home", homeOverride.path]
            default: break
            }
        }
        return result
    }

    var timeout: TimeInterval {
        if case .plan = self { return 180 }
        return 7_200
    }

    func accepts(_ receipt: SessionRecoveryReceipt) -> Bool {
        guard receipt.schemaVersion == 1, receipt.fileCount > 0,
              receipt.totalBytes >= 0, !receipt.providers.isEmpty else { return false }
        switch self {
        case .plan: return false
        case .backup(let destination, _):
            return receipt.status == "verified" && Self.samePath(receipt.bundle, destination)
        case .verify(let bundle):
            return receipt.status == "verified" && Self.samePath(receipt.bundle, bundle)
        case .restore(let bundle, let destination):
            return receipt.status == "restored" && Self.samePath(receipt.bundle, bundle)
                && receipt.restoredRoot.map { Self.samePath($0, destination) } == true
        }
    }

    private static func samePath(_ path: String, _ url: URL) -> Bool {
        path.hasPrefix("/") && URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
            == url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    static func backupDestination(in parent: URL, now: Date = Date(), identifier: UUID = UUID()) -> URL {
        let date = DateFormatter()
        date.locale = Locale(identifier: "en_US_POSIX")
        date.dateFormat = "yyyy-MM-dd"
        return parent.appendingPathComponent("Backup", isDirectory: true)
            .appendingPathComponent(date.string(from: now), isDirectory: true)
            .appendingPathComponent("Modore-\(identifier.uuidString.prefix(8))", isDirectory: true)
    }
}

enum SessionRecoveryResponse {
    case plan(SessionRecoveryPlan)
    case receipt(SessionRecoveryReceipt)
}

struct SessionRecoveryFailure: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct SessionResumeCandidate: Decodable, Identifiable {
    let id, provider, sessionId, label: String
    let workspace: String?
    let sourcePath: String
}

struct SessionResumeList: Decodable {
    let sessions: [SessionResumeCandidate]
    let warnings: [String]

    var isValid: Bool {
        Set(sessions.map(\.id)).count == sessions.count && sessions.allSatisfy {
            !$0.id.isEmpty && !$0.sessionId.isEmpty && ["codex", "claude"].contains($0.provider)
        }
    }
}

struct SessionResumePlan: Decodable {
    let provider, sessionId: String
    let argv: [String]
    let environment: [String: String]
    let workingDirectory: String?
    let status: String
    let limitations: [String]
    let providerHome: String?
    let sourcePaths, preparedPaths: [String]
    let cliVersion: String?

    func matches(_ candidate: SessionResumeCandidate, workspace: URL, home: URL) -> Bool {
        guard provider == candidate.provider, sessionId == candidate.sessionId,
              ["ready_to_try", "unsupported"].contains(status) else { return false }
        if status == "unsupported" { return argv.isEmpty && environment.isEmpty }
        return Self.samePath(workingDirectory, workspace)
            && Self.samePath(providerHome, home)
            && !argv.isEmpty && argv[0].hasPrefix("/")
            && environment.keys.allSatisfy { ["CODEX_HOME", "CLAUDE_CONFIG_DIR", "HOME", "CLAUDE_CODE_PROJECT_DIR_NAME"].contains($0) }
            && Self.samePath(environment[provider == "codex" ? "CODEX_HOME" : "CLAUDE_CONFIG_DIR"], home)
            && Self.samePath(environment["HOME"], home.appendingPathComponent("user-home"))
    }

    private static func samePath(_ path: String?, _ url: URL) -> Bool {
        guard let path, path.hasPrefix("/") else { return false }
        // Python returns physical /private/var paths while Foundation may
        // abbreviate them to /var. Canonicalize both sides, not just the URL.
        return URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
            == url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// This is a copyable command only. The app does not execute it or send an
    /// LLM request. Quote every path and argument, including provider metadata.
    var shellCommand: String {
        guard status == "ready_to_try", let workingDirectory else { return "" }
        let assignments = environment.keys.sorted().map { $0 + "=" + Self.shellQuote(environment[$0]!) }
        return "cd " + Self.shellQuote(workingDirectory) + " && env "
            + (assignments + argv.map(Self.shellQuote)).joined(separator: " ")
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
