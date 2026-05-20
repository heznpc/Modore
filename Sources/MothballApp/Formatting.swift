import Foundation

extension Int64 {
    var fileSizeString: String {
        ByteCountFormatter.string(fromByteCount: self, countStyle: .file)
    }
}

// `RelativeDateTimeFormatter` is a Foundation class (non-Sendable) holding
// mutable state. Under Swift 6 strict concurrency we cannot keep it as a
// free-standing global `let`. Pinning the formatter and its only caller
// to `@MainActor` is correct here because the sole call site is a SwiftUI
// `Text(...)` inside `ScanView`, which is already main-actor-isolated.
@MainActor
private let relativeDateFormatter: RelativeDateTimeFormatter = {
    let f = RelativeDateTimeFormatter()
    f.unitsStyle = .abbreviated
    return f
}()

@MainActor
func relativeDateString(_ date: Date) -> String {
    relativeDateFormatter.localizedString(for: date, relativeTo: Date())
}
