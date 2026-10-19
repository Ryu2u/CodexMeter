import Foundation

nonisolated enum PopoverOverviewSource: Identifiable, Equatable, Sendable {
    case codex
    case provider(ProviderConnection)

    enum ID: Hashable, Sendable {
        case codex
        case provider(UUID)
    }

    var id: ID {
        switch self {
        case .codex:
            .codex
        case .provider(let connection):
            .provider(connection.id)
        }
    }

    static func visibleSources(
        from connections: [ProviderConnection],
        developerPreviewEnabled: Bool
    ) -> [PopoverOverviewSource] {
        guard !developerPreviewEnabled else { return [.codex] }
        return [.codex] + connections.filter(\.enabled).map { .provider($0) }
    }
}
