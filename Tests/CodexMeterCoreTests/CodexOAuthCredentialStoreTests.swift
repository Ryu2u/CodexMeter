import Foundation
import LocalAuthentication
import Security
import XCTest
@testable import CodexMeterCore

final class CodexOAuthCredentialStoreTests: XCTestCase {
    @MainActor
    func testDeniedOrFailedWritePreservesExistingCredential() async throws {
        for status in [errSecAuthFailed, errSecInteractionNotAllowed, errSecIO] {
            let backend = KeychainFixture()
            backend.value = Data("existing-fixture-refresh".utf8)
            backend.updateStatus = status
            let store = CodexOAuthCredentialStore(operations: backend.operations)

            XCTAssertThrowsError(try store.write("rotated-fixture-refresh", allowInteraction: false))
            XCTAssertEqual(backend.value, Data("existing-fixture-refresh".utf8))
            XCTAssertEqual(backend.addCount, 0)
            XCTAssertEqual(backend.deleteCount, 0)
        }
    }

    @MainActor
    func testRetryingPersistenceUpdatesWithoutDeletingTheOldItem() async throws {
        let backend = KeychainFixture()
        backend.value = Data("old-fixture".utf8)
        backend.updateStatus = errSecInteractionNotAllowed
        let store = CodexOAuthCredentialStore(operations: backend.operations)
        XCTAssertThrowsError(try store.write("rotated-fixture", allowInteraction: false))

        backend.updateStatus = errSecSuccess
        try store.write("rotated-fixture", allowInteraction: true)
        XCTAssertEqual(try store.read(allowInteraction: false), "rotated-fixture")
        XCTAssertEqual(backend.addCount, 0)
        XCTAssertEqual(backend.deleteCount, 0)
    }

    @MainActor
    func testMissingItemIsCreatedWithDeviceOnlyAccessibility() async throws {
        let backend = KeychainFixture()
        backend.updateStatus = errSecItemNotFound
        let store = CodexOAuthCredentialStore(operations: backend.operations)
        try store.write("new-fixture-refresh", allowInteraction: true)

        XCTAssertEqual(backend.addCount, 1)
        XCTAssertEqual(backend.deleteCount, 0)
        XCTAssertEqual(backend.addQuery?[kSecAttrAccessible as String] as? String,
                       kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        XCTAssertEqual(try store.read(allowInteraction: false), "new-fixture-refresh")
    }

    @MainActor
    func testOnlyExplicitInteractionsMayOpenKeychainAuthorization() async throws {
        let backend = KeychainFixture()
        backend.value = Data("fixture-refresh".utf8)
        let store = CodexOAuthCredentialStore(operations: backend.operations)
        _ = try store.read(allowInteraction: false)
        try store.write("rotated-fixture-refresh", allowInteraction: false)
        _ = try store.read(allowInteraction: true)
        try store.write("rotated-fixture-refresh", allowInteraction: true)

        XCTAssertEqual(backend.interactionsBlocked, [true, true, false, false])
    }

    @MainActor
    func testUnreadableKeychainIsNotTreatedAsMissingOrDeleted() async throws {
        let backend = KeychainFixture()
        backend.value = Data("fixture-refresh".utf8)
        backend.copyStatus = errSecInteractionNotAllowed
        let store = CodexOAuthCredentialStore(operations: backend.operations)
        XCTAssertThrowsError(try store.read(allowInteraction: false))
        XCTAssertEqual(backend.deleteCount, 0)
        XCTAssertEqual(backend.value, Data("fixture-refresh".utf8))

        backend.copyStatus = errSecItemNotFound
        XCTAssertNil(try store.read(allowInteraction: false))
    }

    @MainActor
    func testExplicitDisconnectDeletesCredential() async throws {
        let backend = KeychainFixture()
        backend.value = Data("fixture-refresh".utf8)
        let store = CodexOAuthCredentialStore(operations: backend.operations)
        try store.delete(allowInteraction: true)
        XCTAssertNil(backend.value)
        XCTAssertEqual(backend.deleteCount, 1)
    }
}

@MainActor
private final class KeychainFixture {
    var value: Data?
    var copyStatus: OSStatus = errSecSuccess
    var updateStatus: OSStatus = errSecSuccess
    var addCount = 0
    var deleteCount = 0
    var addQuery: [String: Any]?
    var interactionsBlocked: [Bool] = []

    var operations: CodexOAuthKeychainOperations {
        CodexOAuthKeychainOperations(
            copy: { [self] query in
                recordInteraction(query)
                return (copyStatus, value)
            },
            update: { [self] query, attributes in
                recordInteraction(query)
                if updateStatus == errSecSuccess { value = attributes[kSecValueData as String] as? Data }
                return updateStatus
            },
            add: { [self] query in
                addCount += 1
                addQuery = query
                value = query[kSecValueData as String] as? Data
                return errSecSuccess
            },
            delete: { [self] query in
                recordInteraction(query)
                deleteCount += 1
                value = nil
                return errSecSuccess
            }
        )
    }

    private func recordInteraction(_ query: [String: Any]) {
        let context = query[kSecUseAuthenticationContext as String] as? LAContext
        interactionsBlocked.append(context?.interactionNotAllowed ?? false)
    }
}
