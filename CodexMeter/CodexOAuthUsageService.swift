import AppKit
import Combine
import Foundation
import Security

/// Keeps the independently authorized refresh credential in an app-only Keychain item.
@MainActor
final class CodexOAuthUsageService: ObservableObject {
    @Published private(set) var deviceCode: CodexOAuthDeviceCode?
    @Published private(set) var isConnected = false
    @Published private(set) var isBusy = false
    @Published private(set) var isStale = false
    @Published private(set) var windows: [CodexUsageWindow] = []
    @Published private(set) var planType: String?
    @Published private(set) var errorMessage: String?
    @Published private(set) var lastUpdated: Date?

    private let client = CodexOAuthClient()
    private let service = "com.codexmeter.codex-oauth.v1"
    private let account = "refresh-token"
    private var accessToken: String?
    private var expiresAt: Date = .distantPast
    private var operation: Task<Void, Never>?
    private var timer: Timer?
    private var generation = UUID()
    private let enabled: Bool

    init(enabled: Bool = true) {
        self.enabled = enabled
        guard enabled else { return }
        do { isConnected = try readRefreshToken() != nil }
        catch { errorMessage = L10n.string("oauth.storage_error") }
    }

    func start() {
        guard enabled else { return }
        timer?.invalidate()
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        if isConnected { refresh() }
    }

    func setPopoverVisible(_ visible: Bool) {
        guard enabled, visible, isConnected else { return }
        refresh()
    }

    /// Stops background polling without discarding the stored credential.
    func suspend() {
        timer?.invalidate()
        timer = nil
    }

    func beginLogin() {
        guard enabled else { return }
        cancelOperation()
        deviceCode = nil
        isBusy = true
        errorMessage = nil
        let current = generation
        operation = Task {
            do {
                let code = try await client.startDeviceFlow()
                guard current == generation, !Task.isCancelled else { return }
                deviceCode = code
                // The code is typed by the human in the browser; copying it mirrors
                // the official device-flow UX and touches no credential material.
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(code.userCode, forType: .string)
                NSWorkspace.shared.open(code.verificationURL)
                while Date() < code.expiresAt {
                    try Task.checkCancellation()
                    try await Task.sleep(nanoseconds: UInt64(max(5, code.interval) * 1_000_000_000))
                    if let authorization = try await client.pollDeviceFlow(deviceAuthID: code.deviceAuthID, userCode: code.userCode) {
                        let tokens = try await client.exchangeCode(code: authorization.authorizationCode, verifier: authorization.codeVerifier)
                        guard current == generation, !Task.isCancelled else { return }
                        guard let refreshToken = tokens.refreshToken else { throw OAuthLocalError.missingCredential }
                        try saveRefreshToken(refreshToken)
                        accessToken = tokens.accessToken
                        expiresAt = tokens.expiresAt
                        isConnected = true
                        deviceCode = nil
                        isBusy = false
                        operation = nil
                        refresh()
                        return
                    }
                }
                throw OAuthLocalError.expired
            } catch is CancellationError {
                return
            } catch {
                guard current == generation else { return }
                deviceCode = nil
                isBusy = false
                errorMessage = localizedError(error)
            }
        }
    }

    func cancelLogin() {
        cancelOperation()
        deviceCode = nil
        isBusy = false
    }

    func disconnect() throws {
        try deleteRefreshToken()
        cancelOperation()
        accessToken = nil
        expiresAt = .distantPast
        isConnected = false
        isBusy = false
        deviceCode = nil
        windows = []
        planType = nil
        lastUpdated = nil
        isStale = false
        errorMessage = nil
    }

    func refresh() {
        guard enabled, isConnected, operation == nil else { return }
        isBusy = true
        let current = generation
        operation = Task {
            do {
                var token = accessToken
                if token == nil || expiresAt.timeIntervalSinceNow < 60 {
                    guard let stored = try readRefreshToken() else { throw OAuthLocalError.missingCredential }
                    let refreshed = try await client.refresh(refreshToken: stored)
                    guard current == generation, !Task.isCancelled else { return }
                    // Persist rotation before using the new access token. A failed write
                    // leaves the prior credential intact and never publishes the new one.
                    if let rotated = refreshed.refreshToken { try saveRefreshToken(rotated) }
                    token = refreshed.accessToken
                    accessToken = token
                    expiresAt = refreshed.expiresAt
                }
                guard let token else { throw OAuthLocalError.missingCredential }
                let quota = try await client.fetchQuota(accessToken: token, accountID: nil)
                guard current == generation, !Task.isCancelled else { return }
                // The decoder cannot localize; apply the same duration-based titles
                // the App Server parser uses so both sources look identical.
                windows = quota.windows.map { Self.titled($0) }
                planType = quota.planType
                lastUpdated = Date()
                isStale = false
                errorMessage = nil
            } catch is CancellationError {
                return
            } catch {
                guard current == generation else { return }
                if let error = error as? CodexOAuthError,
                   error == .refreshTokenInvalid || error == .authentication {
                    // The stored grant is no longer accepted; keep quota output empty
                    // and require an explicit new sign-in rather than endless retries.
                    try? deleteRefreshToken()
                    accessToken = nil
                    expiresAt = .distantPast
                    isConnected = false
                    windows = []
                    planType = nil
                    lastUpdated = nil
                    isStale = false
                    errorMessage = localizedError(error)
                } else {
                    isStale = !windows.isEmpty
                    errorMessage = localizedError(error)
                    accessToken = nil
                }
            }
            guard current == generation else { return }
            isBusy = false
            operation = nil
        }
    }

    private func cancelOperation() {
        generation = UUID()
        operation?.cancel()
        operation = nil
    }

    private enum OAuthLocalError: Error { case expired, missingCredential }

    /// Renames decoded windows with localized duration titles, mirroring the
    /// App Server parser so both quota sources present identically.
    private static func titled(_ window: CodexUsageWindow) -> CodexUsageWindow {
        let durationName = friendlyDuration(window.windowDurationMins)
        let name = window.name == "Codex"
            ? durationName
            : L10n.format("duration.bucket_format", window.name, durationName)
        return CodexUsageWindow(
            id: window.id,
            name: name,
            usedPercent: window.usedPercent,
            windowDurationMins: window.windowDurationMins,
            resetsAt: window.resetsAt
        )
    }

    private static func friendlyDuration(_ minutes: Int?) -> String {
        guard let minutes else { return L10n.string("duration.quota") }
        switch minutes {
        case 300:
            return L10n.string("duration.five_hours")
        case 10_080:
            return L10n.string("duration.weekly")
        case let value where value.isMultiple(of: 1_440):
            return L10n.format("duration.days_format", value / 1_440)
        case let value where value.isMultiple(of: 60):
            return L10n.format("duration.hours_format", value / 60)
        default:
            return L10n.format("duration.minutes_format", minutes)
        }
    }

    private func localizedError(_ error: Error) -> String {
        if case OAuthLocalError.expired = error { return L10n.string("oauth.expired") }
        if case OAuthLocalError.missingCredential = error { return L10n.string("oauth.login_required") }
        if let error = error as? CodexOAuthError {
            switch error {
            case .deviceCodeExpired: return L10n.string("oauth.expired")
            case .authentication, .refreshTokenInvalid: return L10n.string("oauth.login_required")
            default: return L10n.string("oauth.request_error")
            }
        }
        return L10n.string("oauth.request_error")
    }

    private var keychainQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    private func readRefreshToken() throws -> String? {
        var query = keychainQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let token = String(data: data, encoding: .utf8), !token.isEmpty else {
            throw OAuthLocalError.missingCredential
        }
        return token
    }

    private func saveRefreshToken(_ token: String) throws {
        guard !token.isEmpty else { throw OAuthLocalError.missingCredential }
        let data = Data(token.utf8)
        let status = SecItemUpdate(keychainQuery as CFDictionary,
                                   [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var query = keychainQuery
            query[kSecValueData as String] = data
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(query as CFDictionary, nil) == errSecSuccess else {
                throw OAuthLocalError.missingCredential
            }
        } else if status != errSecSuccess {
            throw OAuthLocalError.missingCredential
        }
    }

    private func deleteRefreshToken() throws {
        let status = SecItemDelete(keychainQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw OAuthLocalError.missingCredential
        }
    }
}
