import Foundation

extension Int64 {
    var fileSizeString: String {
        ByteCountFormatter.string(fromByteCount: self, countStyle: .file)
    }
}

private let relativeDateFormatter: RelativeDateTimeFormatter = {
    let f = RelativeDateTimeFormatter()
    f.unitsStyle = .abbreviated
    return f
}()

func relativeDateString(_ date: Date) -> String {
    relativeDateFormatter.localizedString(for: date, relativeTo: Date())
}
