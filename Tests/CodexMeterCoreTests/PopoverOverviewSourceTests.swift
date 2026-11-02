import XCTest
@testable import CodexMeterCore

final class PopoverOverviewSourceTests: XCTestCase {
    func testVisibleSourcesAlwaysIncludesCodexWhenThereAreNoConnections() {
        XCTAssertEqual(
            PopoverOverviewSource.visibleSources(from: [], developerPreviewEnabled: false),
            [.codex]
        )
    }

    func testVisibleSourcesFiltersDisabledConnectionsAndPreservesStoreOrder() {
        let first = makeConnection(name: "First")
        let disabled = makeConnection(name: "Disabled", enabled: false)
        let second = makeConnection(name: "Second")

        let sources = PopoverOverviewSource.visibleSources(
            from: [first, disabled, second],
            developerPreviewEnabled: false
        )

        XCTAssertEqual(sources, [.codex, .provider(first), .provider(second)])
        XCTAssertEqual(sources.map(\.id), [.codex, .provider(first.id), .provider(second.id)])
    }

    func testSameProviderAccountsRemainSeparateSources() {
        let first = makeConnection(kind: .deepSeek, name: "Personal")
        let second = makeConnection(kind: .deepSeek, name: "Team")

        let sources = PopoverOverviewSource.visibleSources(
            from: [first, second],
            developerPreviewEnabled: false
        )

        XCTAssertEqual(sources, [.codex, .provider(first), .provider(second)])
        XCTAssertNotEqual(first.id, second.id)
    }

    func testProviderSourceIDSurvivesRenameAndIdentityEpochChange() {
        let connectionID = UUID()
        let original = makeConnection(id: connectionID, name: "Original")
        let renamed = ProviderConnection(
            id: connectionID,
            kind: original.kind,
            region: original.region,
            name: "Renamed",
            enabled: original.enabled,
            credentialReference: original.credentialReference,
            identityEpoch: UUID(),
            selectedBucketID: original.selectedBucketID
        )

        XCTAssertNotEqual(original, renamed)
        XCTAssertEqual(
            PopoverOverviewSource.provider(original).id,
            PopoverOverviewSource.provider(renamed).id
        )
        XCTAssertEqual(PopoverOverviewSource.provider(renamed).id, .provider(connectionID))
    }

    func testDeveloperPreviewExcludesEveryExternalConnection() {
        let enabled = makeConnection(name: "Enabled")
        let disabled = makeConnection(name: "Disabled", enabled: false)

        XCTAssertEqual(
            PopoverOverviewSource.visibleSources(
                from: [enabled, disabled],
                developerPreviewEnabled: true
            ),
            [.codex]
        )
    }

    func testRemovedCodexSourceLeavesOnlyVisibleConnections() {
        let first = makeConnection(name: "First")
        let disabled = makeConnection(name: "Disabled", enabled: false)
        let second = makeConnection(name: "Second")

        XCTAssertEqual(
            PopoverOverviewSource.visibleSources(
                from: [first, disabled, second],
                developerPreviewEnabled: false,
                codexVisible: false
            ),
            [.provider(first), .provider(second)]
        )
        XCTAssertEqual(
            PopoverOverviewSource.visibleSources(
                from: [],
                developerPreviewEnabled: false,
                codexVisible: false
            ),
            []
        )
        // Developer preview keeps rendering the Codex preview regardless.
        XCTAssertEqual(
            PopoverOverviewSource.visibleSources(
                from: [first],
                developerPreviewEnabled: true,
                codexVisible: false
            ),
            [.codex]
        )
    }

    func testOrderTokenRoundTripsEverySourceKind() {
        let connection = makeConnection(name: "DeepSeek")
        XCTAssertEqual(PopoverOverviewSource.codex.orderToken, "codex")
        XCTAssertEqual(
            PopoverOverviewSource.provider(connection).orderToken,
            connection.id.uuidString
        )
        XCTAssertEqual(
            PopoverOverviewSource.id(forOrderToken: "codex"),
            PopoverOverviewSource.ID.codex
        )
        XCTAssertEqual(
            PopoverOverviewSource.id(forOrderToken: connection.id.uuidString),
            .provider(connection.id)
        )
        XCTAssertNil(PopoverOverviewSource.id(forOrderToken: "not-a-uuid"))
    }

    func testEmptyOrderKeepsDefaultOrdering() {
        let first = makeConnection(name: "First")
        let second = makeConnection(name: "Second")

        XCTAssertEqual(
            PopoverOverviewSource.ordered([.codex, .provider(first), .provider(second)], by: []),
            [.codex, .provider(first), .provider(second)]
        )
    }

    func testOrderReordersListedSources() {
        let first = makeConnection(name: "First")
        let second = makeConnection(name: "Second")

        XCTAssertEqual(
            PopoverOverviewSource.ordered(
                [.codex, .provider(first), .provider(second)],
                by: [second.id.uuidString, "codex", first.id.uuidString]
            ),
            [.provider(second), .codex, .provider(first)]
        )
    }

    func testUnlistedSourcesAppendInDefaultOrder() {
        let first = makeConnection(name: "First")
        let second = makeConnection(name: "Second")
        let third = makeConnection(name: "Third")

        XCTAssertEqual(
            PopoverOverviewSource.ordered(
                [.codex, .provider(first), .provider(second), .provider(third)],
                by: [second.id.uuidString]
            ),
            [.provider(second), .codex, .provider(first), .provider(third)]
        )
    }

    func testUnknownAndDuplicateTokensAreIgnored() {
        let first = makeConnection(name: "First")
        let second = makeConnection(name: "Second")

        XCTAssertEqual(
            PopoverOverviewSource.ordered(
                [.codex, .provider(first), .provider(second)],
                by: ["not-a-uuid", second.id.uuidString, second.id.uuidString]
            ),
            [.provider(second), .codex, .provider(first)]
        )
    }

    func testDropMovesBeforeAndAfterTargetsAcrossCurrentOrder() {
        let first = makeConnection(name: "First")
        let second = makeConnection(name: "Second", enabled: false)
        let sources: [PopoverOverviewSource] = [.codex, .provider(first), .provider(second)]
        let initial = sources.map(\.orderToken)
        let moved = PopoverOverviewSource.moving(
            .codex, relativeTo: .provider(second.id), after: true, sources: sources, order: initial
        )
        XCTAssertEqual(moved, [first.id.uuidString, second.id.uuidString, "codex"])
        XCTAssertEqual(
            PopoverOverviewSource.moving(
                .codex, relativeTo: .provider(first.id), after: false, sources: sources, order: moved!
            ), initial
        )
    }

    func testDropPreservesSameProviderIdentitiesAndUnlistedConnections() {
        let first = makeConnection(name: "Same")
        let second = makeConnection(name: "Same")
        let new = makeConnection(name: "New")
        let sources: [PopoverOverviewSource] = [.codex, .provider(first), .provider(second), .provider(new)]
        XCTAssertEqual(
            PopoverOverviewSource.moving(
                .provider(second.id), relativeTo: .provider(first.id), after: false,
                sources: sources, order: [first.id.uuidString, "codex", second.id.uuidString]
            ), [second.id.uuidString, first.id.uuidString, "codex", new.id.uuidString]
        )
    }

    func testDropRejectsSelfDeletedIdentitiesAndUnchangedAdjacentPositions() {
        let connection = makeConnection(name: "First")
        let sources: [PopoverOverviewSource] = [.codex, .provider(connection)]
        XCTAssertNil(PopoverOverviewSource.moving(.codex, relativeTo: .codex, after: true, sources: sources, order: []))
        XCTAssertNil(PopoverOverviewSource.moving(.provider(UUID()), relativeTo: .codex, after: false, sources: sources, order: []))
        XCTAssertNil(PopoverOverviewSource.moving(.codex, relativeTo: .provider(UUID()), after: true, sources: sources, order: []))
        XCTAssertNil(PopoverOverviewSource.moving(.codex, relativeTo: .provider(connection.id), after: false, sources: sources, order: []))
        XCTAssertNil(PopoverOverviewSource.moving(.provider(connection.id), relativeTo: .codex, after: true, sources: sources, order: []))
    }

    func testOverviewHiddenConnectionsAreOmittedWhileEnabledOnesRemain() {
        let shown = makeConnection(name: "Shown")
        var hidden = makeConnection(name: "Hidden", enabled: true)
        hidden.showsInOverview = false
        let disabled = makeConnection(name: "Disabled", enabled: false)

        XCTAssertEqual(
            PopoverOverviewSource.visibleSources(
                from: [shown, hidden, disabled],
                developerPreviewEnabled: false,
                codexVisible: true
            ),
            [.codex, .provider(shown)]
        )
    }

    private func makeConnection(
        id: UUID = UUID(),
        kind: ProviderKind = .deepSeek,
        name: String,
        enabled: Bool = true
    ) -> ProviderConnection {
        ProviderConnection(
            id: id,
            kind: kind,
            region: .global,
            name: name,
            enabled: enabled,
            credentialReference: "fixture-credential-reference",
            identityEpoch: UUID(),
            selectedBucketID: nil
        )
    }
}
