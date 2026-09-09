import Foundation

struct AssetRetirementPlan: Decodable {
    let id: String
    var items: [AssetRetirementItem]
    let receipt: String
}

struct AssetRetirementFile: Decodable, Identifiable {
    var id: String { path }
    let path: String
    let keep: Bool
    let generated: Bool
    let bytes: Int64
}

struct AssetRetirementRemote: Decodable { let full_name: String }

struct AssetRetirementItem: Decodable, Identifiable {
    let id: String
    let path: String
    let remote: AssetRetirementRemote?
    let archive: Bool
    let local: Bool
    let deleteGenerated: Bool
    let warnings: [String]
    let approved: Bool
    let changed: Bool
    let error: String
    let archiveMutation: String
    let archiveVerification: String
    let localMutation: String
    let localVerification: String
    let beforeFree: Int64?
    let afterFree: Int64?
    let deleteBytes: Int64
    let keepBytes: Int64
    let generatedBytes: Int64
    let deletedCount: Int
    var isFinished: Bool {
        (!archive || (archiveMutation == "succeeded" && archiveVerification == "verified"))
            && (!local || (localMutation == "succeeded" && localVerification == "verified"))
    }
    let files: [AssetRetirementFile]
}

struct AssetRetirementChoice: Identifiable {
    let id = UUID()
    var path: String
    var archive = false
    var local = true
    var deleteGenerated = false
    var request: [String: Any] {
        ["path": path, "archive": archive, "local": local, "deleteGenerated": deleteGenerated]
    }
}
