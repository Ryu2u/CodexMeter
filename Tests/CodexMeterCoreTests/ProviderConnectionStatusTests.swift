import XCTest
@testable import CodexMeterCore

final class ProviderConnectionStatusTests: XCTestCase {
    func testClaudeAuthenticationFailureNamesTheLocalClaudeCodeToken() {
        XCTAssertEqual(
            ProviderConnectionStatus.authRequired.failureMessageKey(for: .claude),
            "providers.error.claudeTokenExpired")
    }

    func testKeyBasedProvidersKeepTheGenericAuthenticationMessage() {
        for kind in ProviderKind.allCases where kind != .claude {
            XCTAssertEqual(
                ProviderConnectionStatus.authRequired.failureMessageKey(for: kind),
                "providers.error.authentication", "\(kind)")
        }
    }

    func testOrdinaryFailuresUseTheirOwnCodeForEveryProvider() {
        for kind in ProviderKind.allCases {
            XCTAssertEqual(
                ProviderConnectionStatus.stale(.network).failureMessageKey(for: kind),
                "providers.error.network")
            XCTAssertEqual(
                ProviderConnectionStatus.unavailable(.localCredentialMissing).failureMessageKey(for: kind),
                "providers.error.localCredentialMissing")
        }
    }

    func testStatesWithoutAFailureMessageReturnNil() {
        let states: [ProviderConnectionStatus] = [.loading, .ready, .rateLimited(until: Date())]
        for kind in ProviderKind.allCases {
            for state in states {
                XCTAssertNil(state.failureMessageKey(for: kind), "\(state)")
            }
        }
    }
}
