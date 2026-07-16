import Foundation

struct SimulatorKeepMigration: Equatable {
    let uuids: Set<String>
    let unresolvedEntries: Set<String>
}

struct SimulatorKeepState: Equatable {
    let uuids: Set<String>
    let legacyEntries: Set<String>

    func resolvingLegacyEntries(with devices: [SimulatorDevice]) -> SimulatorKeepMigration {
        var resolvedUUIDs = uuids
        var unresolved = legacyEntries
        for entry in legacyEntries {
            let matches = devices.filter { $0.name == entry }
            guard !matches.isEmpty else { continue }
            matches.forEach { resolvedUUIDs.insert($0.uuid.uppercased()) }
            unresolved.remove(entry)
        }
        return SimulatorKeepMigration(uuids: resolvedUUIDs, unresolvedEntries: unresolved)
    }
}

enum SimulatorKeepStore {
    private static var url: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/PC Health Check/simulator-keep.txt")
    }

    static func load() -> SimulatorKeepState {
        guard let data = try? SecureLocalFileIO.boundedRead(
            from: url,
            maximumBytes: 65_536
        ), let text = String(data: data, encoding: .utf8) else {
            return SimulatorKeepState(uuids: [], legacyEntries: [])
        }
        let entries = Set(text.split(whereSeparator: \.isNewline).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty })
        let uuids = Set(entries.map { $0.uppercased() }.filter(isUUID))
        let legacyEntries = entries.filter { !isUUID($0.uppercased()) }
        return SimulatorKeepState(uuids: uuids, legacyEntries: legacyEntries)
    }

    static func save(_ uuids: Set<String>) throws {
        let normalized = Set(uuids.map { $0.uppercased() }.filter(isUUID))
        let text = normalized.sorted().joined(separator: "\n") + (normalized.isEmpty ? "" : "\n")
        try SecureLocalFileIO.atomicWrite(
            Data(text.utf8),
            to: url,
            permissions: 0o600
        )
    }

    private static func isUUID(_ value: String) -> Bool {
        value.range(
            of: #"^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$"#,
            options: .regularExpression
        ) != nil
    }
}
