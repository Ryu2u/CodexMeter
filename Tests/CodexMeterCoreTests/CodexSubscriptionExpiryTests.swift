import XCTest
@testable import CodexMeterCore

final class CodexSubscriptionExpiryTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }

    private func date(_ localTime: String) -> Date {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.date(from: localTime)!
    }

    func testCountsWholeCalendarDaysUntilFutureExpiry() {
        let now = date("2026-10-19 11:30:00")
        let expiry = date("2026-10-30 23:59:00")
        XCTAssertEqual(CodexSubscriptionExpiry.daysRemaining(until: expiry, now: now, calendar: calendar), 11)
    }

    func testExpiryLaterTodayCountsAsZero() {
        let now = date("2026-10-19 00:01:00")
        let expiry = date("2026-10-19 23:00:00")
        XCTAssertEqual(CodexSubscriptionExpiry.daysRemaining(until: expiry, now: now, calendar: calendar), 0)
    }

    func testPassedExpiryCountsNegativeCalendarDays() {
        let now = date("2026-10-19 12:00:00")
        let expiry = date("2026-10-16 09:00:00")
        XCTAssertEqual(CodexSubscriptionExpiry.daysRemaining(until: expiry, now: now, calendar: calendar), -3)
    }

    func testCountsAcrossMonthBoundaries() {
        let now = date("2026-10-31 12:00:00")
        let expiry = date("2026-11-01 00:30:00")
        XCTAssertEqual(CodexSubscriptionExpiry.daysRemaining(until: expiry, now: now, calendar: calendar), 1)
    }
}
