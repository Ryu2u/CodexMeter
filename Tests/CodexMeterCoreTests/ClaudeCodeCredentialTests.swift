import XCTest
@testable import CodexMeterCore

final class ClaudeCodeCredentialTests: XCTestCase {
    private func data(_ json: String) -> Data { Data(json.utf8) }

    func testExtractsAccessTokenFromTheClaudeCodePayload() {
        let payload = """
        {"claudeAiOauth":{"accessToken":"sk-ant-oat01-AbCdEf1234567890",
         "refreshToken":"sk-ant-ort01-ZzZzZz9876543210",
         "expiresAt":"2026-12-01T00:00:00Z"}}
        """
        XCTAssertEqual(
            ClaudeCodeCredential.accessToken(from: data(payload)),
            "sk-ant-oat01-AbCdEf1234567890"
        )
    }

    func testNeverReturnsARefreshToken() {
        let payload = """
        {"claudeAiOauth":{"refreshToken":"sk-ant-ort01-ZzZzZz9876543210"}}
        """
        XCTAssertNil(ClaudeCodeCredential.accessToken(from: data(payload)))
    }

    func testToleratesRenamedFieldsAndUnknownContainers() {
        XCTAssertEqual(
            ClaudeCodeCredential.accessToken(from: data(
                #"{"claudeAiOauth":{"token":"sk-ant-oat01-RenamedField0k"}}"#)),
            "sk-ant-oat01-RenamedField0k"
        )
        XCTAssertEqual(
            ClaudeCodeCredential.accessToken(from: data(
                #"{"futureShape":{"oauthToken":"sk-ant-oat01-TopLevel0k"}}"#)),
            "sk-ant-oat01-TopLevel0k"
        )
    }

    func testRejectsMalformedPayloadsAndNonTokenStrings() {
        XCTAssertNil(ClaudeCodeCredential.accessToken(from: data("not json")))
        XCTAssertNil(ClaudeCodeCredential.accessToken(from: data(#"{"claudeAiOauth":{}}"#)))
        XCTAssertNil(ClaudeCodeCredential.accessToken(from: data(
            #"{"claudeAiOauth":{"accessToken":"short"}}"#)))
    }

    func testAccessTokenPredicateOnlyAcceptsOAuthAccessTokens() {
        XCTAssertTrue(ClaudeCodeCredential.isAccessToken("sk-ant-oat01-abcdefghijklmnop"))
        XCTAssertFalse(ClaudeCodeCredential.isAccessToken("sk-ant-ort01-abcdefghijklmnop"))
        XCTAssertFalse(ClaudeCodeCredential.isAccessToken("sk-ant-api03-abcdefghijklmnop"))
        XCTAssertFalse(ClaudeCodeCredential.isAccessToken("sk-ant-oat"))
    }
}
