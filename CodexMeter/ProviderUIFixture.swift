import Foundation

/// Explicit Debug fixtures avoid live credentials and account endpoints.
enum ProviderUIFixture {
    static var isEnabled: Bool {
        #if DEBUG
        CommandLine.arguments.contains("--provider-ui-fixture")
        #else
        false
        #endif
    }

    private static var usesExtendedScenario: Bool {
        #if DEBUG
        CommandLine.arguments.contains("--provider-ui-fixture-scenario=extended")
        #else
        false
        #endif
    }

    static func makeCoordinator() -> ProviderUsageCoordinator {
        #if DEBUG
        if isEnabled {
            let credentials = FixtureCredentials()
            let connections = FixtureConnections(extended: usesExtendedScenario)
            for connection in connections.values {
                credentials.values[connection.credentialReference] =
                    connection.kind == .zhipu
                    ? "eyJhbGciOiJIUzUxMiJ9.zm9sZS1wcmV2aWV3.sig"
                    : connection.name == L10n.string("providers.preview_long_name")
                        ? "preview-long-name-token"
                        : connection.name == L10n.string("providers.preview_unavailable")
                            ? "preview-error-token"
                            : "preview-only-not-an-api-key"
            }
            return ProviderUsageCoordinator(
                credentialStore: credentials, connectionStore: connections,
                transport: FixtureTransport(extended: usesExtendedScenario),
                automaticTimers: true
            )
        }
        #endif
        return ProviderUsageCoordinator()
    }
}

#if DEBUG
@MainActor
private final class FixtureCredentials: ProviderCredentialStoreProtocol {
    var values: [String: String] = [:]
    func read(reference: String, allowInteraction: Bool) throws -> String {
        guard let value = values[reference] else { throw ProviderUsageErrorCode.credentialMissing }
        return value
    }
    func write(_ key: String, reference: String) throws { values[reference] = key }
    func delete(reference: String) throws { values.removeValue(forKey: reference) }
}

@MainActor
private final class FixtureConnections: ProviderConnectionStoreProtocol {
    var values: [ProviderConnection]
    var selected: UUID?

    init(extended: Bool) {
        let base = [
            ProviderConnection(id: UUID(), kind: .deepSeek, region: .global,
                               name: L10n.string("providers.preview_balance"), enabled: true,
                               credentialReference: UUID().uuidString, identityEpoch: UUID(), selectedBucketID: nil),
            ProviderConnection(id: UUID(), kind: .miniMax, region: .global,
                               name: L10n.string("providers.preview_quota"), enabled: true,
                               credentialReference: UUID().uuidString, identityEpoch: UUID(), selectedBucketID: nil),
            ProviderConnection(id: UUID(), kind: .zhipu, region: .china,
                               name: L10n.string("providers.preview_zhipu"), enabled: true,
                               credentialReference: UUID().uuidString, identityEpoch: UUID(), selectedBucketID: nil)
        ]
        if extended {
            values = base + [
                ProviderConnection(id: UUID(), kind: .deepSeek, region: .global,
                                   name: L10n.string("providers.preview_long_name"), enabled: true,
                                   credentialReference: UUID().uuidString, identityEpoch: UUID(), selectedBucketID: nil),
                ProviderConnection(id: UUID(), kind: .miniMax, region: .china,
                                   name: L10n.string("providers.preview_unavailable"), enabled: true,
                                   credentialReference: UUID().uuidString, identityEpoch: UUID(), selectedBucketID: nil),
                ProviderConnection(id: UUID(), kind: .deepSeek, region: .global,
                                   name: L10n.string("providers.preview_disabled"), enabled: false,
                                   credentialReference: UUID().uuidString, identityEpoch: UUID(), selectedBucketID: nil)
            ]
        } else {
            values = base
        }
        selected = values.first?.id
    }

    func loadConnections() throws -> [ProviderConnection] { values }
    func saveConnections(_ connections: [ProviderConnection]) throws { values = connections }
    func loadSelectedConnectionID() -> UUID? { selected }
    func saveSelectedConnectionID(_ id: UUID?) throws { selected = id }
}

private final class FixtureTransport: ProviderUsageTransport, @unchecked Sendable {
    private let extended: Bool
    private let lock = NSLock()
    private var errorConnectionFetches = 0

    init(extended: Bool) {
        self.extended = extended
    }

    func send(_ request: URLRequest) async throws -> ProviderHTTPResponse {
        guard let url = request.url else { throw ProviderUsageFailure(code: .invalidConfiguration) }
        // The extended scenario exercises per-source error and stale handling:
        // the marked connection answers once, then keeps timing out so the row
        // shows a localized error while the old snapshot is retained as stale.
        if extended, url.host == "api.minimax.cn",
           request.value(forHTTPHeaderField: "Authorization") == "Bearer preview-error-token" {
            lock.lock()
            errorConnectionFetches += 1
            let fetchCount = errorConnectionFetches
            lock.unlock()
            if fetchCount > 1 { throw ProviderUsageFailure(code: .timeout) }
        }
        let body: [String: Any]
        switch url.host {
        case "api.deepseek.com":
            // The second DeepSeek connection carries a distinguishing token so
            // its balance answer differs from the first connection's.
            if extended, request.value(forHTTPHeaderField: "Authorization") == "Bearer preview-long-name-token" {
                body = ["is_available": true, "balance_infos": [
                    ["currency": "CNY", "total_balance": "1024.50", "granted_balance": "24.50", "topped_up_balance": "1000.00"],
                    ["currency": "EUR", "total_balance": "87.123456", "granted_balance": "7.123456", "topped_up_balance": "80.00"]
                ]]
                return ProviderHTTPResponse(data: try JSONSerialization.data(withJSONObject: body),
                                            statusCode: 200, headers: [:], url: url)
            }
            body = ["is_available": true, "balance_infos": [
                ["currency": "CNY", "total_balance": "12.3456", "granted_balance": "2.00", "topped_up_balance": "10.3456"],
                ["currency": "USD", "total_balance": "0.25", "granted_balance": "0", "topped_up_balance": "0.25"]
            ]]
        case "api.minimax.io":
            let now = Date().timeIntervalSince1970
            body = ["base_resp": ["status_code": 0], "model_remains": [[
                "model_name": "general",
                "current_interval_remaining_percent": 73.4,
                "current_interval_total_count": 1000,
                "current_interval_usage_count": 734,
                "current_interval_status": 1,
                "current_weekly_remaining_percent": 42.0,
                "current_weekly_total_count": 1000,
                "current_weekly_usage_count": 420,
                "current_weekly_status": 1,
                "weekly_boost_permille": 1500,
                "start_time": Int64((now - 10800) * 1000),
                "end_time": Int64((now + 7200) * 1000),
                "weekly_start_time": Int64((now - 302400) * 1000),
                "weekly_end_time": Int64((now + 302400) * 1000)
            ]]]
        case "api.minimax.cn":
            let now = Date().timeIntervalSince1970
            body = ["base_resp": ["status_code": 0], "model_remains": [[
                "model_name": "general",
                "current_interval_total_count": 0,
                "current_interval_usage_count": 0,
                "current_interval_status": 3,
                "current_weekly_total_count": 0,
                "current_weekly_usage_count": 0,
                "current_weekly_status": 3
            ]]]
        case "bigmodel.cn":
            let now = Date().timeIntervalSince1970
            body = ["code": 200, "msg": "操作成功", "data": [
                "level": "pro",
                "limits": [
                    ["type": "CREDIT_LIMIT", "unit": 3, "number": 5,
                     "usage": 15000, "currentValue": 604, "remaining": 14396,
                     "percentage": 4, "nextResetTime": Int64((now + 7200) * 1000)],
                    ["type": "CREDIT_LIMIT", "unit": 6, "number": 1,
                     "usage": 66000, "currentValue": 10716, "remaining": 55284,
                     "percentage": 16, "nextResetTime": Int64((now + 302400) * 1000)]
                ]
            ]]
        default:
            throw ProviderUsageFailure(code: .invalidConfiguration)
        }
        return ProviderHTTPResponse(data: try JSONSerialization.data(withJSONObject: body),
                                    statusCode: 200, headers: [:], url: url)
    }
}
#endif
