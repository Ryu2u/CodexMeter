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

    func testSecurityToolOutputReadsThePayloadBehindItsTrailingNewline() {
        let output = #"{"claudeAiOauth":{"accessToken":"sk-ant-oat01-ToolOutput0k"}}"# + "\n"
        XCTAssertEqual(
            ClaudeCodeCredential.accessToken(fromSecurityToolOutput: data(output)),
            "sk-ant-oat01-ToolOutput0k"
        )
    }

    func testSecurityToolOutputDecodesAHexEncodedPayload() {
        // The tool prints data it cannot show as plain text as a hex string.
        let json = #"{"claudeAiOauth":{"accessToken":"sk-ant-oat01-HexOutput0k"}}"#
        let hex = json.utf8.map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(
            ClaudeCodeCredential.accessToken(fromSecurityToolOutput: data(hex + "\n")),
            "sk-ant-oat01-HexOutput0k"
        )
    }

    func testSecurityToolOutputRejectsEmptyAndUnusableOutput() {
        XCTAssertNil(ClaudeCodeCredential.accessToken(fromSecurityToolOutput: Data()))
        XCTAssertNil(ClaudeCodeCredential.accessToken(fromSecurityToolOutput: data("\n")))
        XCTAssertNil(ClaudeCodeCredential.accessToken(fromSecurityToolOutput: data("not a payload\n")))
        // A hex string that decodes to something other than a token payload.
        XCTAssertNil(ClaudeCodeCredential.accessToken(fromSecurityToolOutput: data("deadbeef\n")))
    }

    func testAccessTokenPredicateOnlyAcceptsOAuthAccessTokens() {
        XCTAssertTrue(ClaudeCodeCredential.isAccessToken("sk-ant-oat01-abcdefghijklmnop"))
        XCTAssertFalse(ClaudeCodeCredential.isAccessToken("sk-ant-ort01-abcdefghijklmnop"))
        XCTAssertFalse(ClaudeCodeCredential.isAccessToken("sk-ant-api03-abcdefghijklmnop"))
        XCTAssertFalse(ClaudeCodeCredential.isAccessToken("sk-ant-oat"))
    }
}
