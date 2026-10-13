import XCTest
@testable import CodexMeterCore

final class ProviderUsageTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_800_000_000)

    private func connection(_ kind: ProviderKind = .deepSeek, region: ProviderRegion = .global) -> ProviderConnection {
        ProviderConnection(id: UUID(), kind: kind, region: region, name: "Fixture",
                           enabled: true, credentialReference: UUID().uuidString,
                           identityEpoch: UUID(), selectedBucketID: nil)
    }

    private func decode(_ json: String, kind: ProviderKind) throws -> ProviderUsageSnapshot {
        try ProviderUsageAdapter.decode(Data(json.utf8), kind: kind, fetchedAt: date)
    }

    func testDeepSeekUsesTotalBalanceWithoutAddingComponentsAndPreservesCurrencies() throws {
        let snapshot = try decode("""
        {"is_available":true,"balance_infos":[
          {"currency":"CNY","total_balance":"110.1234567890123456789","granted_balance":"10","topped_up_balance":"100"},
          {"currency":"USD","total_balance":"2.50","granted_balance":"1","topped_up_balance":"1.50"}
        ]}
        """, kind: .deepSeek)
        XCTAssertEqual(snapshot.buckets.count, 2)
        XCTAssertEqual(snapshot.buckets[0].metric,
                       .money(remaining: Decimal(string: "110.1234567890123456789")!, currency: "CNY"))
        XCTAssertNil(snapshot.buckets[0].remainingPercent)
        XCTAssertEqual(snapshot.buckets[1].metric, .money(remaining: Decimal(string: "2.50")!, currency: "USD"))
        XCTAssertEqual(snapshot.fetchedAt, date)
    }

    func testMissingMalformedOrDuplicatedDeepSeekBalanceIsNotAZeroBalance() {
        for json in [
            "{}", "{\"balance_infos\":[]}",
            "{\"balance_infos\":[{\"currency\":\"CNY\"}]}",
            "{\"balance_infos\":[{\"currency\":\"CNY\",\"total_balance\":\"12oops\"}]}",
            "{\"balance_infos\":[{\"currency\":\"USD\",\"total_balance\":\"1\"},{\"currency\":\"USD\",\"total_balance\":\"2\"}]}"
        ] {
            XCTAssertThrowsError(try decode(json, kind: .deepSeek))
        }
    }

    func testMiniMaxPreservesDistinctModelWindowsAndRemainingPercentSemantics() throws {
        // A synthetic protocol fixture, not a captured or verified live-account response.
        let snapshot = try decode("""
        {"base_resp":{"status_code":0},"model_remains":[
          {"model_name":"general","current_interval_remaining_percent":82,
           "current_weekly_remaining_percent":41,"current_weekly_status":1,
           "start_time":1800000000000,"end_time":1800018000000,
           "weekly_start_time":1800000000000,"weekly_end_time":1800604800000},
          {"model_name":"video","current_interval_remaining_percent":50,
           "start_time":1800000000000,"end_time":1800086400000}
        ]}
        """, kind: .miniMax)
        XCTAssertEqual(snapshot.buckets.map(\.id), ["general:interval", "general:weekly", "video:interval"])
        XCTAssertEqual(snapshot.buckets.map(\.remainingPercent), [82, 41, 50])
        XCTAssertEqual(snapshot.buckets[0].windowDuration, 18_000)
        XCTAssertEqual(snapshot.buckets[1].windowDuration, 604_800)
        XCTAssertEqual(snapshot.buckets[2].windowDuration, 86_400)
        XCTAssertTrue(ProviderKind.miniMax.isExperimental)
    }

    func testMiniMaxUnlimitedIsDistinctFromUnavailablePlanSentinel() throws {
        let snapshot = try decode("""
        {"model_remains":[{"model_name":"general","current_interval_remaining_percent":100,
         "current_weekly_status":3,"current_weekly_remaining_percent":100}]}
        """, kind: .miniMax)
        XCTAssertEqual(snapshot.buckets.count, 2)
        XCTAssertEqual(snapshot.buckets[0].metric, .percentage(remaining: 100))
        XCTAssertEqual(snapshot.buckets[1].metric, .unlimited)
        XCTAssertNil(snapshot.buckets[1].remainingPercent)
        let absent = try decode("""
        {"model_remains":[{"model_name":"video","current_interval_total_count":0,
         "current_weekly_total_count":0,"current_interval_status":3,"current_weekly_status":3,
         "end_time":1800018000000,"weekly_end_time":1800604800000}]}
        """, kind: .miniMax)
        XCTAssertEqual(absent.buckets.map(\.metric), [.unavailable, .unavailable])
        XCTAssertTrue(absent.buckets.allSatisfy { $0.resetsAt == nil && $0.windowDuration == nil })
    }

    func testMiniMaxExplicitPercentageIsAuthoritativeAndLegacyCountsOnlyProduceRatio() throws {
        let snapshot = try decode("""
        {"model_remains":[
          {"model_name":"video","current_interval_usage_count":3,"current_interval_total_count":5},
          {"model_name":"general","current_interval_usage_count":90,"current_interval_total_count":100,
           "current_interval_remaining_percent":10},
          {"model_name":"audio","current_interval_usage_count":10,"current_interval_total_count":100,
           "current_interval_remaining_percent":10}
        ]}
        """, kind: .miniMax)
        XCTAssertEqual(snapshot.buckets[0].metric, .percentage(remaining: 60))
        XCTAssertEqual(snapshot.buckets[0].remainingPercent, 60)
        XCTAssertNil(snapshot.buckets[0].windowDuration)
        XCTAssertEqual(snapshot.buckets[1].metric, .percentage(remaining: 10))
        XCTAssertEqual(snapshot.buckets[2].metric, .percentage(remaining: 10))
        for json in [
            "{\"model_remains\":[{\"model_name\":\"general\",\"current_interval_total_count\":0,\"current_interval_usage_count\":10}]}",
            "{\"model_remains\":[{\"model_name\":\"video\",\"current_interval_remaining_count\":3,\"unit\":\"requests\"}]}",
            "{\"model_remains\":[{\"model_name\":\"general\",\"current_monthly_remaining_percent\":90}]}"
        ] { XCTAssertThrowsError(try decode(json, kind: .miniMax)) }
    }

    func testMiniMaxBoostPreservesActualPercentAndMissingTimingDoesNotInventWindow() throws {
        let snapshot = try decode("""
        {"model_remains":[{"model_name":"general","current_interval_remaining_percent":80,
         "current_weekly_remaining_percent":100,"weekly_boost_permille":1500,
         "remains_time":18000000,"weekly_remains_time":604800000}]}
        """, kind: .miniMax)
        XCTAssertEqual(snapshot.buckets[1].metric, .percentage(remaining: 150))
        XCTAssertEqual(snapshot.buckets[1].remainingPercent, 100)
        XCTAssertEqual(snapshot.buckets[1].quotaBoostMultiplier, 1.5)
        XCTAssertTrue(snapshot.buckets.allSatisfy { $0.windowDuration == nil && $0.resetsAt == nil })
        let boostedLow = try decode("""
        {"model_remains":[{"model_name":"general","current_weekly_remaining_percent":40,
         "weekly_boost_permille":1500,"weekly_start_time":1799999900000,
         "weekly_end_time":1800000100000}]}
        """, kind: .miniMax).buckets[0]
        XCTAssertEqual(boostedLow.metric, .percentage(remaining: 60))
        XCTAssertEqual(boostedLow.remainingPercent, 40)
        XCTAssertEqual(boostedLow.remainingTimePercent(at: date), 50)
        XCTAssertLessThan(boostedLow.remainingPercent!, boostedLow.remainingTimePercent(at: date)!)
        let exhausted = try decode("""
        {"model_remains":[{"model_name":"general","current_interval_status":2,
         "current_interval_total_count":100,"current_interval_usage_count":100}]}
        """, kind: .miniMax)
        XCTAssertEqual(exhausted.buckets[0].metric, .percentage(remaining: 0))
    }

    func testInvalidMiniMaxValuesRemainUnavailableRatherThanClampedIntoSuccess() throws {
        let snapshot = try decode("""
        {"model_remains":[{"model_name":"general","current_interval_remaining_percent":false,
         "current_weekly_remaining_percent":10,"current_weekly_status":1}]}
        """, kind: .miniMax)
        XCTAssertEqual(snapshot.buckets[0].metric, .unavailable)
        XCTAssertNil(snapshot.buckets[0].remainingPercent)
        XCTAssertEqual(snapshot.buckets[1].remainingPercent, 10)
        XCTAssertThrowsError(try decode("{\"model_remains\":[{\"model_name\":\"general\",\"current_interval_remaining_percent\":120}]}", kind: .miniMax))
    }

    func testUnknownErrorOrTokenFieldsDoNotBecomeQuota() {
        for json in ["{\"tokens\":123}", "{\"base_resp\":{\"status_code\":1004,\"status_msg\":\"server text\"}}",
                     "{\"model_remains\":[]}", "{\"model_remains\":[{\"model_name\":\"general\",\"used_tokens\":100}]}" ] {
            XCTAssertThrowsError(try decode(json, kind: .miniMax))
        }
    }

    func testResponseAndBucketLimitsAreEnforced() {
        XCTAssertThrowsError(try ProviderUsageAdapter.decode(
            Data(repeating: 32, count: ProviderUsageAdapter.maximumResponseBytes + 1), kind: .deepSeek, fetchedAt: date)) { error in
                XCTAssertEqual((error as? ProviderUsageFailure)?.code, .responseTooLarge)
            }
        let rows = (0...ProviderUsageAdapter.maximumBuckets).map { _ in
            "{\"currency\":\"USD\",\"total_balance\":\"1\"}"
        }.joined(separator: ",")
        XCTAssertThrowsError(try decode("{\"balance_infos\":[\(rows)]}", kind: .deepSeek))
    }

    func testTimeRingRequiresValidDurationAndFutureReset() {
        let noDuration = ProviderUsageBucket(id: "one", title: "One", metric: .percentage(remaining: 50), resetsAt: date.addingTimeInterval(100))
        XCTAssertNil(noDuration.remainingTimePercent(at: date))
        let bucket = ProviderUsageBucket(id: "two", title: "Two", metric: .percentage(remaining: 50), windowDuration: 200,
                                         resetsAt: date.addingTimeInterval(100))
        XCTAssertEqual(bucket.remainingTimePercent(at: date), 50)
        XCTAssertNil(bucket.remainingTimePercent(at: date.addingTimeInterval(101)))
        XCTAssertNil(ProviderUsageBucket(id: "three", title: "Three", metric: .unlimited).remainingPercent)
        XCTAssertNil(ProviderUsageBucket(id: "four", title: "Four", metric: .count(remaining: 5, unit: "requests")).remainingPercent)
        XCTAssertNil(ProviderUsageBucket(id: "extreme", title: "Extreme", metric: .percentage(remaining: 50),
            windowDuration: 200, resetsAt: Date(timeIntervalSince1970: 1e308)).remainingTimePercent(at: date))
        XCTAssertNil(ProviderUsageBucket(id: "duration", title: "Duration", metric: .percentage(remaining: 50),
            windowDuration: 1e308, resetsAt: date.addingTimeInterval(100)).remainingTimePercent(at: date))
        XCTAssertNil(bucket.remainingTimePercent(at: Date(timeIntervalSince1970: .infinity)))
    }

    func testMiniMaxEpochMillisecondsRejectOutOfRangeDatesWithoutGuessingTiming() throws {
        for endpoint in ["1e308", "253402300800000", "-1", "false"] {
            let snapshot = try decode("""
            {"model_remains":[{"model_name":"general","current_interval_remaining_percent":40,
             "start_time":1800000000000,"end_time":\(endpoint)}]}
            """, kind: .miniMax)
            XCTAssertNil(snapshot.buckets[0].resetsAt)
            XCTAssertNil(snapshot.buckets[0].windowDuration)
        }
        let milliseconds = try decode("""
        {"model_remains":[{"model_name":"general","current_interval_remaining_percent":40,
         "start_time":1800000000000,"end_time":1800018000000}]}
        """, kind: .miniMax).buckets[0]
        XCTAssertEqual(milliseconds.resetsAt, date.addingTimeInterval(18_000))
        XCTAssertEqual(milliseconds.windowDuration, 18_000)
    }

    func testZhipuDecodesCodingPlanWindowsWithExactCountsAndTiming() throws {
        // Captured console response shape; protocol fixture, not a live verified account.
        let snapshot = try decode("""
        {"code":200,"msg":"ok","data":{"level":"pro","limits":[
          {"type":"CREDIT_LIMIT","unit":3,"number":5,"usage":15000,"currentValue":604,
           "remaining":14396,"percentage":4,"nextResetTime":1800007200000},
          {"type":"CREDIT_LIMIT","unit":6,"number":1,"usage":66000,"currentValue":10716,
           "remaining":55284,"percentage":16,"nextResetTime":1800604800000}
        ]}}
        """, kind: .zhipu)
        XCTAssertEqual(snapshot.buckets.map(\.id), ["zhipu:300", "zhipu:10080"])
        XCTAssertEqual(snapshot.buckets[0].metric, .count(remaining: 14396, unit: "credits"))
        XCTAssertEqual(snapshot.buckets[0].totalCount, 15000)
        XCTAssertEqual(snapshot.buckets[1].metric, .count(remaining: 55284, unit: "credits"))
        XCTAssertEqual(snapshot.buckets[1].totalCount, 66000)
        XCTAssertEqual(snapshot.buckets[0].windowDuration, 18_000)
        XCTAssertEqual(snapshot.buckets[1].windowDuration, 604_800)
        XCTAssertEqual(snapshot.buckets[0].resetsAt, date.addingTimeInterval(7_200))
        XCTAssertEqual(snapshot.buckets[1].resetsAt, date.addingTimeInterval(604_800))
        XCTAssertEqual(snapshot.buckets[0].remainingPercent ?? 0, 95.97, accuracy: 0.01)
        XCTAssertTrue(ProviderKind.zhipu.isExperimental)
    }

    func testZhipuBusinessCodesAndMalformedLimitsFailClosed() {
        XCTAssertThrowsError(try decode("""
        {"code":401,"msg":"private","data":{"limits":[]}}
        """, kind: .zhipu)) { error in
            XCTAssertEqual((error as? ProviderUsageFailure)?.code, .authentication)
        }
        XCTAssertThrowsError(try decode("""
        {"code":500,"msg":"private","data":{"limits":[]}}
        """, kind: .zhipu)) { error in
            XCTAssertEqual((error as? ProviderUsageFailure)?.code, .invalidResponse)
        }
        for json in [
            "{\"data\":{\"limits\":[]}}",
            "{\"data\":{\"limits\":[{\"unit\":3,\"number\":5,\"usage\":0,\"remaining\":0}]}}",
            "{\"data\":{\"limits\":[{\"unit\":3,\"number\":5,\"usage\":100,\"remaining\":101}]}}",
            "{\"data\":{\"limits\":[{\"unit\":3,\"number\":5,\"remaining\":10}]}}",
            "{\"data\":{}}",
            "{\"limits\":[{\"unit\":3,\"number\":5,\"usage\":100,\"remaining\":10}]}"
        ] {
            XCTAssertThrowsError(try decode(json, kind: .zhipu))
        }
    }

    func testZhipuUnknownUnitsKeepIdentityAndResetWithoutInventingWindows() throws {
        let snapshot = try decode("""
        {"code":200,"data":{"limits":[
          {"unit":9,"number":3,"usage":500,"remaining":250,"nextResetTime":1800007200000}
        ]}}
        """, kind: .zhipu)
        XCTAssertEqual(snapshot.buckets.map(\.id), ["zhipu:u9n3"])
        XCTAssertNil(snapshot.buckets[0].windowDuration)
        XCTAssertEqual(snapshot.buckets[0].resetsAt, date.addingTimeInterval(7_200))
        XCTAssertEqual(snapshot.buckets[0].remainingPercent ?? 0, 50, accuracy: 0.01)
    }

    func testZhipuDuplicateWindowTypesKeepStableSuffixedIdentities() throws {
        let snapshot = try decode("""
        {"code":200,"data":{"limits":[
          {"unit":3,"number":5,"usage":100,"remaining":50},
          {"unit":3,"number":5,"usage":200,"remaining":10}
        ]}}
        """, kind: .zhipu)
        XCTAssertEqual(snapshot.buckets.map(\.id), ["zhipu:300", "zhipu:300#2"])
        XCTAssertEqual(snapshot.buckets[1].metric, .count(remaining: 10, unit: "credits"))
    }

    func testZhipuCredentialsAreSessionJWTsWithoutBearerPrefix() throws {
        XCTAssertTrue(ProviderUsageAdapter.validZhipuCredential(
            "eyJhbGciOiJIUzUxMiJ9.eyJzdWIiOiIxIn0.c2ln"))
        XCTAssertFalse(ProviderUsageAdapter.validZhipuCredential("plain-api-key.id.secret"))
        XCTAssertFalse(ProviderUsageAdapter.validZhipuCredential("Bearer eyJhbGciOiJIUzUxMiJ9.a.b"))
        XCTAssertFalse(ProviderUsageAdapter.validZhipuCredential("eyJhbGciOiJIUzUxMiJ9.only-two"))
        let request = try ProviderUsageAdapter.request(for: connection(.zhipu), key: "eyJhbGciOiJIUzUxMiJ9.a.b")
        XCTAssertEqual(request.url?.absoluteString, "https://bigmodel.cn/api/monitor/usage/quota/limit?type=2")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "eyJhbGciOiJIUzUxMiJ9.a.b")
        XCTAssertThrowsError(try ProviderUsageAdapter.request(for: connection(.zhipu), key: "not-a-jwt"))
    }

    func testZhipuFetchFallsBackFromTeamToPersonalScope() async throws {
        let transport = ScopedQuotaTransport()
        let snapshot = try await ProviderUsageAdapter.fetch(
            connection: connection(.zhipu), key: "eyJhbGciOiJIUzUxMiJ9.a.b",
            transport: transport, now: { date })
        XCTAssertEqual(snapshot.buckets.map(\.id), ["zhipu:300"])
        let requests = await transport.visitedTypes
        XCTAssertEqual(requests, [2, 1])
    }

    func testZhipuConsoleAuthCodeMapsToAuthentication() {
        XCTAssertThrowsError(try decode("""
        {"code":1001,"msg":"private","success":false}
        """, kind: .zhipu)) { error in
            XCTAssertEqual((error as? ProviderUsageFailure)?.code, .authentication)
        }
        let personalRequest = try? ProviderUsageAdapter.request(
            for: connection(.zhipu), key: "eyJhbGciOiJIUzUxMiJ9.a.b", quotaType: 1)
        XCTAssertEqual(personalRequest?.url?.absoluteString,
                       "https://bigmodel.cn/api/monitor/usage/quota/limit?type=1")
    }

    func testOfficialRegionsRequestsAndOriginPolicy() throws {
        let cn = try ProviderUsageAdapter.request(for: connection(.miniMax, region: .china), key: "fixture-key")
        let global = try ProviderUsageAdapter.request(for: connection(.miniMax, region: .global), key: "fixture-key")
        XCTAssertEqual(cn.url?.absoluteString, "https://api.minimax.cn/v1/token_plan/remains")
        XCTAssertEqual(global.url?.absoluteString, "https://api.minimax.io/v1/token_plan/remains")
        XCTAssertEqual(global.httpMethod, "GET")
        XCTAssertEqual(global.timeoutInterval, 20)
        XCTAssertEqual(global.cachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertThrowsError(try ProviderUsageAdapter.request(for: connection(), key: "fixture\r\nInjected: header"))
        let official = URL(string: "https://api.deepseek.com/user/balance")!
        XCTAssertTrue(ProviderUsageAdapter.sameOrigin(official, URL(string: "https://api.deepseek.com:443/other")!))
        for url in ["http://api.deepseek.com/user/balance", "https://api.deepseek.com:444/user/balance",
                    "https://api.deepseek.com.example.com/", "https://www.minimax.io/", "https://key@api.deepseek.com/"] {
            XCTAssertFalse(ProviderUsageAdapter.sameOrigin(official, URL(string: url)!))
        }
    }

    func testRefreshScheduleDeduplicatesAndInvalidatesRequestIdentity() {
        var state = ProviderRefreshState()
        let first = state.begin(at: date, manual: false)!
        XCTAssertNil(state.begin(at: date, manual: true))
        XCTAssertTrue(state.owns(first))
        state.cancelled()
        let second = state.begin(at: date, manual: false)!
        XCTAssertFalse(state.owns(first))
        XCTAssertTrue(state.owns(second))
        state.succeeded(at: date)
        XCTAssertNil(state.begin(at: date.addingTimeInterval(299), manual: false))
        XCTAssertNotNil(state.begin(at: date.addingTimeInterval(300), manual: false))
    }

    func testFailuresBackOffButManualRefreshCannotBypassRateLimit() {
        var state = ProviderRefreshState()
        var now = date
        for interval in [20.0, 40, 80, 160, 300, 300] {
            XCTAssertNotNil(state.begin(at: now, manual: false))
            state.failed(at: now, code: .network)
            XCTAssertEqual(state.retryAfter, now.addingTimeInterval(interval))
            XCTAssertNil(state.begin(at: now.addingTimeInterval(interval - 1), manual: false))
            now = now.addingTimeInterval(interval)
        }
        XCTAssertNotNil(state.begin(at: now, manual: true))
        state.failed(at: now, code: .rateLimited, retryAt: now.addingTimeInterval(600))
        XCTAssertNil(state.begin(at: now.addingTimeInterval(599), manual: true))
        XCTAssertNotNil(state.begin(at: now.addingTimeInterval(600), manual: true))
    }

    func testAuthenticationFailureStopsAutomaticPollingWithoutBlockingOtherConnections() {
        var first = ProviderRefreshState(), second = ProviderRefreshState()
        XCTAssertNotNil(first.begin(at: date, manual: false))
        first.failed(at: date, code: .authentication)
        XCTAssertNil(first.begin(at: date.addingTimeInterval(10_000), manual: false))
        XCTAssertNotNil(second.begin(at: date, manual: false))
        XCTAssertNotNil(first.begin(at: date, manual: true))
        first.succeeded(at: date)
        XCTAssertFalse(first.authenticationBlocked)
    }

    func testManualRefreshMayBypassOrdinaryNetworkBackoff() {
        var state = ProviderRefreshState()
        _ = state.begin(at: date, manual: false)
        state.failed(at: date, code: .network)
        XCTAssertNotNil(state.begin(at: date.addingTimeInterval(1), manual: true))
    }

    func testRetryAfterSupportsSecondsAndHTTPDate() {
        XCTAssertEqual(ProviderUsageAdapter.retryAfter("120", at: date), date.addingTimeInterval(120))
        XCTAssertEqual(ProviderUsageAdapter.retryAfter("Wed, 21 Oct 2015 07:28:00 GMT", at: date), Date(timeIntervalSince1970: 1_445_412_480))
        XCTAssertNil(ProviderUsageAdapter.retryAfter("-1", at: date))
        XCTAssertNil(ProviderUsageAdapter.retryAfter("NaN", at: date))
        XCTAssertNil(ProviderUsageAdapter.retryAfter("1e308", at: date))
        XCTAssertNil(ProviderUsageAdapter.retryAfter("invalid", at: date))
    }

    func testMiniMaxBusinessErrorCodesDoNotExposeServerMessages() {
        for (code, expected) in [(1004, ProviderUsageErrorCode.authentication), (2049, .authentication),
                                 (1002, .rateLimited), (2045, .rateLimited), (1001, .timeout)] {
            XCTAssertThrowsError(try decode("{\"base_resp\":{\"status_code\":\(code),\"status_msg\":\"private server text\"}}",
                                             kind: .miniMax)) { error in
                XCTAssertEqual((error as? ProviderUsageFailure)?.code, expected)
            }
        }
    }

    func testPresentMalformedMiniMaxBusinessEnvelopeCannotPublishReadyQuota() {
        for envelope in ["\"error\"", "false", "7", "[]", "null", "{}", "{\"status_code\":false}"] {
            XCTAssertThrowsError(try decode("""
            {"base_resp":\(envelope),"model_remains":[{"model_name":"general","current_interval_remaining_percent":100}]}
            """, kind: .miniMax)) { error in
                XCTAssertEqual((error as? ProviderUsageFailure)?.code, .invalidResponse)
            }
        }
    }

    func testAdapterUsesInjectedTransportAndMapsOnlyLocalErrorCodes() async throws {
        let url = ProviderUsageAdapter.endpoint(kind: .deepSeek, region: .global)
        let response = ProviderHTTPResponse(data: Data("{\"balance_infos\":[{\"currency\":\"USD\",\"total_balance\":\"1.25\"}]}".utf8),
                                           statusCode: 200, headers: [:], url: url)
        let transport = RecordingProviderTransport(response: response)
        let fixedDate = date
        let snapshot = try await ProviderUsageAdapter.fetch(connection: connection(), key: "fixture-key", transport: transport, now: { fixedDate })
        XCTAssertEqual(snapshot.buckets.first?.metric, .money(remaining: Decimal(string: "1.25")!, currency: "USD"))
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-key")
        for (status, code) in [(401, ProviderUsageErrorCode.authentication), (403, .authentication), (429, .rateLimited), (500, .network), (302, .invalidResponse)] {
            let failing = RecordingProviderTransport(response: ProviderHTTPResponse(data: Data("private server body".utf8),
                    statusCode: status, headers: ["retry-after": "90"], url: url))
            do {
                _ = try await ProviderUsageAdapter.fetch(connection: connection(), key: "fixture-key", transport: failing, now: { fixedDate })
                XCTFail("Expected a local failure")
            } catch let error as ProviderUsageFailure {
                XCTAssertEqual(error.code, code)
                if status == 429 { XCTAssertEqual(error.retryAt, fixedDate.addingTimeInterval(90)) }
            }
        }
    }
}

private actor RecordingProviderTransport: ProviderUsageTransport {
    let response: ProviderHTTPResponse
    private(set) var requests: [URLRequest] = []
    init(response: ProviderHTTPResponse) { self.response = response }
    func send(_ request: URLRequest) async throws -> ProviderHTTPResponse {
        requests.append(request)
        return response
    }
}

/// Returns the captured team-scope empty answer for type=2 and a populated
/// personal-scope answer for type=1, recording the visited scopes in order.
private actor ScopedQuotaTransport: ProviderUsageTransport {
    private(set) var visitedTypes: [Int] = []
    func send(_ request: URLRequest) async throws -> ProviderHTTPResponse {
        let query = request.url?.query ?? ""
        let scope = query.contains("type=2") ? 2 : 1
        visitedTypes.append(scope)
        let body = scope == 2
            ? "{\"code\":200,\"data\":{\"level\":\"pro\",\"limits\":[]}}"
            : "{\"code\":200,\"data\":{\"limits\":[{\"unit\":3,\"number\":5,\"usage\":100,\"remaining\":40,\"nextResetTime\":1800007200000}]}}"
        return ProviderHTTPResponse(data: Data(body.utf8), statusCode: 200, headers: [:], url: request.url!)
    }
}
