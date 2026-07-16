import AppKit
import Foundation
import SwiftUI

@MainActor
struct NativeSourceIcon: View {
    let item: StorageItem
    let fallbackSymbol: String

    var body: some View {
        Group {
            if let icon = NativeApplicationIconCache.shared.icon(for: item) {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .padding(2)
                    .frame(width: 36, height: 36)
            } else {
                NativeFormSymbolIcon(symbol: fallbackSymbol, tint: .secondary)
            }
        }
    }

}

@MainActor
private final class NativeApplicationIconCache {
    static let shared = NativeApplicationIconCache()

    private let icons = NSCache<NSString, NSImage>()
    private var missingKeys: Set<String> = []

    func icon(for item: StorageItem) -> NSImage? {
        let key = item.path.isEmpty ? item.label.lowercased() : item.path
        if let cached = icons.object(forKey: key as NSString) {
            return cached
        }
        guard !missingKeys.contains(key), let applicationURL = applicationURL(for: item) else {
            missingKeys.insert(key)
            return nil
        }
        let icon = NSWorkspace.shared.icon(forFile: applicationURL.path)
        icons.setObject(icon, forKey: key as NSString)
        return icon
    }

    private func applicationURL(for item: StorageItem) -> URL? {
        if item.path.hasSuffix(".app"), FileManager.default.fileExists(atPath: item.path) {
            return URL(fileURLWithPath: item.path)
        }

        let label = item.label.lowercased()
        let bundleIdentifier: String?
        if label.contains("chrome") {
            bundleIdentifier = "com.google.Chrome"
        } else if label.contains("claude") {
            bundleIdentifier = "com.anthropic.claudefordesktop"
        } else if label.contains("codex") {
            bundleIdentifier = "com.openai.codex"
        } else {
            bundleIdentifier = nil
        }
        if let bundleIdentifier,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            return url
        }

        if label.contains("codex") {
            let candidates = [
                "/Applications/Codex.app",
                FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("Applications/Codex.app").path,
            ]
            return candidates.first(where: FileManager.default.fileExists(atPath:)).map(URL.init(fileURLWithPath:))
        }
        if label.contains("claude") {
            let candidates = [
                "/Applications/Claude.app",
                FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("Applications/Claude.app").path,
            ]
            return candidates.first(where: FileManager.default.fileExists(atPath:)).map(URL.init(fileURLWithPath:))
        }
        return nil
    }
}

struct NativeFormSymbolIcon: View {
    let symbol: String
    let tint: Color

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 16, weight: .medium))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(tint)
            .frame(width: 36, height: 36)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
    }
}
