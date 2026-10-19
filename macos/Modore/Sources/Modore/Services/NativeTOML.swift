import Foundation
import TOMLDecoder

/// Parse the entire document before attributing any plugin's enabled flag.
enum NativeTOML {
    private struct Config: Decodable {
        struct Plugin: Decodable { let enabled: Bool? }
        let plugins: [String: Plugin]?
    }
    static func pluginFlags(_ text: String) throws -> [String: Bool] {
        let config = try TOMLDecoder().decode(Config.self, from: text)
        return (config.plugins ?? [:]).compactMapValues(\.enabled)
    }
}
