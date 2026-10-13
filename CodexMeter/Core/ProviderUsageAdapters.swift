import Foundation
import CoreFoundation

nonisolated struct ProviderUsageFailure: Error, Sendable {
    let code: ProviderUsageErrorCode
    var retryAt: Date? = nil
}

nonisolated struct ProviderHTTPResponse: Sendable {
    let data: Data
    let statusCode: Int
    let headers: [String: String]
    let url: URL
}

nonisolated protocol ProviderUsageTransport: Sendable {
    func send(_ request: URLRequest) async throws -> ProviderHTTPResponse
}

/// Reject cross-origin redirects before a bearer credential can leave its official host.
private final class ProviderRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let original = task.originalRequest?.url, let destination = request.url,
              ProviderUsageAdapter.sameOrigin(original, destination) else {
            completionHandler(nil)
            return
        }
        var redirected = request
        redirected.setValue(task.originalRequest?.value(forHTTPHeaderField: "Authorization"),
                            forHTTPHeaderField: "Authorization")
        completionHandler(redirected)
    }
}

actor ProviderURLSessionTransport: ProviderUsageTransport {
    private let session: URLSession
    private let redirectPolicy: ProviderRedirectPolicy

    init(configuration: URLSessionConfiguration = .ephemeral) {
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 20
        let policy = ProviderRedirectPolicy()
        redirectPolicy = policy
        session = URLSession(configuration: configuration, delegate: policy, delegateQueue: nil)
    }

    func send(_ request: URLRequest) async throws -> ProviderHTTPResponse {
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        guard let response = response as? HTTPURLResponse, let url = response.url else {
            throw ProviderUsageFailure(code: .invalidResponse)
        }
        var headers: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            guard let name = key as? String else { continue }
            headers[name.lowercased()] = String(describing: value)
        }
        guard (200..<300).contains(response.statusCode) else {
            return ProviderHTTPResponse(data: Data(), statusCode: response.statusCode, headers: headers, url: url)
        }
        if response.expectedContentLength > Int64(ProviderUsageAdapter.maximumResponseBytes) {
            throw ProviderUsageFailure(code: .responseTooLarge)
        }
        var data = Data()
        data.reserveCapacity(min(16_384, ProviderUsageAdapter.maximumResponseBytes))
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < ProviderUsageAdapter.maximumResponseBytes else {
                throw ProviderUsageFailure(code: .responseTooLarge)
            }
            data.append(byte)
        }
        return ProviderHTTPResponse(data: data, statusCode: response.statusCode, headers: headers, url: url)
    }

    deinit { session.invalidateAndCancel() }
}

/// The MiniMax endpoint is documented; its response decoder remains experimental.
/// Keep protocol fixtures distinct from successful live-account verification.
nonisolated enum ProviderUsageAdapter {
    static let maximumResponseBytes = 512 * 1_024
    static let maximumBuckets = 64

    static func endpoint(kind: ProviderKind, region: ProviderRegion) -> URL {
        switch kind {
        case .deepSeek:
            return URL(string: "https://api.deepseek.com/user/balance")!
        case .miniMax:
            let host = region == .china ? "api.minimax.cn" : "api.minimax.io"
            return URL(string: "https://\(host)/v1/token_plan/remains")!
        case .zhipu:
            // Console quota endpoint captured from the coding-plan web app;
            // undocumented, so decode defensively and treat drift as failure.
            return URL(string: "https://bigmodel.cn/api/monitor/usage/quota/limit?type=2")!
        }
    }

    static func request(for connection: ProviderConnection, key: String) throws -> URLRequest {
        if connection.kind == .zhipu {
            // The console API authenticates with the raw session JWT; a Bearer
            // prefix would change the header value and fail.
            guard validZhipuCredential(key) else { throw ProviderUsageFailure(code: .credentialMissing) }
        }
        guard validCredential(key) else { throw ProviderUsageFailure(code: .credentialMissing) }
        var request = URLRequest(url: endpoint(kind: connection.kind, region: connection.region),
                                 cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.httpMethod = "GET"
        request.setValue(connection.kind == .zhipu ? key : "Bearer \(key)",
                         forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }

    static func fetch(
        connection: ProviderConnection,
        key: String,
        transport: any ProviderUsageTransport,
        now: @Sendable () -> Date = { Date() }
    ) async throws -> ProviderUsageSnapshot {
        do {
            let request = try request(for: connection, key: key)
            let response = try await transport.send(request)
            try Task.checkCancellation()
            guard let expectedURL = request.url, sameOrigin(expectedURL, response.url) else {
                throw ProviderUsageFailure(code: .invalidResponse)
            }
            guard response.data.count <= maximumResponseBytes else {
                throw ProviderUsageFailure(code: .responseTooLarge)
            }
            let date = now()
            switch response.statusCode {
            case 200..<300: break
            case 401, 403: throw ProviderUsageFailure(code: .authentication)
            case 429:
                throw ProviderUsageFailure(code: .rateLimited,
                                           retryAt: retryAfter(response.headers["retry-after"], at: date))
            case 500..<600: throw ProviderUsageFailure(code: .network)
            default: throw ProviderUsageFailure(code: .invalidResponse)
            }
            return try decode(response.data, kind: connection.kind, fetchedAt: date)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as ProviderUsageFailure {
            throw error
        } catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            throw ProviderUsageFailure(code: error.code == .timedOut ? .timeout : .network)
        } catch {
            throw ProviderUsageFailure(code: .network)
        }
    }

    static func decode(_ data: Data, kind: ProviderKind, fetchedAt: Date) throws -> ProviderUsageSnapshot {
        guard data.count <= maximumResponseBytes else { throw ProviderUsageFailure(code: .responseTooLarge) }
        guard let json = try? JSONSerialization.jsonObject(with: data),
              let body = json as? [String: Any] else { throw ProviderUsageFailure(code: .invalidResponse) }
        let buckets: [ProviderUsageBucket]
        switch kind {
        case .deepSeek: buckets = try decodeDeepSeek(body)
        case .miniMax: buckets = try decodeMiniMax(body)
        case .zhipu: buckets = try decodeZhipu(body)
        }
        guard !buckets.isEmpty, buckets.count <= maximumBuckets,
              Set(buckets.map(\.id)).count == buckets.count else {
            throw ProviderUsageFailure(code: .unsupportedResponse)
        }
        return ProviderUsageSnapshot(buckets: buckets, fetchedAt: fetchedAt)
    }

    private static func decodeDeepSeek(_ body: [String: Any]) throws -> [ProviderUsageBucket] {
        guard let rows = body["balance_infos"] as? [[String: Any]],
              !rows.isEmpty, rows.count <= maximumBuckets else {
            throw ProviderUsageFailure(code: .unsupportedResponse)
        }
        return try rows.map { row in
            guard let currency = row["currency"] as? String, ["CNY", "USD"].contains(currency),
                  let raw = row["total_balance"] as? String, let amount = decimal(raw) else {
                throw ProviderUsageFailure(code: .unsupportedResponse)
            }
            // total_balance already includes both granted and topped-up balances.
            return ProviderUsageBucket(id: "balance:\(currency)", title: currency,
                                       metric: .money(remaining: amount, currency: currency))
        }
    }

    private static func decodeMiniMax(_ body: [String: Any]) throws -> [ProviderUsageBucket] {
        if body.keys.contains("base_resp") {
            guard let envelope = body["base_resp"] as? [String: Any],
                  let statusCode = integer(envelope["status_code"]) else {
                throw ProviderUsageFailure(code: .invalidResponse)
            }
            switch statusCode {
            case 0: break
            case 1004, 2049: throw ProviderUsageFailure(code: .authentication)
            case 1001: throw ProviderUsageFailure(code: .timeout)
            case 1002, 2045: throw ProviderUsageFailure(code: .rateLimited)
            default: throw ProviderUsageFailure(code: .invalidResponse)
            }
        }
        guard let rows = body["model_remains"] as? [[String: Any]],
              !rows.isEmpty, rows.count <= maximumBuckets else {
            throw ProviderUsageFailure(code: .unsupportedResponse)
        }
        var buckets: [ProviderUsageBucket] = []
        var confirmsUnavailablePlan = false
        for row in rows {
            guard let model = row["model_name"] as? String, !model.isEmpty, model.count <= 80,
                  !model.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                throw ProviderUsageFailure(code: .unsupportedResponse)
            }
            // The official CLI uses this exact sentinel for a model outside the current plan.
            let absentPlan = number(row["current_interval_total_count"]) == 0
                && number(row["current_weekly_total_count"]) == 0
                && integer(row["current_interval_status"]) == 3
                && integer(row["current_weekly_status"]) == 3
            confirmsUnavailablePlan = confirmsUnavailablePlan || absentPlan
            for (prefix, suffix, endField, startField) in [
                ("current_interval", "interval", "end_time", "start_time"),
                ("current_weekly", "weekly", "weekly_end_time", "weekly_start_time")
            ] {
                guard absentPlan || ["_status", "_remaining_percent", "_total_count", "_usage_count"]
                    .contains(where: { row[prefix + $0] != nil }) else { continue }
                let metric = absentPlan ? ProviderUsageMetric.unavailable
                    : miniMaxMetric(row, prefix: prefix, weekly: suffix == "weekly")
                let hidesTiming = absentPlan || metric == .unlimited || metric == .unavailable
                let reset = hidesTiming ? nil : millisecondsTimestamp(row[endField])
                let start = hidesTiming ? nil : millisecondsTimestamp(row[startField])
                let duration = start.flatMap { start in reset.flatMap { end in
                    end > start ? end.timeIntervalSince(start) : nil
                } }
                let boost = suffix == "weekly" && !hidesTiming
                    ? number(row["weekly_boost_permille"]).flatMap { $0 > 0 ? $0 / 1_000 : nil } : nil
                buckets.append(ProviderUsageBucket(id: "\(model):\(suffix)", title: model, metric: metric,
                                                   quotaBoostMultiplier: boost,
                                                   windowDuration: duration, resetsAt: reset))
                guard buckets.count <= maximumBuckets else { throw ProviderUsageFailure(code: .responseTooLarge) }
            }
        }
        guard confirmsUnavailablePlan || buckets.contains(where: { $0.metric != .unavailable }) else {
            throw ProviderUsageFailure(code: .unsupportedResponse)
        }
        return buckets
    }

    private static func miniMaxMetric(_ row: [String: Any], prefix: String, weekly: Bool) -> ProviderUsageMetric {
        let status = integer(row[prefix + "_status"])
        if status == 3 { return .unlimited }
        let rawStatus = row[prefix + "_status"]
        if rawStatus != nil, !(rawStatus is NSNull), status != 1, status != 2 { return .unavailable }
        let rawPercent = row[prefix + "_remaining_percent"]
        let hasPercent = rawPercent != nil && !(rawPercent is NSNull)
        let basePercent: Double
        if hasPercent {
            guard let percent = number(rawPercent), (0...100).contains(percent) else { return .unavailable }
            if status == 2, percent != 0 { return .unavailable }
            // Explicit percentage is authoritative even when usage_count changed direction.
            basePercent = percent
        } else if status == 2 {
            basePercent = 0
        } else {
            guard let total = number(row[prefix + "_total_count"]), total > 0,
                  let reported = number(row[prefix + "_usage_count"]), (0...total).contains(reported) else {
                return .unavailable
            }
            // Official CLI compatibility policy: absent percentage means legacy remaining count.
            // The count's unit is unspecified, so expose its ratio rather than inventing tokens.
            basePercent = reported / total * 100
        }
        var factor = 1.0
        if weekly, let rawBoost = row["weekly_boost_permille"], !(rawBoost is NSNull) {
            guard let boost = number(rawBoost), boost > 0 else { return .unavailable }
            factor = boost / 1_000
            guard factor.isFinite, factor > 0 else { return .unavailable }
        }
        let remaining = basePercent * factor
        guard remaining.isFinite else { return .unavailable }
        // Preserve boosted values above 100 in the metric; visual progress remains bounded.
        return .percentage(remaining: remaining)
    }

    /// The coding-plan console reports one entry per reset window with the
    /// window's total credits, remaining credits, used percentage, and the
    /// next reset as epoch milliseconds. `percentage` is used quota, so the
    /// exact remaining counts drive the metric and the percentage only
    /// cross-checks.
    private static func decodeZhipu(_ body: [String: Any]) throws -> [ProviderUsageBucket] {
        if let code = integer(body["code"]), code != 200 {
            throw ProviderUsageFailure(code: code == 401 || code == 403 ? .authentication : .invalidResponse)
        }
        guard let data = body["data"] as? [String: Any],
              let limits = data["limits"] as? [[String: Any]],
              !limits.isEmpty, limits.count <= maximumBuckets else {
            throw ProviderUsageFailure(code: .unsupportedResponse)
        }
        var seenIDs: Set<String> = []
        return try limits.map { limit in
            guard let usage = number(limit["usage"]), usage > 0,
                  usage <= Self.maximumWindowCredits,
                  let remaining = number(limit["remaining"]), remaining >= 0, remaining <= usage else {
                throw ProviderUsageFailure(code: .unsupportedResponse)
            }
            let durationMins = zhipuWindowMinutes(unit: integer(limit["unit"]), number: integer(limit["number"]))
            let baseID: String
            if let durationMins {
                baseID = "zhipu:\(durationMins)"
            } else {
                let unit = integer(limit["unit"]) ?? -1
                let number = integer(limit["number"]) ?? -1
                baseID = "zhipu:u\(unit)n\(number)"
            }
            // Duplicate window types may legitimately appear; suffix keeps IDs
            // unique while staying stable for a fixed server ordering.
            var id = baseID
            var counter = 2
            while !seenIDs.insert(id).inserted {
                id = "\(baseID)#\(counter)"
                counter += 1
            }
            let resetsAt = millisecondsTimestamp(limit["nextResetTime"])
            // Counts stay exact; the reported integer percentage is only a summary.
            return ProviderUsageBucket(
                id: id,
                title: durationMins.map { "\($0)m" } ?? "window",
                metric: .count(remaining: Int64(remaining.rounded()), unit: "credits"),
                totalCount: Int64(usage.rounded()),
                windowDuration: durationMins.map { Double($0) * 60 },
                resetsAt: resetsAt
            )
        }
    }

    /// Unit 3 counts hours and unit 6 counts weeks in the captured responses.
    /// Unknown units stay unknown instead of guessing a window length.
    private static func zhipuWindowMinutes(unit: Int64?, number: Int64?) -> Int? {
        guard let unit, let number, number > 0, number <= 366 else { return nil }
        switch unit {
        case 3: return Int(number) * 60
        case 6: return Int(number) * 10_080
        default: return nil
        }
    }

    static let maximumWindowCredits: Double = 1_000_000_000

    /// Console credentials are session JWTs: three base64url segments whose
    /// header starts with the canonical `{"alg"` encoding.
    static func validZhipuCredential(_ key: String) -> Bool {
        guard validCredential(key), key.hasPrefix("eyJ"), key.split(separator: ".").count == 3 else {
            return false
        }
        return true
    }

    static func validCredential(_ key: String) -> Bool {
        !key.isEmpty && key.utf8.count <= 8_192 && key.unicodeScalars.allSatisfy { (33...126).contains($0.value) }
    }

    static func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.scheme?.lowercased() == "https" && rhs.scheme?.lowercased() == "https"
            && lhs.host?.lowercased() == rhs.host?.lowercased()
            && (lhs.port ?? 443) == (rhs.port ?? 443)
            && rhs.user == nil && rhs.password == nil
    }

    static func retryAfter(_ value: String?, at date: Date) -> Date? {
        guard let value else { return nil }
        if let seconds = Double(value), seconds.isFinite, seconds >= 0 {
            let retry = date.addingTimeInterval(seconds)
            return ProviderUsageBucket.supportsResetDate(retry) ? retry : nil
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
        return formatter.date(from: value).flatMap { ProviderUsageBucket.supportsResetDate($0) ? $0 : nil }
    }

    private static func decimal(_ value: String) -> Decimal? {
        guard value.utf8.count <= 128,
              value.range(of: "^-?[0-9]+(?:\\.[0-9]+)?(?:[eE][+-]?[0-9]+)?$", options: .regularExpression) != nil,
              let result = Decimal(string: value, locale: Locale(identifier: "en_US_POSIX")),
              !result.isNaN else { return nil }
        return result
    }

    private static func number(_ value: Any?) -> Double? {
        let number: Double?
        if let raw = value as? NSNumber, CFGetTypeID(raw) != CFBooleanGetTypeID() {
            number = raw.doubleValue
        } else if let raw = value as? String {
            number = Double(raw)
        } else { number = nil }
        return number.flatMap { $0.isFinite ? $0 : nil }
    }

    private static func integer(_ value: Any?) -> Int64? {
        if let raw = value as? String { return Int64(raw) }
        guard let raw = value as? NSNumber, CFGetTypeID(raw) != CFBooleanGetTypeID() else { return nil }
        // stringValue avoids Double's rounding at Int64's upper boundary.
        return Int64(raw.stringValue)
    }

    private static func millisecondsTimestamp(_ value: Any?) -> Date? {
        guard let number = number(value), number > 0 else { return nil }
        let seconds = number / 1_000
        guard seconds.isFinite, seconds <= ProviderUsageBucket.maximumResetTimestamp else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }
}
