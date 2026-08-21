import Foundation

/// The read side of the TimeQuota boundary contract.
///
/// TimeQuota (a separate local app, github.com/heznpc/timequota) writes
/// `~/Library/Application Support/TimeQuota/quota.json` atomically on every
/// collection tick. Merging the two products was considered and rejected --
/// their release postures differ -- so this file IS the integration: Modore
/// only ever reads it. Consumer rules agreed with the producer:
///   - file absent or unparseable  -> no card at all (not an error)
///   - `generatedAt` stale         -> no card (a dead producer must not keep
///                                    presenting last week's numbers as now)
///   - fresh but `healthy: false`  -> say collection is broken, show no
///                                    numbers (the producer's own heartbeat
///                                    verdict outranks whatever it sampled)
struct TimeQuotaSnapshot {
    struct Window {
        let provider: String
        let usedPercent: Double
        let resetsAt: Date?
    }

    struct BurnRow: Identifiable {
        let id = UUID()
        let remote: String
        let percent: Double
        let lastActiveAt: Date?
    }

    struct ProviderState: Identifiable {
        let id = UUID()
        let name: String
        let state: String
    }

    let generatedAt: Date
    let collectionHealthy: Bool
    let providerStates: [ProviderState]
    let window: Window?
    let topBurn: [BurnRow]
}

enum TimeQuotaCardService {
    static let quotaFileURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/TimeQuota/quota.json")
    /// The producer ticks every few minutes; an hour of silence means it is
    /// not running, and a card built from its last write would present a
    /// stopped collector's numbers as current -- the exact "checkmark that
    /// only means installed" failure this codebase keeps relearning.
    static let staleAfter: TimeInterval = 60 * 60
    private static let maximumBytes = 64 * 1024

    /// Pure and independently testable: quota.json's agreed v1 shape.
    /// An unknown `schemaVersion` returns nil -- fields could mean something
    /// else under a future contract, and a hidden card is the agreed failure
    /// mode, not a guessed one.
    static func parse(_ data: Data) -> TimeQuotaSnapshot? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              (root["schemaVersion"] as? NSNumber)?.intValue == 1,
              let generatedAt = date(root["generatedAt"]),
              let collection = root["collection"] as? [String: Any],
              let healthy = collection["healthy"] as? Bool else {
            return nil
        }

        let providerStates = ((collection["providers"] as? [String: Any]) ?? [:])
            .compactMap { name, value -> TimeQuotaSnapshot.ProviderState? in
                guard let state = value as? String, !state.isEmpty else { return nil }
                return TimeQuotaSnapshot.ProviderState(name: name, state: state)
            }
            .sorted { $0.name < $1.name }

        var window: TimeQuotaSnapshot.Window?
        if let raw = root["window"] as? [String: Any],
           let provider = raw["provider"] as? String, !provider.isEmpty,
           let usedPercent = (raw["usedPercent"] as? NSNumber)?.doubleValue,
           usedPercent.isFinite {
            window = TimeQuotaSnapshot.Window(
                provider: provider,
                usedPercent: usedPercent,
                resetsAt: date(raw["resetsAt"])
            )
        }

        let topBurn = ((root["topBurn"] as? [[String: Any]]) ?? [])
            .compactMap { raw -> TimeQuotaSnapshot.BurnRow? in
                guard let remote = raw["remote"] as? String, !remote.isEmpty,
                      let percent = (raw["percent"] as? NSNumber)?.doubleValue,
                      percent.isFinite else { return nil }
                return TimeQuotaSnapshot.BurnRow(
                    remote: remote,
                    percent: percent,
                    lastActiveAt: date(raw["lastActiveAt"])
                )
            }

        return TimeQuotaSnapshot(
            generatedAt: generatedAt,
            collectionHealthy: healthy,
            providerStates: providerStates,
            window: window,
            topBurn: topBurn
        )
    }

    /// A future `generatedAt` is as untrustworthy as an old one -- a clock
    /// jump between producer and consumer must read as "cannot tell", not as
    /// maximally fresh. Same rule ScanModel applies to its own snapshot age.
    static func isFresh(_ snapshot: TimeQuotaSnapshot, now: Date = Date()) -> Bool {
        let age = now.timeIntervalSince(snapshot.generatedAt)
        return age >= -60 && age <= staleAfter
    }

    static func loadDisplayable(now: Date = Date()) -> TimeQuotaSnapshot? {
        guard let data = try? SecureLocalFileIO.boundedRead(
            from: quotaFileURL,
            maximumBytes: maximumBytes,
            requireCurrentOwner: true
        ), let snapshot = parse(data), isFresh(snapshot, now: now) else {
            return nil
        }
        return snapshot
    }

    // Formatters are built per call: ISO8601DateFormatter is not Sendable,
    // so a cached static is rejected by the strict-concurrency (release)
    // build, and one quota.json carries about ten dates -- caching buys
    // nothing worth the shared mutable state.
    private static func date(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let parsed = fractional.date(from: text) { return parsed }
        return ISO8601DateFormatter().date(from: text)
    }
}

extension ScanModel {
    func refreshTimeQuotaCard() {
        Task {
            timeQuotaSnapshot = await Task.detached(priority: .utility) {
                TimeQuotaCardService.loadDisplayable()
            }.value
        }
    }
}
