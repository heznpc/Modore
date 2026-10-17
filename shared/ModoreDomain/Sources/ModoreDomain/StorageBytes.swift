import Foundation

/// Capacity arithmetic and UI labels both use binary units. Unlike
/// ByteCountFormatter's localized "GB" label, GiB states the divisor explicitly.
public enum StorageBytes {
    public static func text(_ bytes: Int64, locale: Locale = .current) -> String {
        let units = ["B", "KiB", "MiB", "GiB", "TiB", "PiB", "EiB"]
        var value = Double(bytes)
        var unit = 0
        while abs(value) >= 1_024 && unit < units.count - 1 {
            value /= 1_024
            unit += 1
        }
        return String(format: unit == 0 ? "%.0f %@" : "%.1f %@", locale: locale, value, units[unit])
    }
}
