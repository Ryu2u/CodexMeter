import Foundation
import LocalAuthentication
import Security

nonisolated enum CodexOAuthCredentialError: Error {
    case unavailable
    case storage
}

@MainActor
protocol CodexOAuthCredentialStoreProtocol {
    func read(allowInteraction: Bool) throws -> String?
    func write(_ token: String, allowInteraction: Bool) throws
    func delete(allowInteraction: Bool) throws
}

/// Injectable system operations let regression tests verify persistence failures
/// without reading or changing the user's actual Keychain.
@MainActor
struct CodexOAuthKeychainOperations {
    let copy: ([String: Any]) -> (OSStatus, Data?)
    let update: ([String: Any], [String: Any]) -> OSStatus
    let add: ([String: Any]) -> OSStatus
    let delete: ([String: Any]) -> OSStatus

    static var live: Self {
        Self(
            copy: { query in
                var result: CFTypeRef?
                let status = SecItemCopyMatching(query as CFDictionary, &result)
                return (status, result as? Data)
            },
            update: { query, attributes in
                SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            },
            add: { SecItemAdd($0 as CFDictionary, nil) },
            delete: { SecItemDelete($0 as CFDictionary) }
        )
    }
}

/// Owns only CodexMeter's OAuth refresh credential; failed writes never delete
/// the existing item. Background operations cannot open authorization dialogs.
@MainActor
final class CodexOAuthCredentialStore: CodexOAuthCredentialStoreProtocol {
    private let operations: CodexOAuthKeychainOperations

    init(operations: CodexOAuthKeychainOperations? = nil) {
        self.operations = operations ?? .live
    }

    private func query(allowInteraction: Bool) -> [String: Any] {
        let context = LAContext()
        context.interactionNotAllowed = !allowInteraction
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.codexmeter.codex-oauth.v1",
            kSecAttrAccount as String: "refresh-token",
            kSecUseAuthenticationContext as String: context
        ]
    }

    func read(allowInteraction: Bool) throws -> String? {
        var query = query(allowInteraction: allowInteraction)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let (status, data) = operations.copy(query)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data, data.count <= 16_384,
              let token = String(data: data, encoding: .utf8), !token.isEmpty else {
            throw CodexOAuthCredentialError.unavailable
        }
        return token
    }

    func write(_ token: String, allowInteraction: Bool) throws {
        guard !token.isEmpty, token.utf8.count <= 16_384 else {
            throw CodexOAuthCredentialError.storage
        }
        var query = query(allowInteraction: allowInteraction)
        let data = Data(token.utf8)
        let status = operations.update(query, [kSecValueData as String: data])
        if status == errSecSuccess { return }
        // An ACL denial, locked Keychain, or IO failure must not trigger deletion
        // or be mistaken for an absent item.
        guard status == errSecItemNotFound else { throw CodexOAuthCredentialError.storage }
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard operations.add(query) == errSecSuccess else {
            throw CodexOAuthCredentialError.storage
        }
    }

    func delete(allowInteraction: Bool) throws {
        let status = operations.delete(query(allowInteraction: allowInteraction))
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CodexOAuthCredentialError.storage
        }
    }
}
