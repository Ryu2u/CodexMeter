import Foundation
import LocalAuthentication
import Security

/// Reads the OAuth credential Claude Code itself stores on this machine:
/// the macOS Keychain item named "Claude Code-credentials", with
/// ~/.claude/.credentials.json as the fallback for setups that keep the
/// payload on disk. The token is used in memory only and never copied into
/// CodexMeter's own storage; the first Keychain read requires the user's
/// consent, so it happens through a manual refresh exactly like the app's
/// own credential store.
@MainActor
final class ClaudeCodeCredentialStore {
    private let service = "Claude Code-credentials"
    private let fileURL: URL

    init(fileURL: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/.credentials.json")) {
        self.fileURL = fileURL
    }

    func readAccessToken(allowInteraction: Bool) throws -> String {
        if let token = readFromKeychain(allowInteraction: allowInteraction) ?? readFromFile() {
            return token
        }
        throw ProviderUsageErrorCode.localCredentialMissing
    }

    private func readFromKeychain(allowInteraction: Bool) -> String? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        let context = LAContext()
        context.interactionNotAllowed = !allowInteraction
        query[kSecUseAuthenticationContext as String] = context
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return ClaudeCodeCredential.accessToken(from: data)
    }

    private func readFromFile() -> String? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return ClaudeCodeCredential.accessToken(from: data)
    }
}
