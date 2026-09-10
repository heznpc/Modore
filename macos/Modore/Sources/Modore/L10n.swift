import Foundation

/// Language selection is independent of persisted domain state and identifiers.
/// Unsupported languages use English; regional language tags retain their base language.
enum L10n {
    static let supportedLanguages = ["en", "ko", "ja"]

    static func language(for preferences: [String]) -> String {
        for preference in preferences {
            let base = preference.replacingOccurrences(of: "_", with: "-")
                .split(separator: "-").first.map(String.init)?.lowercased() ?? ""
            if supportedLanguages.contains(base) { return base }
        }
        return "en"
    }

    static func text(_ key: String) -> String {
        text(key, preferences: Locale.preferredLanguages)
    }

    static func text(_ key: String, preferences: [String]) -> String {
        let selected = language(for: preferences)
        return tables[selected]?[key] ?? tables["en"]?[key] ?? key
    }

    /// Only for Modore-generated diagnostics. Never pass paths, project names,
    /// identifiers, or conversation content through this compatibility adapter.
    /// Stored warning text stays unchanged for transaction revalidation.
    static func message(_ raw: String) -> String {
        let translated = text(raw)
        if translated != raw { return translated }
        // Legacy Python messages concatenate a fixed prefix/suffix with a target.
        // Match only catalogued boundary fragments; retain the target verbatim.
        let fragments = messageFragments
        for prefix in fragments where raw.hasPrefix(prefix) {
            let remainder = String(raw.dropFirst(prefix.count))
            for suffix in fragments where remainder.hasSuffix(suffix) {
                return text(prefix) + String(remainder.dropLast(suffix.count)) + text(suffix)
            }
            return text(prefix) + text(remainder)
        }
        for suffix in fragments where raw.hasSuffix(suffix) {
            return String(raw.dropLast(suffix.count)) + text(suffix)
        }
        return raw
    }

    private static let messageFragments: [String] = tables["en"]?.keys.filter {
        !$0.isEmpty && !$0.hasPrefix("report.") && ($0.hasSuffix(": ") || $0.hasPrefix(" ") || $0 == "할당 메모리 " || $0 == "잔류 후보 ")
    }.sorted { $0.count > $1.count } ?? []

    private static let tables: [String: [String: String]] = {
        var result: [String: [String: String]] = [:]
        for language in supportedLanguages {
            guard let path = bundle.path(forResource: language, ofType: "lproj"),
                  let data = try? Data(contentsOf: URL(fileURLWithPath: path).appendingPathComponent("Localizable.strings")),
                  let table = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String] else { continue }
            result[language] = table
        }
        return result
    }()

    static var reportStrings: String {
        let language = language(for: Locale.preferredLanguages)
        var fragments: [String: String] = [:]
        for (key, fallback) in tables["en"] ?? [:] where key.hasPrefix("report.fragment.") {
            fragments[String(key.dropFirst("report.fragment.".count))] = tables[language]?[key] ?? fallback
        }
        guard let data = try? JSONSerialization.data(withJSONObject: fragments),
              let json = String(data: data, encoding: .utf8) else { return "{}" }
        return json
    }

    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: text(key), locale: Locale.current, arguments: arguments)
    }

    static var bundle: Bundle {
        if Bundle.main.path(forResource: "en", ofType: "lproj") != nil { return Bundle.main }
        return Bundle.module
    }
}
