import Foundation

enum WorkspaceSelectionKey {
    static func cleanup(_ item: StorageItem, mode: String) -> String {
        let identity = item.cleanupID.isEmpty ? item.path : item.cleanupID
        return "cleanup|\(mode)|\(identity)"
    }

    static func developmentAsset(_ item: StorageItem) -> String {
        "development|asset|\(storageIdentity(item))"
    }

    static func runtime(_ signal: RuntimeSignal) -> String {
        "development|runtime|\(signal.kind)|\(signal.label)"
    }

    static func application(_ item: StorageItem) -> String {
        "inventory|application|\(storageIdentity(item))"
    }

    static func simulator(_ device: SimulatorDevice) -> String {
        "inventory|simulator|\(device.uuid)"
    }

    static func repairedSelection(current: String?, candidates: [String]) -> String? {
        if let current, candidates.contains(current) {
            return current
        }
        return candidates.first
    }

    private static func storageIdentity(_ item: StorageItem) -> String {
        if !item.path.isEmpty { return item.path }
        if !item.cleanupID.isEmpty { return item.cleanupID }
        return "\(item.kind)|\(item.label)"
    }
}
