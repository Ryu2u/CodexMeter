import XCTest
@testable import CodexMeterCore

final class BeijingResetClockTests: XCTestCase {
    private let china = Locale(identifier: "zh_CN")
    private let english = Locale(identifier: "en_US")

    private func utc(_ iso: String) -> Date {
        ISO8601DateFormatter().date(from: iso)!
    }

    func testSameBeijingDayShowsOnlyTheClockTime() {
        // 06:23Z is 14:23 in Beijing, the same calendar day as 09:35 Beijing.
        let now = utc("2026-11-06T01:35:00Z")
        let reset = utc("2026-11-06T06:23:00Z")
        XCTAssertEqual(BeijingResetClock.text(for: reset, relativeTo: now, locale: china), "14:23")
    }

    func testDifferentBeijingDayAddsTheDate() {
        let now = utc("2026-11-06T01:35:00Z")
        let reset = utc("2026-11-12T06:23:00Z")
        XCTAssertEqual(BeijingResetClock.text(for: reset, relativeTo: now, locale: china), "11月12日 14:23")
    }

    func testDayBoundaryFollowsBeijingNotUTC() {
        // Both instants fall on 6 November in UTC, but 16:30Z is already
        // 00:30 on 7 November in Beijing.
        let now = utc("2026-11-06T15:30:00Z")
        let reset = utc("2026-11-06T16:30:00Z")
        XCTAssertFalse(BeijingResetClock.isSameDay(reset, now))
        XCTAssertEqual(BeijingResetClock.text(for: reset, relativeTo: now, locale: china), "11月7日 00:30")
    }

    func testResultIgnoresTheMacTimeZone() {
        let previous = NSTimeZone.default
        NSTimeZone.default = TimeZone(identifier: "America/Los_Angeles")!
        defer { NSTimeZone.default = previous }
        let now = utc("2026-11-06T01:35:00Z")
        let reset = utc("2026-11-06T06:23:00Z")
        XCTAssertEqual(BeijingResetClock.text(for: reset, relativeTo: now, locale: china), "14:23")
    }

    func testEnglishLocaleUsesItsOwnClockStyle() {
        let now = utc("2026-11-06T01:35:00Z")
        let sameDay = BeijingResetClock.text(for: utc("2026-11-06T06:23:00Z"), relativeTo: now, locale: english)
        XCTAssertTrue(sameDay.contains("2:23"), sameDay)
        XCTAssertTrue(sameDay.contains("PM"), sameDay)
        let laterDay = BeijingResetClock.text(for: utc("2026-11-12T06:23:00Z"), relativeTo: now, locale: english)
        XCTAssertTrue(laterDay.contains("Nov"), laterDay)
        XCTAssertTrue(laterDay.contains("12"), laterDay)
    }

    func testAnEarlierResetStillFormatsAsADate() {
        // A stale snapshot can carry a reset that already passed on an earlier day.
        let now = utc("2026-11-06T01:35:00Z")
        let reset = utc("2026-11-05T06:23:00Z")
        XCTAssertEqual(BeijingResetClock.text(for: reset, relativeTo: now, locale: china), "11月5日 14:23")
    }
}
