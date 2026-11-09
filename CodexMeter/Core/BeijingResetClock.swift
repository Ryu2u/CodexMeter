import Foundation

/// Formats a quota reset instant as Beijing wall-clock time, independent of
/// the Mac's time zone, so every platform's reset reads the same way.
nonisolated enum BeijingResetClock {
    private static let timeZone = TimeZone(identifier: "Asia/Shanghai")!

    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    /// The day boundary is Beijing midnight, not UTC or the local zone.
    static func isSameDay(_ first: Date, _ second: Date) -> Bool {
        calendar.isDate(first, inSameDayAs: second)
    }

    /// The clock time alone when the reset falls on today's Beijing date,
    /// otherwise the date followed by the clock time. The 12/24-hour style
    /// and field order follow `locale`.
    static func text(for reset: Date, relativeTo now: Date, locale: Locale) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.calendar = calendar
        formatter.setLocalizedDateFormatFromTemplate(isSameDay(reset, now) ? "jm" : "MMMdjm")
        return formatter.string(from: reset)
    }
}
