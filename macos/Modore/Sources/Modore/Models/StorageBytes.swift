import Foundation

/// Recovery accounting is signed integer bytes. Legacy *GB fields are GiB;
/// convert them only at the old scanner/protocol boundary, never for arithmetic.
enum StorageBytes {
    static let perGiB: Int64 = 1_073_741_824

    static func fromLegacyGiB(_ value: Double) -> Int64? {
        let bytes = (value * Double(perGiB)).rounded()
        guard bytes.isFinite, bytes >= 0, bytes < Double(Int64.max) else { return nil }
        return Int64(bytes)
    }

    static func fromKiB(_ value: Int64?) -> Int64? {
        guard let value else { return nil }
        let result = value.multipliedReportingOverflow(by: 1_024)
        return result.overflow ? nil : result.partialValue
    }

    static func adding(_ lhs: Int64, _ rhs: Int64) -> Int64? {
        guard lhs >= 0, rhs >= 0 else { return nil }
        let result = lhs.addingReportingOverflow(rhs)
        return result.overflow ? nil : result.partialValue
    }

    static func text(_ bytes: Int64?) -> String {
        guard let bytes else { return L10n.text("미확인") }
        let magnitude = abs(Double(bytes))
        if magnitude >= Double(perGiB) { return String(format: "%.1f GiB", Double(bytes) / Double(perGiB)) }
        if magnitude >= 1_048_576 { return String(format: "%.1f MiB", Double(bytes) / 1_048_576) }
        if magnitude >= 1_024 { return String(format: "%.1f KiB", Double(bytes) / 1_024) }
        return "\(bytes) B"
    }

    static func changeText(_ bytes: Int64?) -> String {
        guard let bytes else { return L10n.text("미확인") }
        return (bytes > 0 ? "+" : "") + text(bytes)
    }
}
