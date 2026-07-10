import Foundation

struct CleanupProcessDisplay: Equatable {
    let name: String
    let rawCommand: String
}

enum CleanupPresentation {
    static func sizeChangeNotice(
        snapshotAge: String,
        scannedSize: String?,
        previewSize: String
    ) -> String? {
        guard let scannedSize, scannedSize != previewSize else { return nil }
        return "\(snapshotAge) 값은 \(scannedSize)였고, 미리보기에서 \(previewSize)로 다시 측정했습니다."
    }

    static func processDisplays(from rawValue: String, limit: Int = 5) -> [CleanupProcessDisplay] {
        var seen = Set<String>()
        return rawValue
            .split(separator: ";")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .compactMap { command in
                let name = compactProcessName(command)
                guard seen.insert(name).inserted else { return nil }
                return CleanupProcessDisplay(name: name, rawCommand: command)
            }
            .prefix(max(0, limit))
            .map { $0 }
    }

    static func compactProcessName(_ command: String) -> String {
        let normalized = command.lowercased()
        if normalized.contains("google chrome helper") {
            return normalized.contains("renderer") ? "Google Chrome Helper (Renderer)" : "Google Chrome Helper"
        }
        if normalized.contains("google chrome") { return "Google Chrome" }
        if normalized.contains("airmcp") { return "AirMCP" }
        if normalized.contains("mcp") && normalized.contains("server") { return "MCP server" }
        if let marker = command.range(of: "/Contents/MacOS/") {
            let tail = String(command[marker.upperBound...])
            return tail.components(separatedBy: " --").first ?? tail
        }
        if normalized.contains("playwright") { return "Playwright" }
        if normalized.contains("codex") { return "Codex" }
        if normalized.contains("claude") { return "Claude" }
        return String(command.prefix(100))
    }
}
