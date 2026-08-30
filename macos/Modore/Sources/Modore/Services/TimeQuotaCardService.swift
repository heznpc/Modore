import Foundation

/// The read side of the QuotaPie boundary contract.
///
/// QuotaPie writes `~/Library/Application Support/QuotaPie/quota.json`
/// atomically on every collection tick. Modore only reads that local boundary
/// file; provider credentials, network collection, and daemon ownership stay
/// in QuotaPie. A missing file means QuotaPie is not installed and remains
/// invisible. Once the file exists, however, stale or invalid data is a health
/// finding rather than a reason to silently remove the card.
struct TimeQuotaSnapshot: Sendable {
    struct Window: Decodable, Sendable {
        let provider: String
        let usedPercent: Double?
        let resetsAt: Date?

        private enum CodingKeys: String, CodingKey {
            case provider, usedPercent, resetsAt
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            provider = try values.decode(String.self, forKey: .provider)
            usedPercent = try values.decode(Double?.self, forKey: .usedPercent)
            resetsAt = try values.decode(Date?.self, forKey: .resetsAt)
        }
    }

    struct BurnRow: Decodable, Identifiable, Sendable {
        let id = UUID()
        let remote: String
        let percent: Double
        let lastActiveAt: Date?

        private enum CodingKeys: String, CodingKey {
            case remote, percent, lastActiveAt
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            remote = try values.decode(String.self, forKey: .remote)
            percent = try values.decode(Double.self, forKey: .percent)
            lastActiveAt = try values.decode(Date.self, forKey: .lastActiveAt)
        }
    }

    struct ProviderState: Identifiable, Sendable {
        enum State: String, Decodable, Sendable {
            case neverAttempted = "never-attempted"
            case attemptedThenFailed = "attempted-then-failed"
            case staleSuccess = "stale-success"
            case recentSuccess = "recent-success"
        }

        let id = UUID()
        let name: String
        let state: State
    }

    struct Headline: Decodable, Sendable {
        enum Kind: String, Decodable, Sendable {
            case normal
            case paceRisk = "pace-risk"
            case degraded
            case setup
        }

        enum WindowKind: String, Decodable, Sendable {
            case fiveHour = "five-hour"
            case weekly
            case monthly
            case other
        }

        enum ErrorCategory: String, Decodable, Sendable {
            case authRequired = "auth-required"
            case authExpired = "auth-expired"
            case rateLimited = "rate-limited"
            case network
            case notConfigured = "not-configured"
            case isolationUnsafe = "isolation-unsafe"
            case providerError = "provider-error"
            case noWindows = "no-windows"
        }

        let kind: Kind
        let provider: String?
        let account: String?
        let windowKind: WindowKind?
        let remainingPercent: Double?
        let exhaustsAt: Date?
        let errorCategory: ErrorCategory?
        let displayText: String
        let displayDetail: String?

        private enum CodingKeys: String, CodingKey {
            case kind, provider, account, windowKind, remainingPercent
            case exhaustsAt, errorCategory, displayText, displayDetail
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            kind = try values.decode(Kind.self, forKey: .kind)
            provider = try values.decode(String?.self, forKey: .provider)
            account = try values.decode(String?.self, forKey: .account)
            windowKind = try values.decode(WindowKind?.self, forKey: .windowKind)
            remainingPercent = try values.decode(Double?.self, forKey: .remainingPercent)
            exhaustsAt = try values.decode(Date?.self, forKey: .exhaustsAt)
            errorCategory = try values.decode(ErrorCategory?.self, forKey: .errorCategory)
            displayText = try values.decode(String.self, forKey: .displayText)
            displayDetail = try values.decode(String?.self, forKey: .displayDetail)
        }
    }

    let generatedAt: Date
    let collectionHealthy: Bool
    let providerStates: [ProviderState]
    let window: Window?
    let headline: Headline?
    let topBurn: [BurnRow]
}

enum TimeQuotaCardState: Sendable {
    /// The boundary file is current. `collectionHealthy` still decides whether
    /// its quota numbers are safe to present.
    case current(TimeQuotaSnapshot)
    /// The file parsed, but its age means the producer may have stopped.
    case stale(TimeQuotaSnapshot)
    /// A boundary file exists but cannot be trusted as schema v2.
    case invalid

    var snapshot: TimeQuotaSnapshot? {
        switch self {
        case .current(let snapshot), .stale(let snapshot): snapshot
        case .invalid: nil
        }
    }
}

/// Plain strings derived from QuotaPie's semantic v2 fields. Keeping this
/// outside SwiftUI makes it difficult for a screen to regress to treating a
/// low used percentage as reassuring when the producer concluded pace risk.
struct TimeQuotaCardPresentation {
    struct Notice: Equatable, Sendable {
        let symbol: String
        let title: String
        let detail: String
    }

    struct ProviderStatus: Equatable, Sendable {
        let symbol: String
        let title: String
        let detail: String
    }

    static func headlineNotice(for snapshot: TimeQuotaSnapshot) -> Notice? {
        guard let headline = snapshot.headline else { return nil }
        switch headline.kind {
        case .normal:
            return nil
        case .paceRisk:
            guard snapshot.collectionHealthy else { return nil }
            let provider = providerName(headline.provider ?? snapshot.window?.provider)
            let window = windowKindName(headline.windowKind)
            var facts: [String] = []
            if let remaining = headline.remainingPercent {
                facts.append("\(percentText(remaining)) 남음")
            }
            if let exhaustsAt = headline.exhaustsAt {
                facts.append("\(exhaustsAt.formatted(date: .abbreviated, time: .shortened))경 소진 예상")
            }
            return Notice(
                symbol: "exclamationmark.triangle",
                title: [provider, window, "소진 위험"].filter { !$0.isEmpty }.joined(separator: " "),
                detail: fallbackDetail(facts, headline: headline, defaultText: "현재 속도라면 리셋 전에 한도를 소진할 수 있습니다.")
            )
        case .degraded:
            let provider = providerName(headline.provider)
            return Notice(
                symbol: "clock.badge.questionmark",
                title: [provider, "한도 확인 지연"].filter { !$0.isEmpty }.joined(separator: " "),
                detail: recoveryText(
                    headline.errorCategory,
                    fallback: headline.displayDetail,
                    defaultText: "최근 한도 값을 확인할 수 없어 사용량 수치를 숨겼습니다."
                )
            )
        case .setup:
            let provider = providerName(headline.provider)
            return Notice(
                symbol: "exclamationmark.triangle",
                title: [provider, "설정 필요"].filter { !$0.isEmpty }.joined(separator: " "),
                detail: recoveryText(
                    headline.errorCategory,
                    fallback: headline.displayDetail,
                    defaultText: "QuotaPie에서 공급자 연결을 설정해야 합니다."
                )
            )
        }
    }

    static func headerValue(for state: TimeQuotaCardState) -> String {
        switch state {
        case .invalid:
            return "읽기 실패"
        case .stale:
            return "오래됨"
        case .current(let snapshot):
            if let headline = snapshot.headline {
                switch headline.kind {
                case .setup:
                    return "설정 필요"
                case .degraded:
                    return "확인 지연"
                case .paceRisk:
                    guard snapshot.collectionHealthy else { return "수집 실패" }
                    let provider = providerName(headline.provider ?? snapshot.window?.provider)
                    return [provider, "소진 위험"].filter { !$0.isEmpty }.joined(separator: " ")
                case .normal:
                    guard snapshot.collectionHealthy else { return "수집 실패" }
                    if let remaining = headline.remainingPercent {
                        let provider = providerName(headline.provider ?? snapshot.window?.provider)
                        return [provider, "\(percentText(remaining)) 남음"]
                            .filter { !$0.isEmpty }
                            .joined(separator: " ")
                    }
                    return "한도 확인됨"
                }
            }
            guard snapshot.collectionHealthy else { return "수집 실패" }
            guard let window = snapshot.window, let used = window.usedPercent else { return "" }
            return "\(providerName(window.provider)) \(percentText(used))"
        }
    }

    static func providerStatus(
        _ provider: TimeQuotaSnapshot.ProviderState,
        boundaryIsStale: Bool
    ) -> ProviderStatus {
        let state: String
        switch provider.state {
        case .recentSuccess: state = "수집 성공"
        case .neverAttempted: state = "수집 시작 전"
        case .attemptedThenFailed: state = "수집 실패"
        case .staleSuccess: state = "성공 기록이 오래됨"
        }
        let stateText = boundaryIsStale ? "마지막 기록상 \(state)" : recentStateText(provider.state)
        return ProviderStatus(
            symbol: !boundaryIsStale && provider.state == .recentSuccess
                ? "checkmark.circle"
                : "clock.badge.questionmark",
            title: "\(providerName(provider.name)): \(stateText)",
            detail: boundaryIsStale
                ? "오래된 경계 파일의 상태이며 현재 상태로 보지 않습니다."
                : "QuotaPie가 마지막 경계 파일에 기록한 공급자 수집 상태입니다."
        )
    }

    static func providerName(_ provider: String?) -> String {
        guard let provider, !provider.isEmpty else { return "" }
        if provider == "codex" { return "Codex" }
        if provider == "claude" { return "Claude" }
        if provider.hasPrefix("codex/") {
            return "Codex · \(provider.dropFirst("codex/".count))"
        }
        if provider.hasPrefix("claude/") {
            return "Claude · \(provider.dropFirst("claude/".count))"
        }
        return provider
    }

    static func percentText(_ value: Double) -> String {
        value == value.rounded()
            ? String(format: "%.0f%%", value)
            : String(format: "%.1f%%", value)
    }

    private static func recentStateText(_ state: TimeQuotaSnapshot.ProviderState.State) -> String {
        switch state {
        case .recentSuccess: return "최근 수집 성공"
        case .neverAttempted: return "수집 시작 전"
        case .attemptedThenFailed: return "수집 실패"
        case .staleSuccess: return "마지막 성공이 오래됨"
        }
    }

    private static func windowKindName(_ kind: TimeQuotaSnapshot.Headline.WindowKind?) -> String {
        switch kind {
        case .fiveHour: return "5시간"
        case .weekly: return "주간"
        case .monthly: return "월간"
        case .other, nil: return ""
        }
    }

    private static func fallbackDetail(
        _ facts: [String],
        headline: TimeQuotaSnapshot.Headline,
        defaultText: String
    ) -> String {
        if !facts.isEmpty { return facts.joined(separator: " · ") }
        if let detail = headline.displayDetail, !detail.isEmpty { return detail }
        if !headline.displayText.isEmpty { return headline.displayText }
        return defaultText
    }

    private static func recoveryText(
        _ category: TimeQuotaSnapshot.Headline.ErrorCategory?,
        fallback: String?,
        defaultText: String
    ) -> String {
        switch category {
        case .authRequired: return "QuotaPie에서 공급자 로그인이 필요합니다."
        case .authExpired: return "QuotaPie에서 공급자 로그인을 다시 연결해야 합니다."
        case .rateLimited: return "공급자 요청 한도 때문에 잠시 후 다시 확인해야 합니다."
        case .network: return "네트워크 연결을 확인한 뒤 QuotaPie 수집을 다시 시도하세요."
        case .notConfigured: return "QuotaPie에서 이 공급자의 수집 방식을 설정해야 합니다."
        case .isolationUnsafe: return "계정 격리를 확인할 수 없어 수집이 중단됐습니다."
        case .providerError: return "공급자 응답 오류로 최근 한도를 확인하지 못했습니다."
        case .noWindows: return "사용량 창을 아직 확인하지 못했습니다."
        case nil:
            if let fallback, !fallback.isEmpty { return fallback }
            return defaultText
        }
    }
}

enum TimeQuotaCardService {
    static let quotaFileURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/QuotaPie/quota.json")
    /// The producer ticks every few minutes; an hour of silence means it is
    /// not running, and a card built from its last write would present a
    /// stopped collector's numbers as current -- the exact "checkmark that
    /// only means installed" failure this codebase keeps relearning.
    static let staleAfter: TimeInterval = 60 * 60
    private static let maximumBytes = 64 * 1024

    /// Pure and independently testable: quota.json's published v2 shape.
    /// An unknown `schemaVersion` returns nil because fields could mean
    /// something else under a future contract. The caller turns that into a
    /// visible invalid-boundary finding without guessing at quota numbers.
    static func parse(_ data: Data) -> TimeQuotaSnapshot? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            guard let value = date(text) else {
                throw DecodingError.dataCorrupted(
                    .init(codingPath: decoder.codingPath, debugDescription: "Invalid ISO-8601 date")
                )
            }
            return value
        }
        guard let document = try? decoder.decode(BoundaryDocument.self, from: data),
              document.schemaVersion == 2,
              document.providerStates.allSatisfy({ !$0.name.isEmpty }),
              document.window.map(validWindow) ?? true,
              document.headline.map(validHeadline) ?? true,
              document.topBurn.allSatisfy(validBurnRow) else {
            return nil
        }
        return TimeQuotaSnapshot(
            generatedAt: document.generatedAt,
            collectionHealthy: document.collectionHealthy,
            providerStates: document.providerStates.sorted { $0.name < $1.name },
            window: document.window,
            headline: document.headline,
            topBurn: document.topBurn
        )
    }

    private static func validWindow(_ window: TimeQuotaSnapshot.Window) -> Bool {
        !window.provider.isEmpty && (window.usedPercent.map(validPercentage) ?? true)
    }

    private static func validHeadline(_ headline: TimeQuotaSnapshot.Headline) -> Bool {
        (headline.provider.map { $0 == "codex" || $0 == "claude" } ?? true)
            && (headline.account.map { !$0.isEmpty } ?? true)
            && (headline.remainingPercent.map(validPercentage) ?? true)
    }

    private static func validBurnRow(_ row: TimeQuotaSnapshot.BurnRow) -> Bool {
        !row.remote.isEmpty && validPercentage(row.percent) && row.lastActiveAt != nil
    }

    private static func validPercentage(_ value: Double) -> Bool {
        value.isFinite && (0 ... 100).contains(value)
    }

    /// Custom decoding keeps nullable fields required: `null` is a published
    /// state, while an omitted key means the v2 contract was not written.
    private struct BoundaryDocument: Decodable {
        let schemaVersion: Int
        let generatedAt: Date
        let collectionHealthy: Bool
        let providerStates: [TimeQuotaSnapshot.ProviderState]
        let window: TimeQuotaSnapshot.Window?
        let headline: TimeQuotaSnapshot.Headline?
        let topBurn: [TimeQuotaSnapshot.BurnRow]

        private enum CodingKeys: String, CodingKey {
            case schemaVersion, generatedAt, collection, window, headline, topBurn
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
            generatedAt = try values.decode(Date.self, forKey: .generatedAt)
            let collection = try values.decode(Collection.self, forKey: .collection)
            collectionHealthy = collection.healthy
            providerStates = collection.providers.map {
                .init(name: $0.key, state: $0.value)
            }
            window = try values.decode(TimeQuotaSnapshot.Window?.self, forKey: .window)
            headline = try values.decode(TimeQuotaSnapshot.Headline?.self, forKey: .headline)
            topBurn = try values.decode([TimeQuotaSnapshot.BurnRow].self, forKey: .topBurn)
        }

        private struct Collection: Decodable {
            let healthy: Bool
            let providers: [String: TimeQuotaSnapshot.ProviderState.State]

            private enum CodingKeys: String, CodingKey {
                case lastSampleAt, healthy, providers
            }

            init(from decoder: Decoder) throws {
                let values = try decoder.container(keyedBy: CodingKeys.self)
                _ = try values.decode(Date?.self, forKey: .lastSampleAt)
                healthy = try values.decode(Bool.self, forKey: .healthy)
                providers = try values.decode(
                    [String: TimeQuotaSnapshot.ProviderState.State].self,
                    forKey: .providers
                )
            }
        }
    }

    /// A future `generatedAt` is as untrustworthy as an old one -- a clock
    /// jump between producer and consumer must read as "cannot tell", not as
    /// maximally fresh. Same rule ScanModel applies to its own snapshot age.
    static func isFresh(_ snapshot: TimeQuotaSnapshot, now: Date = Date()) -> Bool {
        let age = now.timeIntervalSince(snapshot.generatedAt)
        return age >= -60 && age <= staleAfter
    }

    static func cardState(for data: Data, now: Date = Date()) -> TimeQuotaCardState {
        guard let snapshot = parse(data) else { return .invalid }
        return isFresh(snapshot, now: now) ? .current(snapshot) : .stale(snapshot)
    }

    static func loadCardState(
        from url: URL = quotaFileURL,
        now: Date = Date()
    ) -> TimeQuotaCardState? {
        let data: Data
        do {
            // The no-follow bounded open is both the existence check and the
            // read. A separate FileManager probe would follow a swapped
            // symlink before the boundary that is meant to reject it.
            data = try SecureLocalFileIO.boundedRead(
                from: url,
                maximumBytes: maximumBytes,
                requireCurrentOwner: true
            )
        } catch let error as NSError
        where error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT) {
            // No file (or no producer directory) means no QuotaPie installation
            // to integrate with. Do not advertise a dependency that is absent.
            return nil
        } catch {
            // Existing but unreadable, oversized, or wrong-owner files are
            // visible as an invalid local boundary. No bytes escape Modore.
            return .invalid
        }
        return cardState(for: data, now: now)
    }

    // Formatters are built per call: ISO8601DateFormatter is not Sendable,
    // so a cached static is rejected by the strict-concurrency (release)
    // build, and one quota.json carries about ten dates -- caching buys
    // nothing worth the shared mutable state.
    private static func date(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let parsed = fractional.date(from: text) { return parsed }
        return ISO8601DateFormatter().date(from: text)
    }
}

extension ScanModel {
    func refreshTimeQuotaCard() async {
        let state = await Task.detached(priority: .utility) {
            TimeQuotaCardService.loadCardState()
        }.value
        guard !Task.isCancelled else { return }
        timeQuotaCardState = state
    }
}
