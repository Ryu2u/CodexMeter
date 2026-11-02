import Foundation

/// Extracts the Claude Code OAuth access token from the credential payload
/// Claude Code itself stores on this machine (the macOS Keychain item
/// "Claude Code-credentials" or ~/.claude/.credentials.json). The shape is
/// undocumented, so parsing stays defensive: CodexMeter only ever reads the
/// payload and never writes or persists it.
nonisolated enum ClaudeCodeCredential {
    /// Access tokens carry the `sk-ant-oat` prefix; refresh tokens use
    /// `sk-ant-ort` and must never be sent as a bearer credential.
    static func isAccessToken(_ value: String) -> Bool {
        value.hasPrefix("sk-ant-oat") && (20...8_192).contains(value.utf8.count)
    }

    /// Returns the access token embedded in a Claude Code credentials JSON
    /// body, or nil when the payload carries no usable access token.
    static func accessToken(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data),
              let body = json as? [String: Any] else { return nil }
        if let oauth = body["claudeAiOauth"] as? [String: Any] {
            if let token = oauth["accessToken"] as? String, isAccessToken(token) {
                return token
            }
            // Tolerate field renames inside the OAuth object before falling
            // back to a whole-payload scan.
            for value in oauth.values {
                if let token = value as? String, isAccessToken(token) { return token }
            }
        }
        // Last resort for unknown container shapes: any access-token-looking
        // string in the top level or one nesting level below it.
        for value in body.values {
            if let token = value as? String, isAccessToken(token) { return token }
        }
        for case let nested as [String: Any] in body.values {
            for value in nested.values {
                if let token = value as? String, isAccessToken(token) { return token }
            }
        }
        return nil
    }
}
