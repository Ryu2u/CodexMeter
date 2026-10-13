import Foundation
import CoreFoundation

struct CodexOAuthDeviceCode: Sendable {
    let deviceAuthID: String
    let userCode: String
    let verificationURL: URL
    let expiresAt: Date
    let interval: TimeInterval
}

struct CodexOAuthAuthorization: Sendable {
    let authorizationCode: String
    let codeVerifier: String
}

struct CodexOAuthTokens: Sendable {
    let accessToken: String
    let refreshToken: String?
    let idToken: String?
    let expiresAt: Date
}

struct CodexOAuthQuota: Sendable {
    let windows: [CodexUsageWindow]
    let planType: String?
}

/// These errors contain no remote message, URL, token, or response body.
enum CodexOAuthError: Error, Equatable, Sendable {
    case network, timeout, authentication, deviceCodeExpired
    case refreshTokenInvalid, rateLimited, invalidResponse, responseTooLarge
}

struct CodexOAuthHTTPResponse: Sendable {
    let status: Int
    let data: Data
    let url: URL
}

protocol CodexOAuthTransport: Sendable {
    func send(_ request: URLRequest) async throws -> CodexOAuthHTTPResponse
}

private final class CodexOAuthNoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

actor CodexOAuthURLSessionTransport: CodexOAuthTransport {
    private let session: URLSession
    private let redirectPolicy: CodexOAuthNoRedirects

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 20
        let policy = CodexOAuthNoRedirects()
        redirectPolicy = policy
        session = URLSession(configuration: configuration, delegate: policy, delegateQueue: nil)
    }

    func send(_ request: URLRequest) async throws -> CodexOAuthHTTPResponse {
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        guard let response = response as? HTTPURLResponse, let url = response.url else {
            throw CodexOAuthError.invalidResponse
        }
        guard response.expectedContentLength <= Int64(CodexOAuthClient.maximumResponseBytes) else {
            throw CodexOAuthError.responseTooLarge
        }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < CodexOAuthClient.maximumResponseBytes else {
                throw CodexOAuthError.responseTooLarge
            }
            data.append(byte)
        }
        return CodexOAuthHTTPResponse(status: response.statusCode, data: data, url: url)
    }

    deinit { session.invalidateAndCancel() }
}

/// Protocol only; the caller owns token lifetime, secure storage, and poll scheduling.
final class CodexOAuthClient: Sendable {
    static let maximumResponseBytes = 512 * 1_024
    static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    private static let authOrigin = "https://auth.openai.com"
    private static let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
    private static let redirectURI = "https://auth.openai.com/deviceauth/callback"
    private let transport: any CodexOAuthTransport
    private let now: @Sendable () -> Date

    init(transport: any CodexOAuthTransport = CodexOAuthURLSessionTransport(),
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.transport = transport
        self.now = now
    }

    func startDeviceFlow() async throws -> CodexOAuthDeviceCode {
        let url = URL(string: Self.authOrigin + "/api/accounts/deviceauth/usercode")!
        let body = try JSONSerialization.data(withJSONObject: ["client_id": Self.clientID])
        let response = try await send(url: url, method: "POST", body: body, contentType: "application/json")
        try validate(response)
        let object = try Self.object(response.data)
        guard let id = Self.nonempty(object["device_auth_id"]),
              let code = Self.nonempty(object["user_code"]) else { throw CodexOAuthError.invalidResponse }
        let interval = min(3_600, max(1, Self.positiveSeconds(object["interval"]) ?? 5) + 3)
        let lifetime = min(86_400, Self.positiveSeconds(object["expires_in"]) ?? 900)
        return CodexOAuthDeviceCode(deviceAuthID: id, userCode: code,
            verificationURL: URL(string: Self.authOrigin + "/codex/device")!,
            expiresAt: now().addingTimeInterval(lifetime), interval: interval)
    }

    /// A pending grant returns nil; the caller schedules another poll after deviceCode.interval.
    func pollDeviceFlow(deviceAuthID: String, userCode: String) async throws -> CodexOAuthAuthorization? {
        guard Self.validValue(deviceAuthID), Self.validValue(userCode) else { throw CodexOAuthError.invalidResponse }
        let url = URL(string: Self.authOrigin + "/api/accounts/deviceauth/token")!
        let body = try JSONSerialization.data(withJSONObject: ["device_auth_id": deviceAuthID, "user_code": userCode])
        let response = try await send(url: url, method: "POST", body: body, contentType: "application/json")
        switch response.status {
        case 403, 404: return nil
        case 410: throw CodexOAuthError.deviceCodeExpired
        default: try validate(response)
        }
        let object = try Self.object(response.data)
        guard let code = Self.nonempty(object["authorization_code"]),
              let verifier = Self.nonempty(object["code_verifier"]) else { throw CodexOAuthError.invalidResponse }
        return CodexOAuthAuthorization(authorizationCode: code, codeVerifier: verifier)
    }

    func exchangeCode(code: String, verifier: String) async throws -> CodexOAuthTokens {
        guard Self.validValue(code), Self.validValue(verifier) else { throw CodexOAuthError.invalidResponse }
        return try await tokenRequest([
            "grant_type": "authorization_code", "code": code, "redirect_uri": Self.redirectURI,
            "client_id": Self.clientID, "code_verifier": verifier
        ], isRefresh: false)
    }

    func refresh(refreshToken: String) async throws -> CodexOAuthTokens {
        guard Self.validValue(refreshToken) else { throw CodexOAuthError.invalidResponse }
        return try await tokenRequest([
            "grant_type": "refresh_token", "refresh_token": refreshToken,
            "client_id": Self.clientID, "scope": "openid profile email"
        ], isRefresh: true)
    }

    func fetchQuota(accessToken: String, accountID: String?) async throws -> CodexOAuthQuota {
        guard Self.validValue(accessToken), accountID.map(Self.validValue) ?? true else {
            throw CodexOAuthError.invalidResponse
        }
        var headers = ["Authorization": "Bearer \(accessToken)"]
        if let accountID { headers["ChatGPT-Account-Id"] = accountID }
        let response = try await send(url: Self.usageURL, method: "GET", headers: headers)
        try validate(response)
        return try Self.decodeQuota(response.data)
    }

    private func tokenRequest(_ parameters: [String: String], isRefresh: Bool) async throws -> CodexOAuthTokens {
        let url = URL(string: Self.authOrigin + "/oauth/token")!
        let body = parameters.sorted { $0.key < $1.key }.map { key, value in
            "\(Self.formEscape(key))=\(Self.formEscape(value))"
        }.joined(separator: "&").data(using: .utf8)!
        let response = try await send(url: url, method: "POST", body: body,
                                      contentType: "application/x-www-form-urlencoded")
        if isRefresh {
            // Only a body that declares the grant dead proves revocation. A
            // bare 401/403 (proxy exit blocked, WAF page) is an environment
            // failure and must keep the stored credential retryable.
            if Self.isInvalidRefresh(response.data) || Self.isInvalidGrant(response.data) {
                throw CodexOAuthError.refreshTokenInvalid
            }
            if response.status == 401 || response.status == 403 {
                throw CodexOAuthError.authentication
            }
        }
        try validate(response)
        let object = try Self.object(response.data)
        guard let access = Self.nonempty(object["access_token"]) else { throw CodexOAuthError.invalidResponse }
        let lifetime = min(86_400, Self.positiveSeconds(object["expires_in"]) ?? 3_600)
        return CodexOAuthTokens(accessToken: access, refreshToken: Self.nonempty(object["refresh_token"]),
                                idToken: Self.nonempty(object["id_token"]), expiresAt: now().addingTimeInterval(lifetime))
    }

    private func send(url: URL, method: String, body: Data? = nil,
                      contentType: String? = nil, headers: [String: String] = [:]) async throws -> CodexOAuthHTTPResponse {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("CodexMeter", forHTTPHeaderField: "User-Agent")
        if let contentType { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        do {
            let response = try await transport.send(request)
            try Task.checkCancellation()
            guard response.data.count <= Self.maximumResponseBytes else { throw CodexOAuthError.responseTooLarge }
            guard response.url == url, !(300..<400).contains(response.status) else {
                throw CodexOAuthError.invalidResponse
            }
            return response
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as CodexOAuthError {
            throw error
        } catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            throw error.code == .timedOut ? CodexOAuthError.timeout : CodexOAuthError.network
        } catch {
            throw CodexOAuthError.network
        }
    }

    private func validate(_ response: CodexOAuthHTTPResponse) throws {
        switch response.status {
        case 200..<300: return
        case 401, 403: throw CodexOAuthError.authentication
        case 429: throw CodexOAuthError.rateLimited
        case 500..<600: throw CodexOAuthError.network
        default: throw CodexOAuthError.invalidResponse
        }
    }

    private static func object(_ data: Data) throws -> [String: Any] {
        guard let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CodexOAuthError.invalidResponse
        }
        return result
    }

    private static func nonempty(_ value: Any?) -> String? {
        guard let string = value as? String, !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return string
    }

    private static func validValue(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 16_384 && !value.unicodeScalars.contains {
            CharacterSet.controlCharacters.contains($0)
        }
    }

    private static func positiveSeconds(_ value: Any?) -> TimeInterval? {
        let number: Double?
        if let text = value as? String { number = Double(text) }
        else if let raw = value as? NSNumber, CFGetTypeID(raw) != CFBooleanGetTypeID() { number = raw.doubleValue }
        else { number = nil }
        guard let number, number.isFinite, number > 0 else { return nil }
        return number
    }

    private static func formEscape(_ value: String) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed)!
    }

    private static func isInvalidRefresh(_ data: Data) -> Bool {
        guard let object = try? object(data) else { return false }
        let error = object["error"]
        let code = (error as? [String: Any])?["code"] as? String
            ?? error as? String ?? object["code"] as? String
        return ["refresh_token_expired", "refresh_token_reused", "refresh_token_invalidated"]
            .contains(code?.lowercased() ?? "")
    }

    /// RFC 6749 §5.2 reports an expired or revoked grant as `invalid_grant`,
    /// either as the plain error string or nested under a code field.
    private static func isInvalidGrant(_ data: Data) -> Bool {
        guard let object = try? object(data) else { return false }
        if let error = object["error"] as? String {
            return error.lowercased() == "invalid_grant"
        }
        let code = (object["error"] as? [String: Any])?["code"] as? String
        return code?.lowercased() == "invalid_grant"
    }

    static func decodeQuota(_ data: Data) throws -> CodexOAuthQuota {
        guard data.count <= maximumResponseBytes else { throw CodexOAuthError.responseTooLarge }
        let object = try object(data)
        guard let rateLimit = object["rate_limit"] as? [String: Any] else { throw CodexOAuthError.invalidResponse }
        var windows: [CodexUsageWindow] = []
        for (key, id) in [("primary_window", "codex:primary"), ("secondary_window", "codex:secondary")] {
            if let raw = rateLimit[key] as? [String: Any] {
                windows.append(try decodeWindow(raw, id: id, name: "Codex"))
            }
        }
        if let additional = object["additional_rate_limits"] as? [[String: Any]] {
            guard additional.count <= 32 else { throw CodexOAuthError.invalidResponse }
            for (index, item) in additional.enumerated() {
                let name = nonempty(item["limit_name"]) ?? "Additional limit"
                guard name.count <= 100, let limit = item["rate_limit"] as? [String: Any] else { continue }
                for (slot, key) in ["primary_window", "secondary_window"].enumerated() {
                    if let raw = limit[key] as? [String: Any] {
                        windows.append(try decodeWindow(raw, id: "additional:\(index):\(slot)", name: name))
                    }
                }
            }
        }
        guard !windows.isEmpty else { throw CodexOAuthError.invalidResponse }
        windows.sort { ($0.windowDurationMins ?? Int.max, $0.id) < ($1.windowDurationMins ?? Int.max, $1.id) }
        let plan = nonempty(object["plan_type"])
        return CodexOAuthQuota(windows: windows, planType: (plan?.count ?? 0) <= 100 ? plan : nil)
    }

    private static func decodeWindow(_ object: [String: Any], id: String, name: String) throws -> CodexUsageWindow {
        guard let percent = positiveNumber(object["used_percent"]), (0...100).contains(percent) else {
            throw CodexOAuthError.invalidResponse
        }
        let duration: Int?
        if let seconds = positiveNumber(object["limit_window_seconds"]), seconds > 0, seconds <= 365 * 86_400 {
            duration = Int(ceil(seconds / 60))
        } else { duration = nil }
        let reset: Date?
        if let timestamp = positiveNumber(object["reset_at"]), timestamp <= 253_402_300_799 {
            reset = Date(timeIntervalSince1970: timestamp)
        } else { reset = nil }
        return CodexUsageWindow(id: id, name: name, usedPercent: Int(percent.rounded()),
                                windowDurationMins: duration, resetsAt: reset)
    }

    private static func positiveNumber(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue >= 0 else { return nil }
        return number.doubleValue
    }
}
