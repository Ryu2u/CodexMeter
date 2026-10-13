import AppKit
import Combine
import Foundation

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
    private let credentialStore: any CodexOAuthCredentialStoreProtocol
    private var sessionState = CodexOAuthSessionState()
    private var operation: Task<Void, Never>?
    private var timer: Timer?
    private var generation = UUID()
    private var isCredentialAccessBlocked = false
    private let enabled: Bool

    init(enabled: Bool = true, credentialStore: (any CodexOAuthCredentialStoreProtocol)? = nil) {
        self.enabled = enabled
        self.credentialStore = credentialStore ?? CodexOAuthCredentialStore()
        guard enabled else { return }
        do { isConnected = try readRefreshToken() != nil }
        catch {
            isCredentialAccessBlocked = true
            errorMessage = L10n.string("oauth.storage_error")
        }
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
        guard enabled, operation == nil else { return }
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
                        try saveRefreshToken(refreshToken, allowInteraction: true)
                        sessionState.accept(tokens)
                        sessionState.didPersistRefreshToken()
                        // A successful new sign-in replaces the prior account's presentation.
                        windows = []
                        planType = nil
                        lastUpdated = nil
                        isStale = false
                        isConnected = true
                        isCredentialAccessBlocked = false
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
        try deleteRefreshToken(allowInteraction: true)
        cancelOperation()
        sessionState.clear()
        isConnected = false
        isBusy = false
        deviceCode = nil
        windows = []
        planType = nil
        lastUpdated = nil
        isStale = false
        errorMessage = nil
    }

    func refresh(reauthorizing: Bool = false) {
        guard enabled, operation == nil else { return }
        guard !isCredentialAccessBlocked || reauthorizing else { return }
        if !isConnected {
            // A denied prompt or a rebuild's new ad-hoc signature can make the
            // stored credential unreadable. Only an explicit user action may
            // retry the read, so the system prompt reappears without a full
            // sign-in; automatic timers must never loop the password dialog.
            guard reauthorizing else { return }
            do {
                guard try readRefreshToken(allowInteraction: true) != nil else {
                    errorMessage = L10n.string("oauth.login_required")
                    return
                }
                isConnected = true
                errorMessage = nil
            } catch {
                isCredentialAccessBlocked = true
                errorMessage = L10n.string("oauth.storage_error")
                return
            }
        }
        isBusy = true
        let current = generation
        operation = Task {
            do {
                // A server-side rotation may already have invalidated the old
                // credential. Retry saving the new one before any network work.
                try persistPendingRefreshToken(allowInteraction: reauthorizing)
                if sessionState.requiresTokenRefresh(at: Date()) {
                    guard let stored = try readRefreshToken(allowInteraction: reauthorizing) else {
                        throw OAuthLocalError.missingCredential
                    }
                    let refreshed = try await client.refresh(refreshToken: stored)
                    guard current == generation, !Task.isCancelled else { return }
                    sessionState.accept(refreshed)
                    try persistPendingRefreshToken(allowInteraction: reauthorizing)
                }
                guard let token = sessionState.accessToken else { throw OAuthLocalError.missingCredential }
                let quota = try await client.fetchQuota(accessToken: token, accountID: nil)
                guard current == generation, !Task.isCancelled else { return }
                // Localize presentation in the app; the protocol decoder stays UI-independent.
                windows = quota.windows.map { Self.titled($0) }
                planType = quota.planType
                lastUpdated = Date()
                isCredentialAccessBlocked = false
                isStale = false
                errorMessage = nil
            } catch is CancellationError {
                return
            } catch {
                guard current == generation else { return }
                if let error = error as? CodexOAuthError, error == .refreshTokenInvalid {
                    // The server declared this grant dead. Drop the credential
                    // so the UI returns to the sign-in state.
                    try? deleteRefreshToken()
                    sessionState.failed(error)
                    isConnected = false
                    windows = []
                    planType = nil
                    lastUpdated = nil
                    isStale = false
                    errorMessage = localizedError(error)
                } else {
                    // Environment failures (proxy exit blocked, network, rate
                    // limit) keep the stored grant retryable: switching the
                    // proxy off must recover without a new sign-in.
                    isStale = !windows.isEmpty
                    if error is CodexOAuthCredentialError {
                        isCredentialAccessBlocked = true
                    }
                    if let oauthError = error as? CodexOAuthError {
                        sessionState.failed(oauthError)
                    }
                    errorMessage = localizedError(error)
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

    /// Presents the server's returned duration without guessing account-specific windows.
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
        if error is CodexOAuthCredentialError { return L10n.string("oauth.storage_error") }
        if case OAuthLocalError.expired = error { return L10n.string("oauth.expired") }
        if case OAuthLocalError.missingCredential = error { return L10n.string("oauth.login_required") }
        if let error = error as? CodexOAuthError {
            switch error {
            case .deviceCodeExpired: return L10n.string("oauth.expired")
            // The grant stays stored on transient rejections, so the message
            // asks for a retry rather than a new sign-in.
            case .refreshTokenInvalid: return L10n.string("oauth.login_required")
            default: return L10n.string("oauth.request_error")
            }
        }
        return L10n.string("oauth.request_error")
    }

    private func persistPendingRefreshToken(allowInteraction: Bool) throws {
        guard let pending = sessionState.pendingRefreshToken else { return }
        try saveRefreshToken(pending, allowInteraction: allowInteraction)
        sessionState.didPersistRefreshToken()
    }

    private func readRefreshToken(allowInteraction: Bool = false) throws -> String? {
        try credentialStore.read(allowInteraction: allowInteraction)
    }

    private func saveRefreshToken(_ token: String, allowInteraction: Bool) throws {
        try credentialStore.write(token, allowInteraction: allowInteraction)
    }

    private func deleteRefreshToken(allowInteraction: Bool = false) throws {
        try credentialStore.delete(allowInteraction: allowInteraction)
    }
}
