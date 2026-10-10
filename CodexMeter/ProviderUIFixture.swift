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

    static func makeCoordinator() -> ProviderUsageCoordinator {
        #if DEBUG
        if isEnabled {
            let credentials = FixtureCredentials()
            let connections = FixtureConnections()
            for connection in connections.values {
                credentials.values[connection.credentialReference] = "preview-only-not-an-api-key"
            }
            return ProviderUsageCoordinator(
                credentialStore: credentials, connectionStore: connections,
                transport: FixtureTransport(), automaticTimers: true
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
    var values: [ProviderConnection] = [
        ProviderConnection(id: UUID(), kind: .deepSeek, region: .global,
                           name: L10n.string("providers.preview_balance"), enabled: true,
                           credentialReference: UUID().uuidString, identityEpoch: UUID(), selectedBucketID: nil),
        ProviderConnection(id: UUID(), kind: .miniMax, region: .global,
                           name: L10n.string("providers.preview_quota"), enabled: true,
                           credentialReference: UUID().uuidString, identityEpoch: UUID(), selectedBucketID: nil)
    ]
    var selected: UUID?
    init() { selected = values.first?.id }
    func loadConnections() throws -> [ProviderConnection] { values }
    func saveConnections(_ connections: [ProviderConnection]) throws { values = connections }
    func loadSelectedConnectionID() -> UUID? { selected }
    func saveSelectedConnectionID(_ id: UUID?) throws { selected = id }
}

private struct FixtureTransport: ProviderUsageTransport {
    func send(_ request: URLRequest) async throws -> ProviderHTTPResponse {
        guard let url = request.url else { throw ProviderUsageFailure(code: .invalidConfiguration) }
        let body: [String: Any]
        switch url.host {
        case "api.deepseek.com":
            body = ["is_available": true, "balance_infos": [
                ["currency": "CNY", "total_balance": "12.3456", "granted_balance": "2.00", "topped_up_balance": "10.3456"],
                ["currency": "USD", "total_balance": "0.25", "granted_balance": "0", "topped_up_balance": "0.25"]
            ]]
        case "api.minimax.io", "api.minimax.cn":
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
        default:
            throw ProviderUsageFailure(code: .invalidConfiguration)
        }
        return ProviderHTTPResponse(data: try JSONSerialization.data(withJSONObject: body),
                                    statusCode: 200, headers: [:], url: url)
    }
}
#endif
