import Foundation

@MainActor
protocol ProviderConnectionStoreProtocol {
    func loadConnections() throws -> [ProviderConnection]
    func saveConnections(_ connections: [ProviderConnection]) throws
    func loadSelectedConnectionID() -> UUID?
    func saveSelectedConnectionID(_ id: UUID?) throws
    func loadRetiringCredentialReferences() throws -> [String]
    func saveConnections(_ connections: [ProviderConnection], retiringCredentialReferences: [String]) throws
}

extension ProviderConnectionStoreProtocol {
    func loadRetiringCredentialReferences() throws -> [String] { [] }
    func saveConnections(_ connections: [ProviderConnection], retiringCredentialReferences: [String]) throws {
        try saveConnections(connections)
    }
}

/// The namespace contains metadata and selection only, never credential values.
@MainActor
final class ProviderConnectionStore: ProviderConnectionStoreProtocol {
    private let defaults: UserDefaults
    private let connectionsKey = "providers.v1.connections"
    private let selectionKey = "providers.v1.selectedConnectionID"
    static let maximumConnections = 32

    private struct Metadata: Codable {
        let connections: [ProviderConnection]
        let retiringCredentialReferences: [String]
    }

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func loadConnections() throws -> [ProviderConnection] {
        try loadMetadata().connections
    }

    func loadRetiringCredentialReferences() throws -> [String] {
        try loadMetadata().retiringCredentialReferences
    }

    private func loadMetadata() throws -> Metadata {
        guard let data = defaults.data(forKey: connectionsKey) else {
            return Metadata(connections: [], retiringCredentialReferences: [])
        }
        guard data.count <= 128 * 1_024 else { throw ProviderUsageErrorCode.connectionStorage }
        if let metadata = try? JSONDecoder().decode(Metadata.self, from: data),
           Self.valid(metadata.connections, retiring: metadata.retiringCredentialReferences) {
            return metadata
        }
        // Accept the initial array representation without changing existing connection identities.
        guard let connections = try? JSONDecoder().decode([ProviderConnection].self, from: data),
              Self.valid(connections, retiring: []) else { throw ProviderUsageErrorCode.connectionStorage }
        return Metadata(connections: connections, retiringCredentialReferences: [])
    }

    func saveConnections(_ connections: [ProviderConnection]) throws {
        try saveConnections(connections, retiringCredentialReferences: loadMetadata().retiringCredentialReferences)
    }

    func saveConnections(_ connections: [ProviderConnection], retiringCredentialReferences: [String]) throws {
        let metadata = Metadata(connections: connections, retiringCredentialReferences: retiringCredentialReferences)
        guard Self.valid(connections, retiring: retiringCredentialReferences),
              let data = try? JSONEncoder().encode(metadata), data.count <= 128 * 1_024 else {
            throw ProviderUsageErrorCode.connectionStorage
        }
        try persist(data, forKey: connectionsKey)
    }

    func loadSelectedConnectionID() -> UUID? {
        defaults.string(forKey: selectionKey).flatMap(UUID.init(uuidString:))
    }

    func saveSelectedConnectionID(_ id: UUID?) throws {
        try persist(id?.uuidString, forKey: selectionKey)
    }

    private func persist(_ value: Any?, forKey key: String) throws {
        let previous = defaults.object(forKey: key)
        defaults.set(value, forKey: key)
        guard defaults.synchronize() else {
            defaults.set(previous, forKey: key)
            _ = defaults.synchronize()
            throw ProviderUsageErrorCode.connectionStorage
        }
    }

    private static func valid(_ connections: [ProviderConnection], retiring: [String]) -> Bool {
        connections.count <= maximumConnections
            && Set(connections.map(\.id)).count == connections.count
            && Set(connections.map(\.credentialReference)).count == connections.count
            && retiring.count <= 64 && Set(retiring).count == retiring.count
            && retiring.allSatisfy { UUID(uuidString: $0) != nil }
            && Set(retiring).isDisjoint(with: Set(connections.map(\.credentialReference)))
            && connections.allSatisfy {
                UUID(uuidString: $0.credentialReference) != nil
                    && !$0.name.isEmpty && $0.name.count <= 80
                    && !$0.name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
                    && ($0.selectedBucketID?.utf8.count ?? 0) <= 256
            }
    }
}
