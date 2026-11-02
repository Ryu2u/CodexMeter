import Foundation

nonisolated enum DeepSeekPricingPhase: Equatable, Sendable {
    case peak
    case offPeak
    case unconfirmed
}

nonisolated struct DeepSeekPricingSnapshot: Equatable, Sendable {
    let phase: DeepSeekPricingPhase
    let calculatedAt: Date
    let currentPhaseStart: Date?
    let nextPeakAt: Date?
    let nextOffPeakAt: Date?

    var peakWaitFraction: Double? {
        DeepSeekPricingSchedule.remainingWaitFraction(
            at: calculatedAt, phaseStart: currentPhaseStart, target: nextPeakAt)
    }

    var offPeakWaitFraction: Double? {
        DeepSeekPricingSchedule.remainingWaitFraction(
            at: calculatedAt, phaseStart: currentPhaseStart, target: nextOffPeakAt)
    }

    /// The transition that ends the current phase — off-peak counts down to
    /// the next peak and peak counts down to the next off-peak — with its
    /// normalized remaining-wait fraction. Nil while the phase is unknown.
    var currentPhaseTransition: (phase: DeepSeekPricingPhase, at: Date?, waitFraction: Double?)? {
        switch phase {
        case .peak: return (.offPeak, nextOffPeakAt, offPeakWaitFraction)
        case .offPeak: return (.peak, nextPeakAt, peakWaitFraction)
        case .unconfirmed: return nil
        }
    }
}

/// Pricing periods are a local calendar calculation, independent of balance requests.
nonisolated enum DeepSeekPricingSchedule {
    static let rulesURL = URL(string: "https://api-docs.deepseek.com/zh-cn/quick_start/pricing/")!
    static let holidayCoverageYear = 2026
    private static let maximumSearchSegments = 32 * 5

    // Verified 2026-10-14. Statutory dates, rather than whole adjusted breaks:
    // https://www.jinan.gov.cn/col/col118356/art/2026/art_5c0f206d9dc945faa30f68f8e811be7e.html
    // Full breaks: https://www.beijing.gov.cn/zhengce/zhengcefagui/202511/t20251104_4258873.html
    // DeepSeek does not specify whether adjusted weekday breaks count as holidays.
    private static let statutoryHolidays: Set<Int> = [
        101, 216, 217, 218, 219, 405, 501, 502, 619, 925, 1001, 1002, 1003
    ]
    private static let unconfirmedWeekdayBreaks: Set<Int> = [
        102, 220, 223, 406, 504, 505, 1005, 1006, 1007
    ]

    static func snapshot(at date: Date) -> DeepSeekPricingSnapshot {
        guard validDate(date), let segments = segments(on: date),
              let index = segments.firstIndex(where: { $0.start <= date && date < $0.end }) else {
            return unknownSnapshot(at: date)
        }
        let phase = segments[index].phase
        guard phase != .unconfirmed else { return unknownSnapshot(at: date) }
        let future = nextTransitions(in: segments, from: index)
        return DeepSeekPricingSnapshot(
            phase: phase, calculatedAt: date,
            currentPhaseStart: continuousPhaseStart(in: segments, from: index),
            nextPeakAt: future.peak, nextOffPeakAt: future.offPeak)
    }

    /// Both bars measure remaining wait from the same continuous phase start.
    /// Clamping permits safe rendering after wall-clock adjustments.
    static func remainingWaitFraction(at date: Date, phaseStart: Date?, target: Date?) -> Double? {
        guard validDate(date), let phaseStart, validDate(phaseStart),
              let target, validDate(target), target > phaseStart else { return nil }
        let fraction = target.timeIntervalSince(date) / target.timeIntervalSince(phaseStart)
        guard fraction.isFinite else { return nil }
        return min(1, max(0, fraction))
    }

    private struct Segment {
        let start: Date
        let end: Date
        let phase: DeepSeekPricingPhase
    }

    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }

    private static func segments(on date: Date) -> [Segment]? {
        guard validDate(date) else { return nil }
        let calendar = calendar
        let start = calendar.startOfDay(for: date)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start), validDate(end) else { return nil }
        let parts = calendar.dateComponents([.year, .month, .day, .weekday], from: date)
        let isWeekend = parts.weekday == 1 || parts.weekday == 7
        let monthDay = (parts.month ?? 0) * 100 + (parts.day ?? 0)
        if isWeekend || (parts.year == holidayCoverageYear && statutoryHolidays.contains(monthDay)) {
            return [Segment(start: start, end: end, phase: .offPeak)]
        }
        let peakPhase: DeepSeekPricingPhase = parts.year == holidayCoverageYear
            && !unconfirmedWeekdayBreaks.contains(monthDay) ? .peak : .unconfirmed
        var boundaries = [start]
        for hour in [9, 12, 14, 18] {
            guard let boundary = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: date),
                  validDate(boundary) else { return nil }
            boundaries.append(boundary)
        }
        boundaries.append(end)
        let phases: [DeepSeekPricingPhase] = [.offPeak, peakPhase, .offPeak, peakPhase, .offPeak]
        return phases.indices.map { Segment(start: boundaries[$0], end: boundaries[$0 + 1], phase: phases[$0]) }
    }

    private static func continuousPhaseStart(in initial: [Segment], from initialIndex: Int) -> Date? {
        var segments = initial
        var index = initialIndex
        let phase = segments[index].phase
        var start = segments[index].start
        for _ in 0..<maximumSearchSegments {
            if index == 0 {
                guard let previous = self.segments(on: segments[0].start.addingTimeInterval(-1)) else { return nil }
                segments = previous
                index = previous.count - 1
            } else {
                index -= 1
            }
            let previous = segments[index]
            // An unknown segment might extend the current period, so do not guess its start.
            if previous.phase == .unconfirmed { return nil }
            if previous.phase != phase { return start }
            start = previous.start
        }
        return nil
    }

    private static func nextTransitions(in initial: [Segment], from initialIndex: Int) -> (peak: Date?, offPeak: Date?) {
        var segments = initial
        var index = initialIndex
        var previousPhase = segments[index].phase
        var peak: Date?
        var offPeak: Date?
        for _ in 0..<maximumSearchSegments {
            index += 1
            if index == segments.count {
                guard let next = self.segments(on: segments[segments.count - 1].end) else { break }
                segments = next
                index = 0
            }
            let next = segments[index]
            // Never skip an uncertain candidate and advertise a later precise transition.
            if next.phase == .unconfirmed { break }
            if next.phase != previousPhase {
                if next.phase == .peak, peak == nil { peak = next.start }
                if next.phase == .offPeak, offPeak == nil { offPeak = next.start }
            }
            if peak != nil && offPeak != nil { break }
            previousPhase = next.phase
        }
        return (peak, offPeak)
    }

    private static func validDate(_ date: Date) -> Bool {
        let seconds = date.timeIntervalSince1970
        return seconds.isFinite && (0...253_402_300_799).contains(seconds)
    }

    private static func unknownSnapshot(at date: Date) -> DeepSeekPricingSnapshot {
        DeepSeekPricingSnapshot(phase: .unconfirmed, calculatedAt: date,
                                currentPhaseStart: nil, nextPeakAt: nil, nextOffPeakAt: nil)
    }
}
