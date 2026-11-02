import XCTest
@testable import CodexMeterCore

final class DeepSeekPricingScheduleTests: XCTestCase {
    private func date(_ string: String) -> Date {
        ISO8601DateFormatter().date(from: string)!
    }

    private func snapshot(_ localTime: String) -> DeepSeekPricingSnapshot {
        DeepSeekPricingSchedule.snapshot(at: date(localTime + "+08:00"))
    }

    func testWorkingDayUsesHalfOpenPeakBoundaries() {
        for (time, phase) in [
            ("08:59:59", DeepSeekPricingPhase.offPeak), ("09:00:00", .peak),
            ("11:59:59", .peak), ("12:00:00", .offPeak),
            ("13:59:59", .offPeak), ("14:00:00", .peak),
            ("17:59:59", .peak), ("18:00:00", .offPeak)
        ] {
            XCTAssertEqual(snapshot("2026-10-14T" + time).phase, phase, time)
        }
        XCTAssertEqual(snapshot("2026-10-14T09:00:00").currentPhaseStart, date("2026-10-14T09:00:00+08:00"))
        XCTAssertEqual(snapshot("2026-10-14T12:00:00").currentPhaseStart, date("2026-10-14T12:00:00+08:00"))
        XCTAssertEqual(snapshot("2026-10-14T18:00:00").currentPhaseStart, date("2026-10-14T18:00:00+08:00"))
    }

    func testMorningPeakTargetsFuturePeakRatherThanCurrentPeak() {
        let value = snapshot("2026-10-14T10:00:00")
        XCTAssertEqual(value.currentPhaseStart, date("2026-10-14T09:00:00+08:00"))
        XCTAssertEqual(value.nextPeakAt, date("2026-10-14T14:00:00+08:00"))
        XCTAssertEqual(value.nextOffPeakAt, date("2026-10-14T12:00:00+08:00"))
        XCTAssertEqual(value.peakWaitFraction ?? -1, 4.0 / 5, accuracy: 0.000001)
        XCTAssertEqual(value.offPeakWaitFraction ?? -1, 2.0 / 3, accuracy: 0.000001)
    }

    func testCurrentPhaseTransitionWaitsForWhateverEndsTheCurrentPhase() {
        // A morning peak counts down to the noon off-peak...
        let peak = snapshot("2026-10-14T10:00:00")
        XCTAssertEqual(peak.currentPhaseTransition?.phase, .offPeak)
        XCTAssertEqual(peak.currentPhaseTransition?.at, date("2026-10-14T12:00:00+08:00"))
        XCTAssertEqual(peak.currentPhaseTransition?.waitFraction ?? -1, 2.0 / 3, accuracy: 0.000001)
        // ...a night valley waits for the next morning's peak...
        let valley = snapshot("2026-10-14T20:00:00")
        XCTAssertEqual(valley.currentPhaseTransition?.phase, .peak)
        XCTAssertEqual(valley.currentPhaseTransition?.at, date("2026-10-15T09:00:00+08:00"))
        XCTAssertEqual(valley.currentPhaseTransition?.waitFraction ?? -1, 13.0 / 15, accuracy: 0.000001)
        // ...and an unconfirmed phase has no meaningful countdown target
        // (Oct 5 is a makeup workday inside the National Day break).
        XCTAssertNil(snapshot("2026-10-05T10:00:00").currentPhaseTransition)
    }

    func testLunchValleyUsesSameContinuousPhaseStartForBothWaits() {
        let value = snapshot("2026-10-14T13:00:00")
        XCTAssertEqual(value.currentPhaseStart, date("2026-10-14T12:00:00+08:00"))
        XCTAssertEqual(value.nextPeakAt, date("2026-10-14T14:00:00+08:00"))
        XCTAssertEqual(value.nextOffPeakAt, date("2026-10-14T18:00:00+08:00"))
        XCTAssertEqual(value.peakWaitFraction ?? -1, 1.0 / 2, accuracy: 0.000001)
        XCTAssertEqual(value.offPeakWaitFraction ?? -1, 5.0 / 6, accuracy: 0.000001)
    }

    func testAfternoonPeakTargetsNextMorningAndEndsAtEighteen() {
        let value = snapshot("2026-10-14T15:00:00")
        XCTAssertEqual(value.nextPeakAt, date("2026-10-15T09:00:00+08:00"))
        XCTAssertEqual(value.nextOffPeakAt, date("2026-10-14T18:00:00+08:00"))
        let boundary = snapshot("2026-10-14T14:00:00")
        XCTAssertEqual(boundary.peakWaitFraction, 1)
        XCTAssertEqual(boundary.offPeakWaitFraction, 1)
    }

    func testContinuousValleySpansMidnightWithoutRestarting() {
        let value = snapshot("2026-10-14T20:00:00")
        XCTAssertEqual(value.currentPhaseStart, date("2026-10-14T18:00:00+08:00"))
        XCTAssertEqual(value.nextPeakAt, date("2026-10-15T09:00:00+08:00"))
        XCTAssertEqual(value.nextOffPeakAt, date("2026-10-15T12:00:00+08:00"))
        XCTAssertEqual(value.peakWaitFraction ?? -1, 13.0 / 15, accuracy: 0.000001)
        XCTAssertEqual(snapshot("2026-10-15T08:00:00").currentPhaseStart, value.currentPhaseStart)
    }

    func testContinuousWeekendValleyStartsFridayAndTargetsMonday() {
        let value = snapshot("2026-10-16T19:00:00")
        XCTAssertEqual(value.currentPhaseStart, date("2026-10-16T18:00:00+08:00"))
        XCTAssertEqual(value.nextPeakAt, date("2026-10-19T09:00:00+08:00"))
        XCTAssertEqual(value.nextOffPeakAt, date("2026-10-19T12:00:00+08:00"))
        XCTAssertEqual(value.peakWaitFraction ?? -1, 62.0 / 63, accuracy: 0.000001)
        XCTAssertEqual(value.offPeakWaitFraction ?? -1, 65.0 / 66, accuracy: 0.000001)
        XCTAssertEqual(snapshot("2026-10-18T10:00:00").currentPhaseStart, value.currentPhaseStart)
    }

    func testWeekendMakeupWorkdaysRemainOffPeak() {
        for day in ["2026-01-04", "2026-02-14", "2026-02-28", "2026-09-20", "2026-10-10"] {
            XCTAssertEqual(snapshot(day + "T10:00:00").phase, .offPeak, day)
            XCTAssertEqual(snapshot(day + "T15:00:00").phase, .offPeak, day)
        }
        XCTAssertEqual(snapshot("2026-10-10T10:00:00").nextPeakAt, date("2026-10-12T09:00:00+08:00"))
    }

    func testAllConfirmedStatutoryHolidaysAreOffPeak() {
        for day in ["01-01", "02-16", "02-17", "02-18", "02-19", "04-05", "05-01",
                    "05-02", "06-19", "09-25", "10-01", "10-02", "10-03"] {
            XCTAssertEqual(snapshot("2026-" + day + "T10:00:00").phase, .offPeak, day)
            XCTAssertEqual(snapshot("2026-" + day + "T15:00:00").phase, .offPeak, day)
        }
        let holiday = snapshot("2026-06-19T10:00:00")
        XCTAssertEqual(holiday.currentPhaseStart, date("2026-06-18T18:00:00+08:00"))
        XCTAssertEqual(holiday.nextPeakAt, date("2026-06-22T09:00:00+08:00"))
    }

    func testAdjustedWeekdayBreaksDoNotInventPeakOrValley() {
        for day in ["01-02", "02-20", "02-23", "04-06", "05-04", "05-05", "10-05", "10-06", "10-07"] {
            let peakHours = snapshot("2026-" + day + "T10:00:00")
            XCTAssertEqual(peakHours.phase, .unconfirmed, day)
            XCTAssertNil(peakHours.currentPhaseStart)
            XCTAssertNil(peakHours.nextPeakAt)
            XCTAssertNil(peakHours.nextOffPeakAt)
            XCTAssertNil(peakHours.peakWaitFraction)
            XCTAssertNil(peakHours.offPeakWaitFraction)
            XCTAssertEqual(snapshot("2026-" + day + "T13:00:00").phase, .offPeak, day)
        }
    }

    func testUnknownCandidateStopsForwardAndBackwardSearch() {
        let beforeCandidate = snapshot("2026-01-01T20:00:00")
        XCTAssertEqual(beforeCandidate.phase, .offPeak)
        XCTAssertNil(beforeCandidate.nextPeakAt)
        XCTAssertNil(beforeCandidate.nextOffPeakAt)
        let afterCandidate = snapshot("2026-01-02T18:00:00")
        XCTAssertEqual(afterCandidate.phase, .offPeak)
        XCTAssertNil(afterCandidate.currentPhaseStart)
        XCTAssertNil(afterCandidate.peakWaitFraction)
        XCTAssertEqual(afterCandidate.nextPeakAt, date("2026-01-05T09:00:00+08:00"))
        let lunch = snapshot("2026-01-02T13:00:00")
        XCTAssertNil(lunch.currentPhaseStart)
        XCTAssertNil(lunch.nextPeakAt)
    }

    func testUnknownYearAndCrossYearNeverSkipUnconfirmedCandidates() {
        let crossYear = snapshot("2026-12-31T19:00:00")
        XCTAssertEqual(crossYear.phase, .offPeak)
        XCTAssertEqual(crossYear.currentPhaseStart, date("2026-12-31T18:00:00+08:00"))
        XCTAssertNil(crossYear.nextPeakAt)
        XCTAssertNil(crossYear.nextOffPeakAt)
        XCTAssertEqual(snapshot("2027-01-04T10:00:00").phase, .unconfirmed)
        XCTAssertEqual(snapshot("2027-01-04T13:00:00").phase, .offPeak)
        let weekend = snapshot("2027-01-02T10:00:00")
        XCTAssertEqual(weekend.phase, .offPeak)
        XCTAssertNil(weekend.nextPeakAt)
        XCTAssertNil(weekend.currentPhaseStart)
    }

    func testAbsoluteTimeUsesBeijingRegardlessOfDateOffset() {
        let beijing = DeepSeekPricingSchedule.snapshot(at: date("2026-10-14T10:00:00+08:00"))
        XCTAssertEqual(beijing, DeepSeekPricingSchedule.snapshot(at: date("2026-10-14T02:00:00Z")))
        XCTAssertEqual(beijing, DeepSeekPricingSchedule.snapshot(at: date("2026-10-14T11:00:00+09:00")))
    }

    func testInvalidDatesAndUnknownBoundariesStayUnavailable() {
        for seconds in [Double.nan, .infinity, -.infinity, -1, 253_402_300_800] {
            let value = DeepSeekPricingSchedule.snapshot(at: Date(timeIntervalSince1970: seconds))
            XCTAssertEqual(value.phase, .unconfirmed)
            XCTAssertNil(value.currentPhaseStart)
            XCTAssertNil(value.nextPeakAt)
            XCTAssertNil(value.nextOffPeakAt)
            XCTAssertNil(value.peakWaitFraction)
        }
        let now = date("2026-10-14T10:00:00+08:00")
        XCTAssertNil(DeepSeekPricingSchedule.remainingWaitFraction(at: now, phaseStart: nil, target: now))
        XCTAssertNil(DeepSeekPricingSchedule.remainingWaitFraction(at: now, phaseStart: now, target: nil))
        XCTAssertNil(DeepSeekPricingSchedule.remainingWaitFraction(at: now, phaseStart: now, target: now))
    }

    func testClockJumpsClampWaitFractionAndRecomputeThePhase() {
        let start = date("2026-10-14T09:00:00+08:00")
        let target = date("2026-10-14T12:00:00+08:00")
        XCTAssertEqual(DeepSeekPricingSchedule.remainingWaitFraction(
            at: start.addingTimeInterval(-60), phaseStart: start, target: target), 1)
        XCTAssertEqual(DeepSeekPricingSchedule.remainingWaitFraction(
            at: target.addingTimeInterval(60), phaseStart: start, target: target), 0)
        XCTAssertEqual(snapshot("2026-10-14T13:00:00").phase, .offPeak)
        XCTAssertEqual(snapshot("2026-10-14T10:00:00").phase, .peak)
    }
}
