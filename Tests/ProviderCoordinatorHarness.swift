// Compile this isolated harness with Core and the provider store/coordinator sources; it never accesses real credentials or APIs.
import Combine
import Foundation

@MainActor
private final class HarnessCredentials: ProviderCredentialStoreProtocol {
    var values: [String: String] = [:]
    var failWrite = false
    var failDeletes: Set<String> = []
    var readInteractions: [Bool] = []
    var readReferences: [String] = []
    var authorizationRequired: Set<String> = []
    var onDelete: ((String) -> Void)?
    func read(reference: String, allowInteraction: Bool) throws -> String {
        readInteractions.append(allowInteraction)
        readReferences.append(reference)
        guard allowInteraction || !authorizationRequired.contains(reference) else {
            throw ProviderUsageErrorCode.credentialUnavailable
        }
        guard let value = values[reference] else { throw ProviderUsageErrorCode.credentialMissing }
        return value
    }
    func write(_ key: String, reference: String) throws {
        guard !failWrite else { throw ProviderUsageErrorCode.credentialStorage }
        values[reference] = key
    }
    func delete(reference: String) throws {
        guard !failDeletes.contains(reference) else { throw ProviderUsageErrorCode.credentialStorage }
        onDelete?(reference)
        values[reference] = nil
    }
}

@MainActor
private final class HarnessConnections: ProviderConnectionStoreProtocol {
    var values: [ProviderConnection] = []
    var selected: UUID?
    var failWrite = false
    var retiring: [String] = []
    var overviewOrder: [String]?
    var overviewWrites = 0
    func loadConnections() throws -> [ProviderConnection] { values }
    func saveConnections(_ connections: [ProviderConnection]) throws {
        guard !failWrite else { throw ProviderUsageErrorCode.connectionStorage }
        values = connections
    }
    func loadSelectedConnectionID() -> UUID? { selected }
    func saveSelectedConnectionID(_ id: UUID?) throws { selected = id }
    func loadRetiringCredentialReferences() throws -> [String] { retiring }
    func loadOverviewOrder() -> [String]? { overviewOrder }
    func saveOverviewOrder(_ order: [String]) throws {
        guard !failWrite else { throw ProviderUsageErrorCode.connectionStorage }
        overviewOrder = order
        overviewWrites += 1
    }
    func saveConnections(_ connections: [ProviderConnection], retiringCredentialReferences: [String]) throws {
        try saveConnections(connections)
        retiring = retiringCredentialReferences
    }
}

nonisolated private final class HarnessClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 1_800_000_000)
    func now() -> Date { lock.lock(); defer { lock.unlock() }; return value }
    func advance(_ interval: TimeInterval) { lock.lock(); defer { lock.unlock() }; value.addTimeInterval(interval) }
}

private actor HarnessTransport: ProviderUsageTransport {
    private var pending: [Int: CheckedContinuation<ProviderHTTPResponse, Error>] = [:]
    private(set) var requests: [URLRequest] = []
    func send(_ request: URLRequest) async throws -> ProviderHTTPResponse {
        requests.append(request)
        let index = requests.count
        // Deliberately ignore cancellation until resumed to replay a late server response.
        return try await withCheckedThrowingContinuation { pending[index] = $0 }
    }
    func complete(_ index: Int, status: Int = 200, amount: String = "1", retryAfter: String? = nil) {
        let data = Data("{\"balance_infos\":[{\"currency\":\"USD\",\"total_balance\":\"\(amount)\"}]}".utf8)
        let headers = retryAfter.map { ["retry-after": $0] } ?? [:]
        pending.removeValue(forKey: index)!.resume(returning: ProviderHTTPResponse(
            data: data, statusCode: status, headers: headers, url: requests[index - 1].url!))
    }
    func fail(_ index: Int) { pending.removeValue(forKey: index)!.resume(throwing: URLError(.cannotConnectToHost)) }
    func completeJSON(_ index: Int, json: String) {
        pending.removeValue(forKey: index)!.resume(returning: ProviderHTTPResponse(
            data: Data(json.utf8), statusCode: 200, headers: [:], url: requests[index - 1].url!))
    }
    func index(forFixtureKey key: String) -> Int {
        requests.firstIndex { $0.value(forHTTPHeaderField: "Authorization") == "Bearer \(key)" }! + 1
    }
    func latestIndex(forFixtureKey key: String) -> Int {
        requests.lastIndex { $0.value(forHTTPHeaderField: "Authorization") == "Bearer \(key)" }! + 1
    }
    var count: Int { requests.count }
}

@main
private struct ProviderCoordinatorHarness {
    @MainActor
    static func main() async throws {
        let credentials = HarnessCredentials(), store = HarnessConnections(), clock = HarnessClock()
        let transport = HarnessTransport()
        let coordinator = ProviderUsageCoordinator(credentialStore: credentials, connectionStore: store,
            transport: transport, now: { clock.now() }, automaticTimers: false)
        try coordinator.saveConnection(kind: .deepSeek, region: .global, name: "First", key: "fixture-first")
        try coordinator.saveConnection(kind: .deepSeek, region: .global, name: "Second", key: "fixture-second")
        let first = coordinator.connections[0], second = coordinator.connections[1]
        check(coordinator.selectedBucket(for: first.id) == nil, "No synthetic zero snapshot")
        coordinator.refresh(first.id)
        coordinator.refresh(first.id)
        coordinator.refresh(second.id)
        await wait { await transport.count == 2 }
        let oldFirstRequest = await transport.index(forFixtureKey: "fixture-first")
        let originalSecondRequest = await transport.index(forFixtureKey: "fixture-second")
        credentials.onDelete = { reference in
            if reference == first.credentialReference {
                check(store.values[0].credentialReference != reference, "Metadata committed before old key deletion")
                check(coordinator.connections[0].identityEpoch != first.identityEpoch, "Identity published before old key deletion")
            }
        }
        try coordinator.saveConnection(id: first.id, kind: .deepSeek, region: .global, name: "First", key: "fixture-replacement")
        check(credentials.values[first.credentialReference] == nil, "Old owned credential removed")
        check(coordinator.snapshots[first.id] == nil, "Replacement clears visible snapshot")
        coordinator.refresh(first.id)
        await wait { await transport.count == 3 }
        await transport.complete(3, amount: "33")
        await wait { await MainActor.run { coordinator.statuses[first.id] == .ready } }
        await transport.complete(oldFirstRequest, amount: "999")
        await transport.complete(originalSecondRequest, amount: "44")
        await wait { await MainActor.run { coordinator.statuses[second.id] == .ready } }
        check(coordinator.snapshots[first.id]?.buckets.first?.metric == .money(remaining: 33, currency: "USD"), "Late replacement response ignored")
        check(coordinator.snapshots[second.id]?.buckets.first?.metric == .money(remaining: 44, currency: "USD"), "Independent connection preserved")

        let current = coordinator.connections[0]
        try coordinator.saveConnection(id: current.id, kind: current.kind, region: current.region, name: "Renamed", key: "")
        check(coordinator.connections[0].identityEpoch == current.identityEpoch, "Rename retains identity")
        coordinator.selectBucket("missing:explicit", for: first.id)
        check(coordinator.selectedBucket(for: first.id) == nil, "Explicit missing bucket does not select another")
        check(store.values[0].selectedBucketID == "missing:explicit", "Bucket selection persists")
        coordinator.selectBucket(nil, for: first.id)
        check(coordinator.selectedBucket(for: first.id)?.id == "balance:USD", "Automatic balance selection")
        coordinator.selectedConnectionID = second.id
        coordinator.refresh(second.id)
        await wait { await transport.count == 4 }
        try coordinator.deleteConnection(second.id)
        await transport.complete(4, amount: "888")
        await spin()
        check(coordinator.snapshots[second.id] == nil, "Deleted connection cannot receive a late snapshot")
        check(coordinator.selectedConnectionID == nil && store.selected == nil, "Delete restores Codex selection")
        check(credentials.values[second.credentialReference] == nil, "Delete removes only its owned key")

        store.failWrite = true
        let retained = coordinator.connections[0], count = credentials.values.count
        do {
            try coordinator.saveConnection(id: first.id, kind: .deepSeek, region: .global, name: "Failed", key: "fixture-never-committed")
            fatalError("Persistence failure was not reported")
        } catch let code as ProviderUsageErrorCode { check(code == .connectionStorage, "Local persistence error") }
        check(coordinator.connections[0] == retained, "Failed persistence does not publish replacement")
        check(credentials.values.count == count, "Uncommitted new key cleaned up")
        store.failWrite = false
        credentials.failWrite = true
        do {
            try coordinator.saveConnection(id: first.id, kind: .deepSeek, region: .global, name: "Failed", key: "fixture-write-rejected")
            fatalError("Keychain failure was not reported")
        } catch let code as ProviderUsageErrorCode { check(code == .credentialStorage, "Local keychain error") }
        check(coordinator.connections[0] == retained, "Keychain write failure preserves connection")
        credentials.failWrite = false

        coordinator.refresh(first.id)
        await wait { await transport.count == 5 }
        await transport.fail(5)
        await wait { await MainActor.run { coordinator.statuses[first.id] == .stale(.network) } }
        check(coordinator.snapshots[first.id]?.buckets.first?.metric == .money(remaining: 33, currency: "USD"), "Network failure retains stale successful snapshot")
        coordinator.poll()
        await spin()
        check(await transport.count == 5, "Network backoff suppresses automatic request")
        clock.advance(20)
        coordinator.poll()
        await wait { await transport.count == 6 }
        await transport.complete(6, status: 401)
        await wait { await MainActor.run { coordinator.statuses[first.id] == .authRequired } }
        clock.advance(1_000)
        coordinator.poll()
        await spin()
        check(await transport.count == 6, "Authentication failure stops automatic requests")
        check(credentials.readInteractions.contains(false), "Automatic credential reads disallow interaction")
        coordinator.refresh(first.id)
        await wait { await transport.count == 7 }
        await transport.complete(7, status: 429, retryAfter: "600")
        await wait { await MainActor.run { coordinator.statuses[first.id]?.errorCode == .rateLimited } }
        coordinator.refresh(first.id)
        clock.advance(599)
        coordinator.refresh(first.id)
        await spin()
        check(await transport.count == 7, "Manual refresh respects Retry-After")
        clock.advance(1)
        coordinator.refresh(first.id)
        await wait { await transport.count == 8 }
        await transport.complete(8, amount: "20")
        await wait { await MainActor.run { coordinator.statuses[first.id] == .ready } }
        var publications = 0
        let observation = coordinator.objectWillChange.sink { publications += 1 }
        clock.advance(60)
        coordinator.poll()
        await spin()
        let minuteRequestCount = await transport.count
        check(publications > 0 && minuteRequestCount == 8, "Minute publication does not issue an extra HTTP request")
        withExtendedLifetime(observation) {}

        let previousEpoch = coordinator.connections[0].identityEpoch
        try coordinator.saveConnection(id: first.id, kind: .deepSeek, region: .china, name: "Renamed", key: "")
        check(coordinator.connections[0].identityEpoch != previousEpoch, "Region change rotates identity")
        check(coordinator.snapshots[first.id] == nil, "Region change discards previous snapshot")
        let suite = "CodexMeter.ProviderFixture.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("unchanged", forKey: "codex.preference.fixture")
        let persistent = ProviderConnectionStore(defaults: defaults)
        try persistent.saveConnections(coordinator.connections)
        try persistent.saveSelectedConnectionID(first.id)
        check(try persistent.loadConnections() == coordinator.connections, "Metadata round trip")
        check(persistent.loadSelectedConnectionID() == first.id, "Selection round trip")
        check(defaults.string(forKey: "codex.preference.fixture") == "unchanged", "Codex preferences stay isolated")
        let encoded = String(data: defaults.data(forKey: "providers.v1.connections")!, encoding: .utf8)!
        check(!encoded.contains("fixture-replacement"), "Persisted metadata excludes the key")

        let interruptedReference = UUID().uuidString
        credentials.values[interruptedReference] = "fixture-interrupted-save"
        let disabledConnections = coordinator.connections.map { connection in
            var disabled = connection
            disabled.enabled = false
            return disabled
        }
        try persistent.saveConnections(disabledConnections, retiringCredentialReferences: [interruptedReference])
        let recovered = ProviderUsageCoordinator(credentialStore: credentials, connectionStore: persistent,
            transport: transport, now: { clock.now() }, automaticTimers: false)
        check(try persistent.loadRetiringCredentialReferences() == [interruptedReference], "Retirement journal survives reloading")
        // All connections are disabled so startup cleanup performs no HTTP request.
        recovered.start()
        check(credentials.values[interruptedReference] == nil, "Interrupted uncommitted secret is cleaned up")
        check(try persistent.loadRetiringCredentialReferences().isEmpty, "Successful cleanup clears its persisted journal")

        let active = recovered.connections[0]
        do {
            try persistent.saveConnections(recovered.connections, retiringCredentialReferences: [active.credentialReference])
            fatalError("Active credential retirement was accepted")
        } catch let code as ProviderUsageErrorCode { check(code == .connectionStorage, "Active references cannot enter cleanup") }
        do {
            try persistent.saveConnections(recovered.connections, retiringCredentialReferences: (0..<65).map { _ in UUID().uuidString })
            fatalError("Unbounded retirement queue was accepted")
        } catch let code as ProviderUsageErrorCode { check(code == .connectionStorage, "Retirement queue is bounded") }
        credentials.failDeletes = [active.credentialReference]
        do { try recovered.deleteConnection(active.id); fatalError("Deletion failure was not reported") }
        catch let code as ProviderUsageErrorCode { check(code == .credentialStorage, "Deletion failure uses a local code") }
        check(recovered.connections.isEmpty, "A failed secret deletion still revokes the visible connection")
        check(try persistent.loadRetiringCredentialReferences() == [active.credentialReference], "Failed deletion remains recoverable")
        credentials.failDeletes = []
        let retriedCleanup = ProviderUsageCoordinator(credentialStore: credentials, connectionStore: persistent,
            transport: transport, now: { clock.now() }, automaticTimers: false)
        retriedCleanup.start()
        check(credentials.values[active.credentialReference] == nil, "Next launch retries only the retired owned reference")
        check(try persistent.loadRetiringCredentialReferences().isEmpty, "Retry clears the retirement journal")

        let boostStore = HarnessConnections()
        let boostedCoordinator = ProviderUsageCoordinator(credentialStore: credentials, connectionStore: boostStore,
            transport: transport, now: { clock.now() }, automaticTimers: false)
        try boostedCoordinator.saveConnection(kind: .miniMax, region: .china, name: "MiniMax fixture", key: "fixture-minimax")
        let boostedID = boostedCoordinator.connections[0].id
        boostedCoordinator.refresh(boostedID)
        await wait { await transport.count == 9 }
        await transport.completeJSON(9, json: """
        {"model_remains":[{"model_name":"general","current_interval_remaining_percent":50,
         "current_weekly_remaining_percent":40,"weekly_boost_permille":1500}]}
        """)
        await wait { await MainActor.run { boostedCoordinator.statuses[boostedID] == .ready } }
        check(boostedCoordinator.selectedBucket(for: boostedID)?.id == "general:weekly", "Automatic selection uses normalized current-plan capacity")
        check(boostedCoordinator.selectedBucket(for: boostedID)?.metric == .percentage(remaining: 60), "Selected boosted metric preserves base-equivalent amount")
        boostedCoordinator.selectBucket("general:interval", for: boostedID)
        check(boostedCoordinator.selectedBucket(for: boostedID)?.id == "general:interval", "Explicit provider bucket remains selected")
        try await testRefreshAllFanOut()
        try await testRefreshAllRetryPolicies()
        try await testAutomaticBucketPrefersStandardDurations()
        try await testPlatformOrderPersistence()
        print("Provider coordinator isolated harness passed (fake credentials and HTTP only).")
    }

    @MainActor
    private static func testPlatformOrderPersistence() async throws {
        let credentials = HarnessCredentials(), store = HarnessConnections()
        let transport = HarnessTransport()
        let first = ProviderConnection(
            id: UUID(), kind: .deepSeek, region: .global, name: "Same", enabled: false,
            credentialReference: UUID().uuidString, identityEpoch: UUID(), selectedBucketID: "balance:CNY"
        )
        let second = ProviderConnection(
            id: UUID(), kind: .deepSeek, region: .global, name: "Same", enabled: false,
            credentialReference: UUID().uuidString, identityEpoch: UUID(), selectedBucketID: nil
        )
        store.values = [first, second]
        store.selected = first.id
        store.overviewOrder = [second.id.uuidString, "codex", first.id.uuidString]
        let coordinator = ProviderUsageCoordinator(
            credentialStore: credentials, connectionStore: store,
            transport: transport, automaticTimers: false
        )
        check(coordinator.orderedOverviewSources.map(\.orderToken) == store.overviewOrder, "Settings restores persisted source order")
        check(coordinator.moveOverviewSource(.codex, relativeTo: .provider(first.id), after: true), "Valid drop commits")
        let saved = [second.id.uuidString, first.id.uuidString, "codex"]
        check(store.overviewOrder == saved && coordinator.overviewOrder == saved, "Persisted and published order agree")
        check(coordinator.connections == [first, second] && store.values == [first, second], "Ordering preserves connection identities, metadata and store order")
        check(coordinator.selectedConnectionID == first.id && store.selected == first.id, "Ordering preserves menu-bar source selection")
        store.failWrite = true
        check(!coordinator.moveOverviewSource(.provider(first.id), relativeTo: .provider(second.id), after: false), "Failed drop save is reported")
        check(coordinator.overviewOrder == saved && store.overviewOrder == saved, "Failed save retains previous published and stored order")
        check(coordinator.configurationError == .connectionStorage, "Failed order save is visible")
        store.failWrite = false
        let writes = store.overviewWrites
        check(!coordinator.moveOverviewSource(.codex, relativeTo: .codex, after: false), "Self drop is ignored")
        check(!coordinator.moveOverviewSource(.provider(UUID()), relativeTo: .codex, after: false), "Deleted source is ignored")
        check(!coordinator.moveOverviewSource(.codex, relativeTo: .provider(UUID()), after: true), "Deleted destination is ignored")
        check(!coordinator.moveOverviewSource(.codex, relativeTo: .provider(first.id), after: true), "Unchanged adjacent position is ignored")
        check(store.overviewWrites == writes, "Ignored drops never persist")
        let restored = ProviderUsageCoordinator(
            credentialStore: credentials, connectionStore: store,
            transport: transport, automaticTimers: false
        )
        check(restored.orderedOverviewSources.map(\.orderToken) == saved, "New coordinator restores saved display order")
        check(restored.selectedConnectionID == first.id && credentials.readReferences.isEmpty, "Restoration preserves selection without credential reads")
        check(await transport.count == 0, "Reordering makes no HTTP requests")
        print("Platform drag order passed (persistence, rollback, restoration, disabled/same-provider identity, selection, no-op and no HTTP).")
    }

    @MainActor
    private static func testRefreshAllFanOut() async throws {
        let credentials = HarnessCredentials(), store = HarnessConnections(), clock = HarnessClock()
        let transport = HarnessTransport()
        let coordinator = ProviderUsageCoordinator(credentialStore: credentials, connectionStore: store,
            transport: transport, now: { clock.now() }, automaticTimers: false)
        try coordinator.saveConnection(kind: .deepSeek, region: .global, name: "All first", key: "fixture-all-first")
        try coordinator.saveConnection(kind: .miniMax, region: .china, name: "All quota", key: "fixture-all-quota")
        try coordinator.saveConnection(kind: .deepSeek, region: .global, name: "All second", key: "fixture-all-second")
        try coordinator.saveConnection(kind: .deepSeek, region: .global, name: "Disabled", key: "fixture-all-disabled", enabled: false)
        let first = coordinator.connections[0], quota = coordinator.connections[1]
        let second = coordinator.connections[2], disabled = coordinator.connections[3]
        let enabledReferences = [first.credentialReference, quota.credentialReference, second.credentialReference]
        check(coordinator.selectedConnectionID == nil, "Fan-out starts with Codex selected")

        coordinator.refresh(first.id)
        coordinator.refreshAll()
        coordinator.refreshAll()
        coordinator.poll()
        await wait { await transport.count == 3 }
        await spin()
        check(await transport.count == 3, "One busy connection does not block others or duplicate in-flight work")
        check(credentials.readReferences.sorted() == enabledReferences.sorted(), "Each enabled connection reads its own credential once")
        check(credentials.readInteractions == [true, true, true], "Default all-source refresh preserves manual authorization")
        check(coordinator.statuses[disabled.id] == .unavailable(.disabled), "Disabled status stays unchanged")
        await transport.complete(await transport.latestIndex(forFixtureKey: "fixture-all-first"), amount: "10")
        await transport.completeJSON(await transport.latestIndex(forFixtureKey: "fixture-all-quota"), json: """
        {"model_remains":[{"model_name":"general","current_interval_remaining_percent":50,
         "current_weekly_remaining_percent":40}]}
        """)
        await transport.complete(await transport.latestIndex(forFixtureKey: "fixture-all-second"), amount: "30")
        await wait { await MainActor.run {
            coordinator.statuses[first.id] == .ready && coordinator.statuses[quota.id] == .ready
                && coordinator.statuses[second.id] == .ready
        } }
        check(coordinator.snapshots.count == 3, "All enabled snapshots publish with no external source selected")
        check(coordinator.snapshots[first.id]?.buckets.first?.metric == .money(remaining: 10, currency: "USD"), "First balance publishes independently")
        check(coordinator.snapshots[quota.id]?.buckets.contains { $0.metric == .percentage(remaining: 40) } == true, "Different provider quota publishes independently")
        check(coordinator.snapshots[second.id]?.buckets.first?.metric == .money(remaining: 30, currency: "USD"), "Same-provider connections remain independent")

        coordinator.selectedConnectionID = second.id
        coordinator.refreshAll()
        coordinator.refreshAll()
        await wait { await transport.count == 6 }
        await spin()
        check(await transport.count == 6 && credentials.readReferences.count == 6, "Selection does not filter fan-out or bypass deduplication")
        await transport.complete(await transport.latestIndex(forFixtureKey: "fixture-all-first"), amount: "11")
        await transport.completeJSON(await transport.latestIndex(forFixtureKey: "fixture-all-quota"), json: """
        {"model_remains":[{"model_name":"general","current_interval_remaining_percent":25,
         "current_weekly_remaining_percent":30}]}
        """)
        await transport.complete(await transport.latestIndex(forFixtureKey: "fixture-all-second"), amount: "31")
        await wait { await MainActor.run {
            coordinator.statuses[first.id] == .ready && coordinator.statuses[quota.id] == .ready
                && coordinator.statuses[second.id] == .ready
        } }
        check(coordinator.snapshots[first.id]?.buckets.first?.metric == .money(remaining: 11, currency: "USD"), "Nonselected balance still refreshes")
        check(coordinator.snapshots[quota.id]?.buckets.contains { $0.metric == .percentage(remaining: 25) } == true, "Nonselected provider still refreshes")
        check(coordinator.snapshots[second.id]?.buckets.first?.metric == .money(remaining: 31, currency: "USD"), "Selected balance also refreshes")
        check(coordinator.selectedConnectionID == second.id && store.selected == second.id, "Refresh-all preserves menu-bar selection")
        check(!credentials.readReferences.contains(disabled.credentialReference) && coordinator.snapshots[disabled.id] == nil, "Disabled connection never reads credentials or publishes a snapshot")
        print("Refresh-all fan-out passed (selection, disabled, in-flight, duplicate calls).")
    }

    @MainActor
    private static func testRefreshAllRetryPolicies() async throws {
        let credentials = HarnessCredentials(), store = HarnessConnections(), clock = HarnessClock()
        let transport = HarnessTransport()
        let coordinator = ProviderUsageCoordinator(credentialStore: credentials, connectionStore: store,
            transport: transport, now: { clock.now() }, automaticTimers: false)
        try coordinator.saveConnection(kind: .deepSeek, region: .global, name: "Policy first", key: "fixture-policy-first")
        try coordinator.saveConnection(kind: .deepSeek, region: .global, name: "Policy second", key: "fixture-policy-second")
        let first = coordinator.connections[0], second = coordinator.connections[1]

        coordinator.refreshAll(manual: false)
        await wait { await transport.count == 2 }
        check(credentials.readInteractions == [false, false], "Automatic fan-out forbids credential authorization dialogs")
        await transport.complete(await transport.latestIndex(forFixtureKey: "fixture-policy-first"), amount: "10")
        await transport.complete(await transport.latestIndex(forFixtureKey: "fixture-policy-second"), amount: "20")
        await wait { await MainActor.run { coordinator.statuses[first.id] == .ready && coordinator.statuses[second.id] == .ready } }
        var publications = 0
        let observation = coordinator.objectWillChange.sink { publications += 1 }
        clock.advance(60)
        coordinator.poll()
        await spin()
        check(publications > 0 && credentials.readReferences.count == 2, "Poll publishes the minute clock without reading successful credentials again")
        check(await transport.count == 2, "Minute clock does not issue extra HTTP requests")
        withExtendedLifetime(observation) {}
        clock.advance(239)
        coordinator.refreshAll(manual: false)
        await spin()
        check(await transport.count == 2 && credentials.readReferences.count == 2, "Automatic fan-out respects the five-minute success interval")
        clock.advance(1)
        coordinator.poll()
        await wait { await transport.count == 4 }
        check(credentials.readInteractions == [false, false, false, false], "Poll delegates automatic refresh without interaction")
        await transport.fail(await transport.latestIndex(forFixtureKey: "fixture-policy-first"))
        await transport.complete(await transport.latestIndex(forFixtureKey: "fixture-policy-second"), amount: "21")
        await wait { await MainActor.run { coordinator.statuses[first.id] == .stale(.network) && coordinator.statuses[second.id] == .ready } }
        check(coordinator.snapshots[first.id]?.buckets.first?.metric == .money(remaining: 10, currency: "USD"), "One source failure retains its previous snapshot")
        check(coordinator.snapshots[second.id]?.buckets.first?.metric == .money(remaining: 21, currency: "USD"), "One source failure does not prevent another source publishing")
        coordinator.refreshAll(manual: false)
        clock.advance(19)
        coordinator.refreshAll(manual: false)
        await spin()
        check(await transport.count == 4 && credentials.readReferences.count == 4, "Automatic fan-out respects ordinary error backoff")
        clock.advance(1)
        coordinator.refreshAll(manual: false)
        await wait { await transport.count == 5 }
        check(credentials.readReferences.last == first.credentialReference && credentials.readInteractions.last == false, "Only the due failed source retries automatically")
        await transport.fail(await transport.latestIndex(forFixtureKey: "fixture-policy-first"))
        await wait { await MainActor.run { coordinator.statuses[first.id] == .stale(.network) } }

        coordinator.refreshAll()
        await wait { await transport.count == 7 }
        check(Array(credentials.readInteractions.suffix(2)) == [true, true], "Manual fan-out retries ordinary errors and allows authorization")
        await transport.complete(await transport.latestIndex(forFixtureKey: "fixture-policy-first"), status: 401)
        await transport.complete(await transport.latestIndex(forFixtureKey: "fixture-policy-second"), amount: "22")
        await wait { await MainActor.run { coordinator.statuses[first.id] == .authRequired && coordinator.statuses[second.id] == .ready } }
        check(coordinator.snapshots[first.id]?.buckets.first?.metric == .money(remaining: 10, currency: "USD"), "Authentication failure also retains the previous snapshot")
        clock.advance(1_000)
        coordinator.refreshAll(manual: false)
        await wait { await transport.count == 8 }
        await spin()
        check(await transport.count == 8 && credentials.readReferences.count == 8, "Authentication-blocked source does not block or join another source's automatic refresh")
        check(credentials.readReferences.last == second.credentialReference && credentials.readInteractions.last == false, "Authentication-blocked source does not reread credentials automatically")
        await transport.complete(await transport.latestIndex(forFixtureKey: "fixture-policy-second"), amount: "23")
        await wait { await MainActor.run { coordinator.statuses[second.id] == .ready } }
        coordinator.refreshAll()
        await wait { await transport.count == 10 }
        await transport.complete(await transport.latestIndex(forFixtureKey: "fixture-policy-first"), status: 429, retryAfter: "600")
        await transport.complete(await transport.latestIndex(forFixtureKey: "fixture-policy-second"), amount: "24")
        await wait { await MainActor.run { coordinator.statuses[first.id]?.errorCode == .rateLimited && coordinator.statuses[second.id] == .ready } }
        let retryAt = clock.now().addingTimeInterval(600)
        check(coordinator.statuses[first.id] == .rateLimited(until: retryAt), "Retry-After is retained per connection")
        check(coordinator.snapshots[first.id]?.buckets.first?.metric == .money(remaining: 10, currency: "USD"), "Rate limiting retains the previous snapshot")
        coordinator.refreshAll()
        coordinator.refreshAll()
        await wait { await transport.count == 11 }
        await spin()
        check(await transport.count == 11 && credentials.readReferences.count == 11, "Manual fan-out honors Retry-After while refreshing another source once")
        check(credentials.readReferences.last == second.credentialReference, "Rate-limited credential is not read by manual fan-out")
        await transport.complete(await transport.latestIndex(forFixtureKey: "fixture-policy-second"), amount: "25")
        await wait { await MainActor.run { coordinator.statuses[second.id] == .ready } }
        clock.advance(599)
        coordinator.refreshAll(manual: false)
        await wait { await transport.count == 12 }
        await spin()
        check(await transport.count == 12 && credentials.readReferences.count == 12, "Automatic fan-out cannot bypass Retry-After before its boundary")
        check(credentials.readReferences.last == second.credentialReference && credentials.readInteractions.last == false, "Other source remains independently eligible during Retry-After")
        await transport.complete(await transport.latestIndex(forFixtureKey: "fixture-policy-second"), amount: "26")
        await wait { await MainActor.run { coordinator.statuses[second.id] == .ready } }
        clock.advance(1)
        coordinator.refreshAll()
        await wait { await transport.count == 14 }
        await transport.complete(await transport.latestIndex(forFixtureKey: "fixture-policy-first"), amount: "11")
        await transport.complete(await transport.latestIndex(forFixtureKey: "fixture-policy-second"), amount: "27")
        await wait { await MainActor.run { coordinator.statuses[first.id] == .ready && coordinator.statuses[second.id] == .ready } }
        check(coordinator.snapshots[first.id]?.buckets.first?.metric == .money(remaining: 11, currency: "USD"), "Manual retry succeeds exactly at the Retry-After boundary")

        credentials.authorizationRequired = [second.credentialReference]
        clock.advance(300)
        coordinator.refreshAll(manual: false)
        await wait { await transport.count == 15 }
        check(coordinator.statuses[second.id] == .stale(.credentialUnavailable), "Noninteractive credential failure is isolated to its source")
        check(Array(credentials.readInteractions.suffix(2)) == [false, false], "Automatic credential failure never escalates to interactive access")
        check(coordinator.snapshots[second.id]?.buckets.first?.metric == .money(remaining: 27, currency: "USD"), "Credential failure retains the previous snapshot")
        await transport.complete(await transport.latestIndex(forFixtureKey: "fixture-policy-first"), amount: "12")
        await wait { await MainActor.run { coordinator.statuses[first.id] == .ready } }
        let blockedReadCount = credentials.readReferences.count
        coordinator.refreshAll(manual: false)
        await spin()
        check(await transport.count == 15 && credentials.readReferences.count == blockedReadCount, "Automatic fan-out pauses authorization-blocked credential reads")
        coordinator.refreshAll()
        await wait { await transport.count == 17 }
        check(Array(credentials.readInteractions.suffix(2)) == [true, true], "Manual fan-out can authorize a previously blocked credential")
        await transport.complete(await transport.latestIndex(forFixtureKey: "fixture-policy-first"), amount: "13")
        await transport.complete(await transport.latestIndex(forFixtureKey: "fixture-policy-second"), amount: "28")
        await wait { await MainActor.run { coordinator.statuses[first.id] == .ready && coordinator.statuses[second.id] == .ready } }
        check(coordinator.snapshots[second.id]?.buckets.first?.metric == .money(remaining: 28, currency: "USD"), "Manual authorization recovers the affected source")
        check(coordinator.connections == [first, second], "Fan-out preserves connection identities and metadata")
        print("Refresh-all policies passed (cadence, authorization, backoff, Retry-After, isolated stale snapshots).")
    }

    @MainActor
    private static func testAutomaticBucketPrefersStandardDurations() async throws {
        let credentials = HarnessCredentials(), store = HarnessConnections(), clock = HarnessClock()
        let transport = HarnessTransport()
        let coordinator = ProviderUsageCoordinator(credentialStore: credentials, connectionStore: store,
            transport: transport, now: { clock.now() }, automaticTimers: false)
        try coordinator.saveConnection(kind: .miniMax, region: .china, name: "Window selection", key: "fixture-window-selection")
        let id = coordinator.connections[0].id
        @MainActor func publish(_ rows: [String]) async {
            let requestIndex = await transport.count + 1
            coordinator.refresh(id)
            await wait { await transport.count == requestIndex }
            await transport.completeJSON(requestIndex, json: "{\"model_remains\":[\(rows.joined(separator: ","))]}")
            await wait { await MainActor.run { coordinator.statuses[id] == .ready } }
        }
        let fiveHour = """
        {"model_name":"higher","current_interval_remaining_percent":81,
         "start_time":1800000000000,"end_time":1800018000000}
        """
        let week = """
        {"model_name":"lower","current_interval_remaining_percent":49.8,
         "start_time":1800000000000,"end_time":1800604800000}
        """
        let hour = """
        {"model_name":"hour","current_interval_remaining_percent":1,
         "start_time":1800000000000,"end_time":1800003600000}
        """
        let day = """
        {"model_name":"day","current_interval_remaining_percent":49.8,
         "start_time":1800000000000,"end_time":1800086400000}
        """

        await publish([fiveHour, week])
        check(coordinator.selectedBucket(for: id)?.id == "higher:interval", "Automatic selection prefers the five-hour 81% window over the weekly 49.8% window")
        check(coordinator.selectedBucket(for: id)?.metric == .percentage(remaining: 81), "Five-hour selection preserves its precise metric")
        await publish([week, fiveHour])
        check(coordinator.selectedBucket(for: id)?.id == "higher:interval", "Five-hour priority does not depend on server ordering or window names")
        coordinator.selectBucket("lower:interval", for: id)
        check(coordinator.selectedBucket(for: id)?.id == "lower:interval", "Explicit weekly selection overrides the five-hour default")
        check(coordinator.selectedBucket(for: id)?.metric == .percentage(remaining: 49.8), "Explicit weekly selection retains internal fractional precision")
        coordinator.selectBucket("missing:explicit", for: id)
        check(coordinator.selectedBucket(for: id) == nil, "Invalid explicit selection does not fall back to a standard window")
        coordinator.selectBucket(nil, for: id)
        await publish([hour, week])
        check(coordinator.selectedBucket(for: id)?.id == "lower:interval", "Weekly window wins over a lower nonstandard window when five-hour quota is absent")
        await publish([day, hour])
        check(coordinator.selectedBucket(for: id)?.id == "hour:interval", "Nonstandard windows still use the lowest remaining percentage")
        await publish([
            """
            {"model_name":"zeta","current_interval_remaining_percent":81,
             "start_time":1800000000000,"end_time":1800018000000}
            """,
            """
            {"model_name":"alpha","current_interval_remaining_percent":81,
             "start_time":1800000000000,"end_time":1800018000000}
            """,
            week
        ])
        check(coordinator.selectedBucket(for: id)?.id == "alpha:interval", "Equal-priority equal-percentage windows retain stable ID tie-breaking")
        await publish([
            "{\"model_name\":\"unavailable\",\"current_interval_status\":9}",
            "{\"model_name\":\"unlimited\",\"current_interval_status\":3}"
        ])
        check(coordinator.selectedBucket(for: id)?.metric == .unlimited, "Unlimited fallback still precedes unavailable metrics")

        try coordinator.saveConnection(kind: .deepSeek, region: .global, name: "Balance selection", key: "fixture-balance-selection")
        let balanceID = coordinator.connections[1].id
        let balanceRequest = await transport.count + 1
        coordinator.refresh(balanceID)
        await wait { await transport.count == balanceRequest }
        await transport.completeJSON(balanceRequest, json: """
        {"balance_infos":[{"currency":"USD","total_balance":"2"},
                          {"currency":"CNY","total_balance":"10"}]}
        """)
        await wait { await MainActor.run { coordinator.statuses[balanceID] == .ready } }
        check(coordinator.selectedBucket(for: balanceID)?.id == "balance:CNY", "Monetary fallback retains stable ID order instead of comparing amounts")
        check(coordinator.selectedBucket(for: balanceID)?.metric == .money(remaining: 10, currency: "CNY"), "Monetary selection preserves the unchanged balance")
        print("Automatic bucket selection passed (five-hour, weekly fallback, ordering, explicit choice, precision, money).")
    }

    private static func check(_ condition: Bool, _ message: String) { precondition(condition, message) }
    private static func wait(_ predicate: () async -> Bool) async {
        for _ in 0..<5_000 {
            if await predicate() { return }
            await Task.yield()
        }
        fatalError("Timed out waiting for a controlled harness event")
    }
    private static func spin() async { for _ in 0..<50 { await Task.yield() } }
}
