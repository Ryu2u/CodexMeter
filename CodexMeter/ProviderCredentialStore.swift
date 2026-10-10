import Foundation
import LocalAuthentication
import Security

@MainActor
protocol ProviderCredentialStoreProtocol {
    func read(reference: String, allowInteraction: Bool) throws -> String
    func write(_ key: String, reference: String) throws
    func delete(reference: String) throws
}

/// Accesses only credentials explicitly saved for CodexMeter's provider connections.
@MainActor
final class ProviderCredentialStore: ProviderCredentialStoreProtocol {
    private let service = "com.codexmeter.provider-credentials.v1"

    private func query(reference: String) throws -> [String: Any] {
        guard UUID(uuidString: reference) != nil else { throw ProviderUsageErrorCode.invalidConfiguration }
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: reference
        ]
    }

    func read(reference: String, allowInteraction: Bool) throws -> String {
        var query = try query(reference: reference)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let authenticationContext = LAContext()
        authenticationContext.interactionNotAllowed = !allowInteraction
        query[kSecUseAuthenticationContext as String] = authenticationContext
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status != errSecItemNotFound else { throw ProviderUsageErrorCode.credentialMissing }
        guard status == errSecSuccess, let data = result as? Data,
              let key = String(data: data, encoding: .utf8), ProviderUsageAdapter.validCredential(key) else {
            throw ProviderUsageErrorCode.credentialUnavailable
        }
        return key
    }

    func write(_ key: String, reference: String) throws {
        guard ProviderUsageAdapter.validCredential(key) else { throw ProviderUsageErrorCode.invalidConfiguration }
        var query = try query(reference: reference)
        query[kSecValueData as String] = Data(key.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(query as CFDictionary, nil) == errSecSuccess else {
            throw ProviderUsageErrorCode.credentialStorage
        }
    }

    func delete(reference: String) throws {
        var query = try query(reference: reference)
        let authenticationContext = LAContext()
        authenticationContext.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = authenticationContext
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ProviderUsageErrorCode.credentialStorage
        }
    }
}
