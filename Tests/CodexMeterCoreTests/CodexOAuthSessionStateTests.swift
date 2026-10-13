import XCTest
@testable import CodexMeterCore

final class CodexOAuthSessionStateTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testEmptySessionRequiresRefresh() {
        let state = CodexOAuthSessionState()

        XCTAssertNil(state.accessToken)
        XCTAssertEqual(state.expiresAt, .distantPast)
        XCTAssertNil(state.pendingRefreshToken)
        XCTAssertTrue(state.requiresTokenRefresh(at: now))
        XCTAssertTrue(state.requiresTokenRefresh(at: .distantPast))
    }

    func testRefreshThresholdIsStrictlyLessThanSixtySeconds() {
        var state = CodexOAuthSessionState()
        state.accept(makeTokens(expiresIn: 120))

        XCTAssertFalse(state.requiresTokenRefresh(at: now.addingTimeInterval(59.999)))
        XCTAssertFalse(state.requiresTokenRefresh(at: now.addingTimeInterval(60)))
        XCTAssertTrue(state.requiresTokenRefresh(at: now.addingTimeInterval(60.001)))
        XCTAssertTrue(state.requiresTokenRefresh(at: now.addingTimeInterval(120)))
        XCTAssertTrue(state.requiresTokenRefresh(at: now.addingTimeInterval(121)))
    }

    func testTransientFailuresKeepValidAccessTokenReusable() {
        let failures: [CodexOAuthError] = [
            .authentication, .network, .timeout, .rateLimited, .invalidResponse, .responseTooLarge
        ]

        for failure in failures {
            var state = CodexOAuthSessionState()
            let tokens = makeTokens()
            state.accept(tokens)
            state.didPersistRefreshToken()

            state.failed(failure)

            XCTAssertEqual(state.accessToken, tokens.accessToken)
            XCTAssertEqual(state.expiresAt, tokens.expiresAt)
            XCTAssertNil(state.pendingRefreshToken)
            XCTAssertFalse(state.requiresTokenRefresh(at: now.addingTimeInterval(60)))
        }
    }

    func testAuthenticationFailureKeepsValidAccessTokenAndPendingRotation() {
        var state = CodexOAuthSessionState()
        let tokens = makeTokens(refreshToken: "rotated-refresh")
        state.accept(tokens)

        state.failed(.authentication)

        XCTAssertEqual(state.accessToken, tokens.accessToken)
        XCTAssertEqual(state.expiresAt, tokens.expiresAt)
        XCTAssertEqual(state.pendingRefreshToken, "rotated-refresh")
        XCTAssertFalse(state.requiresTokenRefresh(at: now))
    }

    func testAccessTokenRejectionInvalidatesOnlyAccessToken() {
        var state = CodexOAuthSessionState()
        state.accept(makeTokens(refreshToken: "rotated-refresh"))

        state.failed(.accessTokenRejected)

        XCTAssertNil(state.accessToken)
        XCTAssertEqual(state.expiresAt, .distantPast)
        XCTAssertEqual(state.pendingRefreshToken, "rotated-refresh")
        XCTAssertTrue(state.requiresTokenRefresh(at: now))
    }

    func testUnpersistedRotationSurvivesSubsequentFailures() {
        var state = CodexOAuthSessionState()
        let tokens = makeTokens(refreshToken: "latest-refresh")
        state.accept(tokens)

        // A failed storage write leaves the persistence acknowledgement uncalled.
        XCTAssertEqual(state.pendingRefreshToken, "latest-refresh")
        for failure in [CodexOAuthError.authentication, .network, .timeout, .rateLimited, .invalidResponse, .responseTooLarge] {
            state.failed(failure)
            XCTAssertEqual(state.pendingRefreshToken, "latest-refresh")
            XCTAssertEqual(state.accessToken, tokens.accessToken)
            XCTAssertEqual(state.expiresAt, tokens.expiresAt)
            XCTAssertFalse(state.requiresTokenRefresh(at: now))
        }

        state.failed(.accessTokenRejected)
        XCTAssertEqual(state.pendingRefreshToken, "latest-refresh")
        XCTAssertNil(state.accessToken)
        XCTAssertTrue(state.requiresTokenRefresh(at: now))

        state.failed(.network)
        XCTAssertEqual(state.pendingRefreshToken, "latest-refresh")
        XCTAssertNil(state.accessToken)
        XCTAssertEqual(state.expiresAt, .distantPast)
    }

    func testSuccessfulPersistenceClearsOnlyPendingCredential() {
        var state = CodexOAuthSessionState()
        let tokens = makeTokens(refreshToken: "rotated-refresh")
        state.accept(tokens)

        state.didPersistRefreshToken()

        XCTAssertNil(state.pendingRefreshToken)
        XCTAssertEqual(state.accessToken, tokens.accessToken)
        XCTAssertEqual(state.expiresAt, tokens.expiresAt)
        XCTAssertFalse(state.requiresTokenRefresh(at: now))
    }

    func testRevokedRefreshCredentialClearsEntireSession() {
        var state = CodexOAuthSessionState()
        state.accept(makeTokens(refreshToken: "revoked-refresh"))

        state.failed(.refreshTokenInvalid)

        XCTAssertNil(state.accessToken)
        XCTAssertEqual(state.expiresAt, .distantPast)
        XCTAssertNil(state.pendingRefreshToken)
        XCTAssertTrue(state.requiresTokenRefresh(at: now))
    }

    func testDisconnectClearsEntireSession() {
        var state = CodexOAuthSessionState()
        state.accept(makeTokens(refreshToken: "pending-refresh"))

        state.clear()

        XCTAssertNil(state.accessToken)
        XCTAssertEqual(state.expiresAt, .distantPast)
        XCTAssertNil(state.pendingRefreshToken)
        XCTAssertTrue(state.requiresTokenRefresh(at: now))
    }

    func testRefreshWithoutRotationDoesNotRequirePersistence() {
        var state = CodexOAuthSessionState()
        state.accept(makeTokens(refreshToken: "stored-refresh"))
        state.didPersistRefreshToken()
        let refreshed = makeTokens(accessToken: "refreshed-access", expiresIn: 7_200)

        state.accept(refreshed)

        XCTAssertEqual(state.accessToken, refreshed.accessToken)
        XCTAssertEqual(state.expiresAt, refreshed.expiresAt)
        XCTAssertNil(state.pendingRefreshToken)
        XCTAssertFalse(state.requiresTokenRefresh(at: now))
    }

    func testRefreshWithoutRotationPreservesUnpersistedCredential() {
        var state = CodexOAuthSessionState()
        state.accept(makeTokens(refreshToken: "pending-refresh"))
        let refreshed = makeTokens(accessToken: "refreshed-access", expiresIn: 7_200)

        state.accept(refreshed)

        XCTAssertEqual(state.pendingRefreshToken, "pending-refresh")
        XCTAssertEqual(state.accessToken, refreshed.accessToken)
        XCTAssertEqual(state.expiresAt, refreshed.expiresAt)
    }

    func testNewRotationReplacesPendingCredentialWithLatest() {
        var state = CodexOAuthSessionState()
        state.accept(makeTokens(refreshToken: "older-refresh"))
        let refreshed = makeTokens(accessToken: "latest-access", refreshToken: "latest-refresh")

        state.accept(refreshed)

        XCTAssertEqual(state.pendingRefreshToken, "latest-refresh")
        XCTAssertEqual(state.accessToken, refreshed.accessToken)
        XCTAssertEqual(state.expiresAt, refreshed.expiresAt)
    }

    private func makeTokens(accessToken: String = "test-access", refreshToken: String? = nil,
                            expiresIn: TimeInterval = 3_600) -> CodexOAuthTokens {
        CodexOAuthTokens(accessToken: accessToken, refreshToken: refreshToken, idToken: nil,
                         expiresAt: now.addingTimeInterval(expiresIn))
    }
}
