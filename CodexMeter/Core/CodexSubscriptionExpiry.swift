import Foundation

/// Calendar-day countdown for the manually entered Codex subscription expiry.
enum CodexSubscriptionExpiry {
    /// Whole calendar days from `now` until `expiry`: positive while it is in
    /// the future, zero on the expiry day, negative once it has passed.
    static func daysRemaining(
        until expiry: Date,
        now: Date,
        calendar: Calendar = .current
    ) -> Int {
        calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: now),
            to: calendar.startOfDay(for: expiry)
        ).day ?? 0
    }
}
