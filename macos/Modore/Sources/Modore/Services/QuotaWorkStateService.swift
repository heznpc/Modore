import AppKit
import CryptoKit
import Foundation

/// Read-only work integration. QuotaPie owns quota collection and all resume
/// approvals; Modore owns discovery and inspection of local conversations.
struct QuotaWorkSnapshot: Decodable, Sendable {
    struct Account: Decodable, Sendable {
        let provider: String
        let account: String
        let label: String
        let profileKey: String?
        let collectionState: String
        let windows: [Window]
    }
    struct Window: Decodable, Sendable {
        let bucket: String
        let label: String
        let remainingPercent: Double?
        let resetsAtMs: Double?
        let observedAtMs: Double
        let freshness: String
        let validUntilMs: Double
    }
    struct Task: Decodable, Identifiable, Sendable {
        let id: String
        let provider: String
        let account: String
        let sessionKey: String
        let bucket: String
        let label: String
        let state: String
        let registeredAtMs: Double
        let readyAtMs: Double?

        var reviewURL: URL? { URL(string: "quotapie://resume/\(id)") }
        var statusText: String {
            switch state {
            case "ready": L10n.text("재개 가능 · QuotaPie에서 확인 필요")
            case "approved": L10n.text("재개 승인됨 · 실행 결과는 QuotaPie에서 확인")
            default: L10n.text("한도 회복 대기 중")
            }
        }
    }
    let schemaVersion: Int
    let generatedAtMs: Double
    let expiresAtMs: Double
    let accounts: [Account]
    let tasks: [Task]

    func isCurrent(now: Date = Date()) -> Bool {
        let ms = now.timeIntervalSince1970 * 1_000
        return generatedAtMs <= ms + 60_000 && expiresAtMs > ms
    }

    func linkedTasks(for session: SessionIndexEntry) -> [Task] {
        guard session.kind == "session", let nativeID = session.providerSessionId,
              let uuid = UUID(uuidString: nativeID) else { return [] }
        let provider = session.tool.lowercased()
        guard ["codex", "claude"].contains(provider) else { return [] }
        // Session IDs can be copied to another account's profile. Both the
        // account-scoped ID and canonical profile membership must agree.
        let candidates = tasks.filter { task in
            task.provider == provider && task.sessionKey == Self.sessionKey(
                provider: provider, account: task.account, nativeID: uuid.uuidString.lowercased())
        }
        guard !candidates.isEmpty else { return [] }
        let rootKey = Self.profileKey(of: session.sourceURL, provider: provider)
        return candidates.filter { task in
            guard
                  let account = accounts.first(where: { $0.provider == provider && $0.account == task.account }),
                  let profileKey = account.profileKey, rootKey == profileKey else { return false }
            return true
        }
    }

    func task(for session: SessionIndexEntry) -> Task? {
        let matches = linkedTasks(for: session)
        return matches.count == 1 ? matches.first : nil
    }

    func session(for taskID: String, in sessions: [SessionIndexEntry]) -> SessionIndexEntry? {
        guard let task = tasks.first(where: { $0.id == taskID }) else { return nil }
        // Resolve one requested task, without hashing every task against every
        // indexed conversation or touching unrelated session directories.
        let candidates = sessions.filter { session in
            guard session.kind == "session", session.tool.lowercased() == task.provider,
                  let nativeID = session.providerSessionId, UUID(uuidString: nativeID) != nil else { return false }
            return Self.sessionKey(provider: task.provider, account: task.account, nativeID: nativeID) == task.sessionKey
        }
        let matches = candidates.filter { linkedTasks(for: $0).contains { $0.id == taskID } }
        return matches.count == 1 ? matches.first : nil
    }

    static func sessionKey(provider: String, account: String, nativeID: String) -> String {
        digest("\(provider)\0\(account)\0\(nativeID.lowercased())")
    }

    static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func profileKey(of source: URL, provider: String) -> String? {
        var directory = source.resolvingSymlinksInPath().deletingLastPathComponent()
        let stores = provider == "codex" ? ["sessions", "archived_sessions"] : ["projects"]
        for _ in 0..<128 {
            guard directory.path != "/" else { break }
            if stores.contains(directory.lastPathComponent) {
                return digest(directory.deletingLastPathComponent().path)
            }
            directory.deleteLastPathComponent()
        }
        return nil
    }
}

enum QuotaWorkState: Sendable {
    case missing, invalid
    case available(QuotaWorkSnapshot)

    var snapshot: QuotaWorkSnapshot? {
        if case .available(let snapshot) = self { return snapshot }
        return nil
    }
}

struct QuotaWorkStateService {
    static var boundaryURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/QuotaPie/work-state.json")
    }

    static func read(from url: URL = boundaryURL) -> QuotaWorkState {
        do {
            let data = try SecureLocalFileIO.boundedRead(from: url, maximumBytes: 1_048_576, requireCurrentOwner: true)
            return decode(data)
        } catch let error as NSError where error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT) {
            return .missing
        } catch { return .invalid }
    }

    static func decode(_ data: Data) -> QuotaWorkState {
        guard let snapshot = try? JSONDecoder().decode(QuotaWorkSnapshot.self, from: data),
              snapshot.schemaVersion == 1,
              snapshot.generatedAtMs > 0,
              snapshot.expiresAtMs > snapshot.generatedAtMs,
              snapshot.expiresAtMs - snapshot.generatedAtMs <= 600_000,
              Set(snapshot.accounts.map { "\($0.provider)\0\($0.account)" }).count == snapshot.accounts.count,
              Set(snapshot.tasks.map(\.id)).count == snapshot.tasks.count,
              snapshot.accounts.allSatisfy({ account in
                  ["codex", "claude"].contains(account.provider) && !account.account.isEmpty &&
                  (account.profileKey == nil || isHash(account.profileKey!)) &&
                  account.windows.allSatisfy { window in
                      window.observedAtMs > 0 && window.validUntilMs >= window.observedAtMs &&
                      window.remainingPercent.map { (0...100).contains($0) } != false
                  }
              }),
              snapshot.tasks.allSatisfy({ task in
                  UUID(uuidString: task.id) != nil && task.id == task.id.lowercased() &&
                  isHash(task.sessionKey) && ["waiting", "ready", "approved"].contains(task.state) &&
                  snapshot.accounts.contains { $0.provider == task.provider && $0.account == task.account }
              }) else { return .invalid }
        return .available(snapshot)
    }

    private static func isHash(_ value: String) -> Bool {
        value.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}

/// Feature-owned state: integration refresh and navigation do not extend the
/// storage/cleanup transaction model or acquire provider credentials.
@MainActor
final class QuotaWorkModel: ObservableObject {
    @Published private(set) var state: QuotaWorkState = .missing
    @Published private(set) var revision = 0
    @Published var requestedTaskID: String?
    @Published var message: String?

    func refresh() async {
        let value = await Task.detached { QuotaWorkStateService.read() }.value
        guard !Task.isCancelled else { return }
        state = value
        revision += 1
    }

    func review(_ task: QuotaWorkSnapshot.Task) {
        guard let snapshot = state.snapshot, snapshot.isCurrent(),
              snapshot.tasks.contains(where: { $0.id == task.id }),
              let url = task.reviewURL, NSWorkspace.shared.open(url) else {
            message = L10n.text("QuotaPie를 열 수 없습니다. 앱과 최신 수집 상태를 확인하세요.")
            return
        }
    }
}
