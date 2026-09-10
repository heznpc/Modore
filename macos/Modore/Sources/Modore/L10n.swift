import Foundation

enum L10n {
    static func text(_ key: String) -> String { bundle.localizedString(forKey:key,value:key,table:nil) }
    static func format(_ key: String, _ value: String) -> String { String(format:text(key),locale:Locale.current,value) }
    static var bundle: Bundle {
        if Bundle.main.path(forResource:"en",ofType:"lproj") != nil { return Bundle.main }
        return Bundle.module
    }
}
