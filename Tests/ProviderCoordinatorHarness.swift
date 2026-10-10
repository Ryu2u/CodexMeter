// Compile this isolated harness with the five provider source files; it never accesses real credentials or APIs.
import Combine
import Foundation

@MainActor
private final class HarnessCredentials: ProviderCredentialStoreProtocol {
    var values: [String: String] = [:]
    var failWrite = false
    var failDeletes: Set<String> = []
    var readInteractions: [Bool] = []
    var onDelete: ((String) -> Void)?
    func read(reference: String, allowInteraction: Bool) throws -> String {
        readInteractions.append(allowInteraction)
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
    func loadConnections() throws -> [ProviderConnection] { values }
    func saveConnections(_ connections: [ProviderConnection]) throws {
        guard !failWrite else { throw ProviderUsageErrorCode.connectionStorage }
        values = connections
    }
    func loadSelectedConnectionID() -> UUID? { selected }
    func saveSelectedConnectionID(_ id: UUID?) throws { selected = id }
    func loadRetiringCredentialReferences() throws -> [String] { retiring }
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
        print("Provider coordinator isolated harness passed (fake credentials and HTTP only).")
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
