import Foundation

@MainActor
protocol ProviderConnectionStoreProtocol {
    func loadConnections() throws -> [ProviderConnection]
    func saveConnections(_ connections: [ProviderConnection]) throws
    func loadSelectedConnectionID() -> UUID?
    func saveSelectedConnectionID(_ id: UUID?) throws
    func loadRetiringCredentialReferences() throws -> [String]
    func saveConnections(_ connections: [ProviderConnection], retiringCredentialReferences: [String]) throws
    func loadOverviewOrder() -> [String]?
    func saveOverviewOrder(_ order: [String]) throws
    func loadCodexEnrolled() -> Bool
    func saveCodexEnrolled(_ enrolled: Bool) throws
    func loadCodexShowsInOverview() -> Bool
    func saveCodexShowsInOverview(_ visible: Bool) throws
}

extension ProviderConnectionStoreProtocol {
    func loadRetiringCredentialReferences() throws -> [String] { [] }
    func saveConnections(_ connections: [ProviderConnection], retiringCredentialReferences: [String]) throws {
        try saveConnections(connections)
    }
    func loadOverviewOrder() -> [String]? { nil }
    func saveOverviewOrder(_ order: [String]) throws {}
    func loadCodexEnrolled() -> Bool { true }
    func saveCodexEnrolled(_ enrolled: Bool) throws {}
    func loadCodexShowsInOverview() -> Bool { true }
    func saveCodexShowsInOverview(_ visible: Bool) throws {}
}

/// The namespace contains metadata and selection only, never credential values.
@MainActor
final class ProviderConnectionStore: ProviderConnectionStoreProtocol {
    private let defaults: UserDefaults
    private let connectionsKey = "providers.v1.connections"
    private let selectionKey = "providers.v1.selectedConnectionID"
    private let overviewOrderKey = "providers.v1.overviewOrder"
    private let codexEnrolledKey = "providers.v1.codexEnrolled"
    private let codexShowsInOverviewKey = "providers.v1.codexShowsInOverview"
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

    func loadOverviewOrder() -> [String]? {
        defaults.stringArray(forKey: overviewOrderKey)
    }

    func saveOverviewOrder(_ order: [String]) throws {
        // Codex plus every connection; anything else cannot be rendered.
        guard order.count <= Self.maximumConnections + 1,
              Set(order).count == order.count,
              order.allSatisfy({ PopoverOverviewSource.id(forOrderToken: $0) != nil }) else {
            throw ProviderUsageErrorCode.connectionStorage
        }
        try persist(order, forKey: overviewOrderKey)
    }

    /// Codex is an ordinary removable source; the flag only controls whether
    /// its row is enrolled. Absent means enrolled for pre-shell installs.
    func loadCodexEnrolled() -> Bool {
        defaults.object(forKey: codexEnrolledKey) == nil ? true : defaults.bool(forKey: codexEnrolledKey)
    }

    func saveCodexEnrolled(_ enrolled: Bool) throws {
        try persist(enrolled, forKey: codexEnrolledKey)
    }

    /// Absent means shown, matching the connection-level field's semantics.
    func loadCodexShowsInOverview() -> Bool {
        defaults.object(forKey: codexShowsInOverviewKey) == nil
            ? true : defaults.bool(forKey: codexShowsInOverviewKey)
    }

    func saveCodexShowsInOverview(_ visible: Bool) throws {
        try persist(visible, forKey: codexShowsInOverviewKey)
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
