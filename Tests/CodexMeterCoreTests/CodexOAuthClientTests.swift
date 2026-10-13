import Foundation
import XCTest
@testable import CodexMeterCore

private actor OAuthStubTransport: CodexOAuthTransport {
    private var responses: [CodexOAuthHTTPResponse]
    private var requests: [URLRequest] = []

    init(_ responses: [CodexOAuthHTTPResponse]) { self.responses = responses }

    func send(_ request: URLRequest) async throws -> CodexOAuthHTTPResponse {
        requests.append(request)
        return responses.removeFirst()
    }

    func captured() -> [URLRequest] { requests }
}

final class CodexOAuthClientTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func reply(_ path: String, _ status: Int, _ json: String, host: String = "auth.openai.com") -> CodexOAuthHTTPResponse {
        CodexOAuthHTTPResponse(status: status, data: Data(json.utf8),
                               url: URL(string: "https://\(host)\(path)")!)
    }

    func testDeviceStartAndPendingOrSuccessfulPoll() async throws {
        let transport = OAuthStubTransport([
            reply("/api/accounts/deviceauth/usercode", 200,
                  #"{"device_auth_id":"private-id","user_code":"ABCD-EFGH","interval":"10","expires_in":900}"#),
            reply("/api/accounts/deviceauth/token", 403, #"{"message":"secret"}"#),
            reply("/api/accounts/deviceauth/token", 200,
                  #"{"authorization_code":"auth-code","code_verifier":"server-verifier"}"#)
        ])
        let client = CodexOAuthClient(transport: transport, now: { Date(timeIntervalSince1970: 1_800_000_000) })
        let device = try await client.startDeviceFlow()
        XCTAssertEqual(device.deviceAuthID, "private-id")
        XCTAssertEqual(device.userCode, "ABCD-EFGH")
        XCTAssertEqual(device.verificationURL.absoluteString, "https://auth.openai.com/codex/device")
        XCTAssertEqual(device.interval, 13)
        XCTAssertEqual(device.expiresAt, now.addingTimeInterval(900))
        let pending = try await client.pollDeviceFlow(deviceAuthID: device.deviceAuthID, userCode: device.userCode)
        XCTAssertNil(pending)
        let grant = try await client.pollDeviceFlow(deviceAuthID: device.deviceAuthID, userCode: device.userCode)
        XCTAssertEqual(grant?.authorizationCode, "auth-code")
        XCTAssertEqual(grant?.codeVerifier, "server-verifier")
        let requests = await transport.captured()
        XCTAssertEqual(requests[0].httpMethod, "POST")
        XCTAssertEqual(try JSONSerialization.jsonObject(with: requests[0].httpBody!) as? [String: String],
                       ["client_id": CodexOAuthClient.clientID])
        XCTAssertEqual(try JSONSerialization.jsonObject(with: requests[1].httpBody!) as? [String: String],
                       ["device_auth_id": "private-id", "user_code": "ABCD-EFGH"])
    }

    func testExchangeAndRefreshUseCorrectFormAndRetainRotatedToken() async throws {
        let transport = OAuthStubTransport([
            reply("/oauth/token", 200, #"{"access_token":"access","refresh_token":"refresh","id_token":"id","expires_in":120}"#),
            reply("/oauth/token", 200, #"{"access_token":"next","refresh_token":"rotated","expires_in":3600}"#)
        ])
        let client = CodexOAuthClient(transport: transport, now: { Date(timeIntervalSince1970: 1_800_000_000) })
        let initial = try await client.exchangeCode(code: "code +", verifier: "verifier&")
        XCTAssertEqual(initial.accessToken, "access")
        XCTAssertEqual(initial.refreshToken, "refresh")
        XCTAssertEqual(initial.idToken, "id")
        XCTAssertEqual(initial.expiresAt, now.addingTimeInterval(120))
        let refreshed = try await client.refresh(refreshToken: "refresh")
        XCTAssertEqual(refreshed.refreshToken, "rotated")
        XCTAssertNil(refreshed.idToken)
        let requests = await transport.captured()
        let exchange = String(data: requests[0].httpBody!, encoding: .utf8)!
        XCTAssertTrue(exchange.contains("code=code%20%2B"))
        XCTAssertTrue(exchange.contains("code_verifier=verifier%26"))
        XCTAssertTrue(exchange.contains("redirect_uri=https%3A%2F%2Fauth.openai.com%2Fdeviceauth%2Fcallback"))
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Content-Type"), "application/x-www-form-urlencoded")
        let refresh = String(data: requests[1].httpBody!, encoding: .utf8)!
        XCTAssertTrue(refresh.contains("grant_type=refresh_token"))
        XCTAssertTrue(refresh.contains("scope=openid%20profile%20email"))
    }

    func testQuotaDecodesWindowsAndDoesNotInventMissingTiming() async throws {
        let transport = OAuthStubTransport([
            reply("/backend-api/wham/usage", 200, #"{"plan_type":"plus","rate_limit":{"primary_window":{"used_percent":25,"limit_window_seconds":18000,"reset_at":1800018000},"secondary_window":{"used_percent":90,"limit_window_seconds":604800}},"additional_rate_limits":[{"limit_name":"GPT-Reserve","rate_limit":{"primary_window":{"used_percent":10,"limit_window_seconds":604800,"reset_at":1800604800}}}]}"#, host: "chatgpt.com")
        ])
        let client = CodexOAuthClient(transport: transport)
        let quota = try await client.fetchQuota(accessToken: "secret-token", accountID: "workspace")
        XCTAssertEqual(quota.planType, "plus")
        XCTAssertEqual(Set(quota.windows.map(\.usedPercent)), Set([25, 90, 10]))
        XCTAssertEqual(quota.windows[0].remainingPercent, 75)
        XCTAssertEqual(quota.windows[0].windowDurationMins, 300)
        XCTAssertNil(quota.windows.first(where: { $0.usedPercent == 90 })?.resetsAt)
        XCTAssertEqual(quota.windows.first(where: { $0.usedPercent == 10 })?.name, "GPT-Reserve")
        let request = await transport.captured()[0]
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret-token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "ChatGPT-Account-Id"), "workspace")
    }

    func testSanitizedErrorsAndResponseLimits() async throws {
        let expired = CodexOAuthClient(transport: OAuthStubTransport([
            reply("/api/accounts/deviceauth/token", 410, #"{"token":"leak"}"#)
        ]))
        do { _ = try await expired.pollDeviceFlow(deviceAuthID: "id", userCode: "code"); XCTFail() }
        catch { XCTAssertEqual(error as? CodexOAuthError, .deviceCodeExpired); XCTAssertFalse(String(describing: error).contains("leak")) }

        let invalid = CodexOAuthClient(transport: OAuthStubTransport([
            reply("/oauth/token", 400, #"{"error":{"code":"refresh_token_reused"},"token":"leak"}"#)
        ]))
        do { _ = try await invalid.refresh(refreshToken: "secret"); XCTFail() }
        catch { XCTAssertEqual(error as? CodexOAuthError, .refreshTokenInvalid) }

        // Standard RFC 6749 invalid_grant also proves the grant dead.
        let revoked = CodexOAuthClient(transport: OAuthStubTransport([
            reply("/oauth/token", 401, #"{"error":"invalid_grant","error_description":"token expired"}"#)
        ]))
        do { _ = try await revoked.refresh(refreshToken: "secret"); XCTFail() }
        catch { XCTAssertEqual(error as? CodexOAuthError, .refreshTokenInvalid) }

        // A bare 401/403 (proxy exit block, WAF page) keeps the stored grant
        // retryable instead of reporting it revoked.
        for status in [401, 403] {
            let blocked = CodexOAuthClient(transport: OAuthStubTransport([
                reply("/oauth/token", status, "<html>blocked</html>")
            ]))
            do { _ = try await blocked.refresh(refreshToken: "secret"); XCTFail() }
            catch { XCTAssertEqual(error as? CodexOAuthError, .authentication) }
        }

        let tooLarge = CodexOAuthClient(transport: OAuthStubTransport([
            CodexOAuthHTTPResponse(status: 200, data: Data(count: CodexOAuthClient.maximumResponseBytes + 1),
                                   url: URL(string: "https://auth.openai.com/api/accounts/deviceauth/usercode")!)
        ]))
        do { _ = try await tooLarge.startDeviceFlow(); XCTFail() }
        catch { XCTAssertEqual(error as? CodexOAuthError, .responseTooLarge) }
    }

    func testMalformedQuotaAndRedirectAreRejected() async throws {
        for json in [#"{"rate_limit":{"primary_window":{"used_percent":false}}}"#,
                     #"{"rate_limit":{"primary_window":{"used_percent":110}}}"#,
                     #"{"rate_limit":{}}"#] {
            XCTAssertThrowsError(try CodexOAuthClient.decodeQuota(Data(json.utf8)))
        }
        let redirected = CodexOAuthClient(transport: OAuthStubTransport([
            reply("/api/accounts/deviceauth/usercode", 200, #"{"device_auth_id":"a","user_code":"b"}"#, host: "attacker.example")
        ]))
        do { _ = try await redirected.startDeviceFlow(); XCTFail() }
        catch { XCTAssertEqual(error as? CodexOAuthError, .invalidResponse) }
    }
}
