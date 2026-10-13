import Foundation

nonisolated struct CodexOAuthSessionState {
    private(set) var accessToken: String?
    private(set) var expiresAt: Date = .distantPast
    private(set) var pendingRefreshToken: String?

    func requiresTokenRefresh(at date: Date) -> Bool {
        accessToken == nil || expiresAt.timeIntervalSince(date) < 60
    }

    mutating func accept(_ tokens: CodexOAuthTokens) {
        accessToken = tokens.accessToken
        expiresAt = tokens.expiresAt
        // Keep the latest rotated credential until its persistence succeeds.
        if let refreshToken = tokens.refreshToken {
            pendingRefreshToken = refreshToken
        }
    }

    mutating func didPersistRefreshToken() {
        pendingRefreshToken = nil
    }

    mutating func failed(_ error: CodexOAuthError) {
        switch error {
        case .accessTokenRejected:
            accessToken = nil
            expiresAt = .distantPast
        case .refreshTokenInvalid:
            clear()
        case .authentication, .network, .timeout, .rateLimited, .invalidResponse, .responseTooLarge, .deviceCodeExpired:
            break
        }
    }

    mutating func clear() {
        accessToken = nil
        expiresAt = .distantPast
        pendingRefreshToken = nil
    }
}
