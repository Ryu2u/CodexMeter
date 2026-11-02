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

    /// Stable string form persisted in the user's overview order.
    var orderToken: String {
        switch self {
        case .codex:
            "codex"
        case .provider(let connection):
            connection.id.uuidString
        }
    }

    static func id(forOrderToken token: String) -> ID? {
        token == "codex" ? .codex : UUID(uuidString: token).map { .provider($0) }
    }

    /// Applies the persisted order: listed sources keep it, unlisted ones
    /// append in their default relative order, and unknown or duplicated
    /// tokens (removed or renamed sources) are ignored rather than dropping
    /// any source.
    static func ordered(
        _ sources: [PopoverOverviewSource],
        by order: [String]
    ) -> [PopoverOverviewSource] {
        guard !order.isEmpty else { return sources }
        let byToken = Dictionary(uniqueKeysWithValues: sources.map { ($0.orderToken, $0) })
        var seen = Set<String>()
        var sorted: [PopoverOverviewSource] = []
        for token in order {
            guard !seen.contains(token), let source = byToken[token] else { continue }
            seen.insert(token)
            sorted.append(source)
        }
        return sorted + sources.filter { !seen.contains($0.orderToken) }
    }

    /// The shell lists every enrolled source uniformly: Codex appears only
    /// while visible (enrolled and not hidden by its overview switch),
    /// exactly like an enabled connection. Developer preview keeps rendering
    /// the Codex preview regardless.
    static func visibleSources(
        from connections: [ProviderConnection],
        developerPreviewEnabled: Bool,
        codexVisible: Bool = true
    ) -> [PopoverOverviewSource] {
        guard !developerPreviewEnabled else { return [.codex] }
        return (codexVisible ? [.codex] : [])
            + connections.filter { $0.enabled && $0.isShownInOverview }.map { .provider($0) }
    }

    /// Resolves an insertion against the current identities, not stale drag indices.
    /// A missing source/target or an unchanged position never produces a write.
    static func moving(
        _ id: ID,
        relativeTo target: ID,
        after: Bool,
        sources: [PopoverOverviewSource],
        order: [String]
    ) -> [String]? {
        guard id != target else { return nil }
        let original = ordered(sources, by: order)
        guard let sourceIndex = original.firstIndex(where: { $0.id == id }),
              original.contains(where: { $0.id == target }) else { return nil }
        var result = original
        let source = result.remove(at: sourceIndex)
        guard let targetIndex = result.firstIndex(where: { $0.id == target }) else { return nil }
        result.insert(source, at: targetIndex + (after ? 1 : 0))
        return result == original ? nil : result.map(\.orderToken)
    }
}
