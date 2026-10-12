import Foundation

struct SupplementalStorageAudit: Sendable {
    struct Path: Sendable {
        let path: String
        let bytes: Int64?
        let classification: String
        let evidence: String
        let usage: String
    }
    let date: Date
    let roots: [String]
    let rows: Int
    let unmeasured: Int
    let paths: [Path]
    let contentDetails: [String]
    let candidatePaths: [String]

    var candidates: [StorageItem] {
        candidatePaths.compactMap { path in
            StorageItem(json: ["kind": "project_residue", "cleanupId": "project_residue",
                "path": path, "label": URL(fileURLWithPath: path).deletingLastPathComponent().lastPathComponent
                    + " · " + URL(fileURLWithPath: path).lastPathComponent,
                "measureStatus": "historical", "sizeGB": 0,
                "note": "별도 조사 기록에서 발견 · \(date.formatted()) · 현재 크기·사용 여부는 새로 조사해야 합니다."])
        }
    }

    static func latest() -> Self? {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Modore/storage-audits")
        guard let directories = try? FileManager.default.contentsOfDirectory(at: root,
            includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return nil }
        return directories.sorted { $0.lastPathComponent > $1.lastPathComponent }.prefix(40).compactMap { directory in
            guard let json = read(directory.appendingPathComponent("summary.json")),
                  let epoch = json["observedAt"] as? Double, epoch.isFinite, epoch > 0,
                  let collector = json["collector"] as? [String: Any] else { return nil }
            let pathJSON = read(directory.appendingPathComponent("large-path-recheck.json"))
            let recreation = (readValue(directory.appendingPathComponent("recreation-recheck.json"))
                ?? readValue(directory.appendingPathComponent("recreation-evidence.json"))) as? [[String: Any]] ?? []
            let breakdown = read(directory.appendingPathComponent("content-breakdown.json")) ?? [:]
            let paths = (pathJSON?["rows"] as? [[String: Any]] ?? []).prefix(100).compactMap { row -> Path? in
                guard let path = row["path"] as? String else { return nil }
                var detail = row["evidence"] as? String ?? "근거 없음"
                if let checked = recreation.first(where: { $0["path"] as? String == path }) {
                    let markers = checked["markers"] as? [String] ?? []
                    detail += " · 명세: " + markers.joined(separator: ", ")
                    if let tracked = checked["trackedFiles"] as? Int, checked["gitExit"] as? Int == 0 {
                        detail += " · Git 추적 파일 \(tracked)개"
                    }
                    if checked["installedLockMatches"] as? Bool == true { detail += " · 설치 lock 일치" }
                    if checked["rebuildExecuted"] as? Bool == false { detail += " · 재빌드 미검증" }
                }
                return Path(path: path, bytes: row["bytes"] as? Int64,
                    classification: row["classification"] as? String ?? "확인 부족",
                    evidence: detail,
                    usage: row["useConclusion"] as? String ?? "사용 상태 미확인")
            }
            return Self(date: Date(timeIntervalSince1970: epoch), roots: collector["projectRoots"] as? [String] ?? [],
                rows: collector["rows"] as? Int ?? 0, unmeasured: collector["unmeasuredRows"] as? Int ?? 0, paths: paths, contentDetails: describe(breakdown), candidatePaths: recreation.compactMap {
                    guard let path = $0["path"] as? String, path.hasPrefix("/"),
                          ["Pods", "build", ".dart_tool", "node_modules", "target", ".build", ".gradle"]
                            .contains(URL(fileURLWithPath: path).lastPathComponent) else { return nil }
                    return path
                })
        }.max { $0.date < $1.date }
    }

    private static func describe(_ object: [String: Any], prefix: String = "") -> [String] {
        object.keys.sorted().flatMap { key -> [String] in
            let label = prefix.isEmpty ? key : prefix + " · " + key
            if let nested = object[key] as? [String: Any] { return describe(nested, prefix: label) }
            if key.lowercased().hasSuffix("bytes"), let bytes = object[key] as? Int64 {
                return [label + ": " + StorageBytes.text(bytes)]
            }
            if key == "note", let note = object[key] as? String { return [note] }
            return []
        }
    }

    private static func read(_ url: URL) -> [String: Any]? { readValue(url) as? [String: Any] }
    private static func readValue(_ url: URL) -> Any? {
        guard let data = try? SecureLocalFileIO.boundedRead(from: url, maximumBytes: 2_000_000) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }
}
