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
