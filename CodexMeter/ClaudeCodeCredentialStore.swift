import Foundation
import LocalAuthentication
import Security

/// Reads the OAuth credential Claude Code itself stores on this machine:
/// the macOS Keychain item named "Claude Code-credentials", with
/// ~/.claude/.credentials.json as the fallback for setups that keep the
/// payload on disk. The token is used in memory only and never copied into
/// CodexMeter's own storage. A direct Keychain read needs the user's consent
/// and so only runs for a manual refresh; the `security` tool read below
/// needs none.
@MainActor
final class ClaudeCodeCredentialStore {
    private let service = "Claude Code-credentials"
    private let fileURL: URL

    init(fileURL: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/.credentials.json")) {
        self.fileURL = fileURL
    }

    func readAccessToken(allowInteraction: Bool) throws -> String {
        // The interactive read goes last: it is the only one that can raise a
        // password prompt, so it only runs for a user-initiated refresh.
        if let token = readFromKeychain(allowInteraction: false)
            ?? readThroughSecurityTool()
            ?? (allowInteraction ? readFromKeychain(allowInteraction: true) : nil)
            ?? readFromFile() {
            return token
        }
        throw ProviderUsageErrorCode.localCredentialMissing
    }

    /// Claude Code rewrites the item with `security add-generic-password -U`,
    /// which resets its partition list to `apple-tool:` and drops the
    /// "Always Allow" grant of every other app, so a direct read asks for the
    /// Keychain password again after each token refresh. Apple's `security`
    /// tool, the one Claude Code itself reads through, stays inside that
    /// list and never prompts.
    private func readThroughSecurityTool() -> String? {
        // A locked Keychain would raise an unlock dialog even for this tool.
        guard isDefaultKeychainUnlocked() else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", service, "-w"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        // Bound the main-thread wait: terminating the tool closes its output
        // and releases the blocking read below.
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 3, execute: watchdog)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()
        guard process.terminationStatus == 0 else { return nil }
        return ClaudeCodeCredential.accessToken(fromSecurityToolOutput: data)
    }

    private func isDefaultKeychainUnlocked() -> Bool {
        var keychain: SecKeychain?
        guard SecKeychainCopyDefault(&keychain) == errSecSuccess, let keychain else { return false }
        var status: SecKeychainStatus = 0
        guard SecKeychainGetStatus(keychain, &status) == errSecSuccess else { return false }
        return status & SecKeychainStatus(kSecUnlockStateStatus) != 0
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
