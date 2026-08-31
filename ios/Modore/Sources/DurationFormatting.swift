import Foundation

enum DurationFormatting {
    static func string(_ duration: TimeInterval, locale: Locale = .current) -> String {
        let totalSeconds = max(0, Int(duration.rounded(.down)))
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        formatter.allowedUnits = totalSeconds >= 3600
            ? [.hour, .minute]
            : totalSeconds >= 60 ? [.minute, .second] : [.second]
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        formatter.calendar = calendar
        return formatter.string(from: TimeInterval(totalSeconds)) ?? "0"
    }
}
