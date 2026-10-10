import Foundation

nonisolated enum ProviderKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case deepSeek
    case miniMax

    var id: String { rawValue }
    var isExperimental: Bool { self == .miniMax }
}

nonisolated enum ProviderRegion: String, Codable, CaseIterable, Identifiable, Sendable {
    case china
    case global

    var id: String { rawValue }
}

/// Stores connection metadata only. Secrets live in the app's own Keychain service.
nonisolated struct ProviderConnection: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var kind: ProviderKind
    var region: ProviderRegion
    var name: String
    var enabled: Bool
    var credentialReference: String
    var identityEpoch: UUID
    var selectedBucketID: String?
}

nonisolated enum ProviderUsageMetric: Equatable, Sendable {
    case money(remaining: Decimal, currency: String)
    case percentage(remaining: Double)
    case count(remaining: Int64, unit: String)
    case unlimited
    case unavailable
}

nonisolated struct ProviderUsageBucket: Identifiable, Equatable, Sendable {
    static let maximumResetTimestamp: TimeInterval = 253_402_300_799
    let id: String
    let title: String
    let metric: ProviderUsageMetric
    var totalCount: Int64? = nil
    var quotaBoostMultiplier: Double? = nil
    var windowDuration: TimeInterval? = nil
    var resetsAt: Date? = nil

    var remainingPercent: Double? {
        switch metric {
        case .percentage(let remaining):
            guard remaining.isFinite else { return nil }
            let multiplier = quotaBoostMultiplier ?? 1
            guard multiplier.isFinite, multiplier > 0 else { return nil }
            let capacityPercent = remaining / multiplier
            guard capacityPercent.isFinite else { return nil }
            return min(100, max(0, capacityPercent))
        case .count(let remaining, _):
            guard let totalCount, totalCount > 0, remaining >= 0 else { return nil }
            return min(100, max(0, Double(remaining) / Double(totalCount) * 100))
        case .money, .unlimited, .unavailable:
            return nil
        }
    }

    func remainingTimePercent(at date: Date) -> Double? {
        guard let windowDuration, windowDuration.isFinite, windowDuration > 0,
              windowDuration <= Self.maximumResetTimestamp,
              let resetsAt, Self.supportsResetDate(resetsAt), Self.supportsResetDate(date),
              resetsAt >= date else { return nil }
        let percentage = resetsAt.timeIntervalSince(date) / windowDuration * 100
        guard percentage.isFinite else { return nil }
        return min(100, max(0, percentage))
    }

    static func supportsResetDate(_ date: Date) -> Bool {
        let seconds = date.timeIntervalSince1970
        return seconds.isFinite && (0...maximumResetTimestamp).contains(seconds)
    }
}

nonisolated struct ProviderUsageSnapshot: Equatable, Sendable {
    let buckets: [ProviderUsageBucket]
    let fetchedAt: Date
}

/// Only these local codes cross the service/UI boundary; never expose server bodies or keys.
nonisolated enum ProviderUsageErrorCode: String, Error, Codable, CaseIterable, Sendable {
    case credentialMissing
    case credentialUnavailable
    case invalidConfiguration
    case authentication
    case rateLimited
    case network
    case timeout
    case invalidResponse
    case responseTooLarge
    case unsupportedResponse
    case disabled
    case credentialStorage
    case connectionStorage
}

nonisolated enum ProviderConnectionStatus: Equatable, Sendable {
    case loading
    case ready
    case stale(ProviderUsageErrorCode)
    case authRequired
    case rateLimited(until: Date)
    case unavailable(ProviderUsageErrorCode)

    var isLoading: Bool { if case .loading = self { return true }; return false }
    var isStale: Bool {
        switch self {
        case .ready: return false
        case .loading, .stale, .authRequired, .rateLimited, .unavailable: return true
        }
    }
    var errorCode: ProviderUsageErrorCode? {
        switch self {
        case .ready, .loading: return nil
        case .stale(let code), .unavailable(let code): return code
        case .authRequired: return .authentication
        case .rateLimited: return .rateLimited
        }
    }
    var retryAt: Date? {
        if case .rateLimited(let until) = self { return until }
        return nil
    }
}

/// Per-connection scheduling and request identity are independent of UI selection.
nonisolated struct ProviderRefreshState: Sendable {
    static let successInterval: TimeInterval = 300
    private(set) var requestID: UUID?
    private(set) var lastSuccess: Date?
    private(set) var retryAfter: Date?
    private(set) var rateLimitUntil: Date?
    private(set) var authenticationBlocked = false
    private(set) var failureCount = 0

    mutating func begin(at date: Date, manual: Bool) -> UUID? {
        guard requestID == nil else { return nil }
        if let rateLimitUntil, rateLimitUntil > date { return nil }
        if !manual, let retryAfter, retryAfter > date { return nil }
        guard manual || !authenticationBlocked else { return nil }
        if !manual, failureCount == 0, let lastSuccess,
           date.timeIntervalSince(lastSuccess) < Self.successInterval { return nil }
        let id = UUID()
        requestID = id
        return id
    }

    func owns(_ id: UUID) -> Bool { requestID == id }

    mutating func succeeded(at date: Date) {
        requestID = nil
        lastSuccess = date
        retryAfter = nil
        rateLimitUntil = nil
        failureCount = 0
        authenticationBlocked = false
    }

    mutating func failed(at date: Date, code: ProviderUsageErrorCode, retryAt: Date? = nil) {
        requestID = nil
        if code == .authentication || code == .credentialMissing || code == .credentialUnavailable {
            authenticationBlocked = true
            retryAfter = nil
            return
        }
        authenticationBlocked = false
        failureCount = min(5, failureCount + 1)
        let backoff = min(300, 20 * pow(2, Double(failureCount - 1)))
        retryAfter = max(date.addingTimeInterval(backoff), retryAt ?? date)
        if code == .rateLimited { rateLimitUntil = retryAfter }
    }

    mutating func cancelled() { requestID = nil }
}
