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

    /// Reads the payload printed by `security find-generic-password -w`: the
    /// stored bytes followed by a newline, or a hex string when the tool
    /// cannot show them as plain text.
    static func accessToken(fromSecurityToolOutput output: Data) -> String? {
        guard let text = String(data: output, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        if let token = accessToken(from: Data(text.utf8)) { return token }
        guard let decoded = hexDecoded(text) else { return nil }
        return accessToken(from: decoded)
    }

    private static func hexDecoded(_ text: String) -> Data? {
        guard text.count.isMultiple(of: 2), !text.isEmpty else { return nil }
        var bytes = Data(capacity: text.count / 2)
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(index, offsetBy: 2)
            guard let byte = UInt8(text[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return bytes
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
