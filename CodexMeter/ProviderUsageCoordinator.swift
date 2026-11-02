import Combine
import Foundation

/// Coordinates independent external connections without participating in Codex authentication.
@MainActor
final class ProviderUsageCoordinator: ObservableObject {
    @Published private(set) var connections: [ProviderConnection] = []
    @Published private(set) var snapshots: [UUID: ProviderUsageSnapshot] = [:]
    @Published private(set) var statuses: [UUID: ProviderConnectionStatus] = [:]
    @Published private(set) var configurationError: ProviderUsageErrorCode?
    /// User-customized popover source order as stable order tokens; empty
    /// means the default Codex-first, store-order layout.
    @Published private(set) var overviewOrder: [String] = []
    /// Codex is an ordinary removable source: the flag controls whether its
    /// row is enrolled. The OAuth service itself keeps running either way.
    @Published private(set) var codexEnrolled = true
    /// Presentational Codex switch mirroring the per-connection overview
    /// toggles: hidden rows keep polling and stay listed in Settings.
    @Published private(set) var codexShowsInOverview = true

    /// Whether the popover overview should list the Codex source.
    var codexVisibleInOverview: Bool { codexEnrolled && codexShowsInOverview }
    @Published var selectedConnectionID: UUID? {
        didSet {
            if let id = selectedConnectionID, !connections.contains(where: { $0.id == id }) {
                selectedConnectionID = nil
                return
            }
            guard configurationReadable else { return }
            do { try connectionStore.saveSelectedConnectionID(selectedConnectionID) }
            catch { configurationError = .connectionStorage }
        }
    }

    private let credentialStore: any ProviderCredentialStoreProtocol
    private let connectionStore: any ProviderConnectionStoreProtocol
    private let transport: any ProviderUsageTransport
    private let now: @Sendable () -> Date
    private let automaticTimers: Bool
    /// Claude connections borrow the on-device Claude Code OAuth token
    /// instead of a CodexMeter-owned stored key.
    private let claudeCredentialReader: @MainActor (_ allowInteraction: Bool) throws -> String
    private var configurationReadable = true
    private var refreshStates: [UUID: ProviderRefreshState] = [:]
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var timer: Timer?
    private var lastClockPublication: Date?
    private var hasStarted = false
    private var retiringCredentialReferences: [String] = []

    init(
        credentialStore: (any ProviderCredentialStoreProtocol)? = nil,
        connectionStore: (any ProviderConnectionStoreProtocol)? = nil,
        transport: (any ProviderUsageTransport)? = nil,
        now: @escaping @Sendable () -> Date = { Date() },
        automaticTimers: Bool = true,
        claudeCredentialReader: (@MainActor (_ allowInteraction: Bool) throws -> String)? = nil
    ) {
        self.credentialStore = credentialStore ?? ProviderCredentialStore()
        self.connectionStore = connectionStore ?? ProviderConnectionStore()
        self.transport = transport ?? ProviderURLSessionTransport()
        self.now = now
        self.automaticTimers = automaticTimers
        self.claudeCredentialReader = claudeCredentialReader ?? { allowInteraction in
            try ClaudeCodeCredentialStore().readAccessToken(allowInteraction: allowInteraction)
        }
        var restoredConnections: [ProviderConnection] = []
        var restoredSelection: UUID?
        var restoredOverviewOrder: [String] = []
        var restoredCodexEnrolled = true
        var restoredCodexShowsInOverview = true
        do {
            restoredConnections = try self.connectionStore.loadConnections()
            retiringCredentialReferences = try self.connectionStore.loadRetiringCredentialReferences()
            let selected = self.connectionStore.loadSelectedConnectionID()
            restoredSelection = restoredConnections.contains(where: { $0.id == selected }) ? selected : nil
            restoredOverviewOrder = self.connectionStore.loadOverviewOrder() ?? []
            restoredCodexEnrolled = self.connectionStore.loadCodexEnrolled()
            restoredCodexShowsInOverview = self.connectionStore.loadCodexShowsInOverview()
        } catch {
            configurationReadable = false
            configurationError = .connectionStorage
        }
        // Assigning the wrapped value keeps didSet's persistence path from
        // overwriting the stored selection with nil during every launch.
        _selectedConnectionID = Published(initialValue: restoredSelection)
        connections = restoredConnections
        overviewOrder = restoredOverviewOrder
        codexEnrolled = restoredCodexEnrolled
        codexShowsInOverview = restoredCodexShowsInOverview
        for connection in restoredConnections where !connection.enabled {
            statuses[connection.id] = .unavailable(.disabled)
        }
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        if configurationReadable {
            do { try flushRetiredCredentials() }
            catch { configurationError = (error as? ProviderUsageErrorCode) ?? .credentialStorage }
        }
        poll()
        guard automaticTimers else { return }
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.poll() }
        }
        timer.tolerance = 5
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func setPopoverVisible(_ visible: Bool) {
        guard visible else { return }
        objectWillChange.send()
        poll()
    }

    /// The one-minute publication updates reset rings without an extra HTTP request.
    func poll() {
        let date = now()
        if lastClockPublication.map({ date.timeIntervalSince($0) >= 60 }) ?? true {
            lastClockPublication = date
            objectWillChange.send()
        }
        refreshAll(manual: false)
    }

    func refreshAll(manual: Bool = true) {
        for connection in connections where connection.enabled {
            refresh(connection.id, manual: manual)
        }
    }

    func refresh(_ id: UUID, manual: Bool = true) {
        guard let connection = connections.first(where: { $0.id == id }), connection.enabled else { return }
        var state = refreshStates[id] ?? ProviderRefreshState()
        guard let requestID = state.begin(at: now(), manual: manual) else { return }
        refreshStates[id] = state
        statuses[id] = .loading
        let key: String
        do {
            // Claude borrows the local Claude Code token on demand; every
            // other kind reads its CodexMeter-owned stored key.
            key = connection.kind == .claude
                ? try claudeCredentialReader(manual)
                : try credentialStore.read(reference: connection.credentialReference, allowInteraction: manual)
        }
        catch {
            let code = (error as? ProviderUsageErrorCode) ?? .credentialUnavailable
            completeFailure(ProviderUsageFailure(code: code), connection: connection, requestID: requestID)
            return
        }
        let transport = self.transport
        let clock = now
        tasks[id] = Task { [weak self] in
            do {
                let snapshot = try await ProviderUsageAdapter.fetch(connection: connection, key: key,
                                                                    transport: transport, now: clock)
                guard let self, self.owns(connection: connection, requestID: requestID) else { return }
                self.snapshots[id] = snapshot
                self.statuses[id] = .ready
                self.refreshStates[id]?.succeeded(at: snapshot.fetchedAt)
                self.tasks[id] = nil
            } catch is CancellationError {
                guard let self, self.owns(connection: connection, requestID: requestID) else { return }
                self.refreshStates[id]?.cancelled()
                self.tasks[id] = nil
                self.statuses[id] = self.snapshots[id] == nil ? .unavailable(.network) : .stale(.network)
            } catch {
                guard let self else { return }
                let failure = (error as? ProviderUsageFailure) ?? ProviderUsageFailure(code: .network)
                self.completeFailure(failure, connection: connection, requestID: requestID)
            }
        }
    }

    func saveConnection(
        id: UUID? = nil,
        kind: ProviderKind,
        region: ProviderRegion,
        name: String,
        key: String,
        enabled: Bool = true
    ) throws {
        guard configurationReadable else { throw ProviderUsageErrorCode.connectionStorage }
        let existing = id.flatMap { id in connections.first(where: { $0.id == id }) }
        guard id == nil || existing != nil else { throw ProviderUsageErrorCode.invalidConfiguration }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 80,
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw ProviderUsageErrorCode.invalidConfiguration
        }
        // A Claude connection carries no stored secret: it borrows the local
        // Claude Code token, so an empty key is valid for new connections.
        guard existing != nil || !key.isEmpty || kind == .claude else { throw ProviderUsageErrorCode.credentialMissing }
        // A different vendor must not receive the previous vendor's retained key.
        if let existing, existing.kind != kind, key.isEmpty { throw ProviderUsageErrorCode.credentialMissing }
        let newReference = !key.isEmpty ? UUID().uuidString : nil
        if let newReference {
            guard ProviderUsageAdapter.validCredential(key) else { throw ProviderUsageErrorCode.invalidConfiguration }
            // Journal the uncommitted reference so a crash cannot leave an untracked owned secret.
            try persistConnections(connections, retiring: retiringCredentialReferences + [newReference])
            do { try credentialStore.write(key, reference: newReference) }
            catch {
                try? flushRetiredCredentials()
                throw ProviderUsageErrorCode.credentialStorage
            }
        }
        let identityChanged = existing == nil || newReference != nil
            || existing?.region != region || existing?.kind != kind
        // A Claude connection stores no secret, but every connection still
        // needs the unique UUID reference the metadata store validates, so a
        // new secretless connection mints its own instead of force-unwrapping
        // an existing one that does not exist.
        let credentialReference = newReference ?? existing?.credentialReference ?? UUID().uuidString
        let connection = ProviderConnection(
            id: existing?.id ?? UUID(), kind: kind, region: region, name: name, enabled: enabled,
            credentialReference: credentialReference,
            identityEpoch: identityChanged ? UUID() : existing!.identityEpoch,
            selectedBucketID: existing?.selectedBucketID
        )
        var updated = connections.filter { $0.id != connection.id }
        if let index = connections.firstIndex(where: { $0.id == connection.id }) {
            updated.insert(connection, at: index)
        } else { updated.append(connection) }
        var retirements = retiringCredentialReferences.filter { $0 != newReference }
        if let oldReference = existing?.credentialReference, newReference != nil {
            retirements.append(oldReference)
        }
        do { try persistConnections(updated, retiring: retirements) }
        catch {
            try? flushRetiredCredentials()
            throw ProviderUsageErrorCode.connectionStorage
        }
        if identityChanged || existing?.enabled != enabled {
            invalidate(connection.id)
            snapshots[connection.id] = nil
            statuses[connection.id] = enabled ? nil : .unavailable(.disabled)
        }
        connections = updated
        configurationError = nil
        // Publish the new identity only after both secret creation and metadata persistence succeed.
        do { try flushRetiredCredentials() }
        catch {
            let code = (error as? ProviderUsageErrorCode) ?? .credentialStorage
            configurationError = code
            throw code
        }
        if hasStarted, enabled, identityChanged || existing?.enabled != enabled {
            refresh(connection.id, manual: false)
        }
    }

    func deleteConnection(_ id: UUID) throws {
        guard configurationReadable else { throw ProviderUsageErrorCode.connectionStorage }
        guard let connection = connections.first(where: { $0.id == id }) else { return }
        let updated = connections.filter { $0.id != id }
        do { try persistConnections(updated, retiring: retiringCredentialReferences + [connection.credentialReference]) }
        catch { throw ProviderUsageErrorCode.connectionStorage }
        invalidate(id)
        snapshots[id] = nil
        statuses[id] = nil
        connections = updated
        if selectedConnectionID == id { selectedConnectionID = nil }
        do { try flushRetiredCredentials() }
        catch {
            let code = (error as? ProviderUsageErrorCode) ?? .credentialStorage
            configurationError = code
            throw code
        }
    }

    func selectBucket(_ bucketID: String?, for id: UUID) {
        guard configurationReadable, let index = connections.firstIndex(where: { $0.id == id }),
              (bucketID?.utf8.count ?? 0) <= 256 else { return }
        var updated = connections
        updated[index].selectedBucketID = bucketID
        do { try connectionStore.saveConnections(updated); connections = updated }
        catch { configurationError = .connectionStorage }
    }

    /// Every renderable source in its default order. Codex joins only while
    /// enrolled, so both the settings list and reorder writes stay consistent.
    private var orderingCandidates: [PopoverOverviewSource] {
        (codexEnrolled ? [.codex] : []) + connections.map { .provider($0) }
    }

    var orderedOverviewSources: [PopoverOverviewSource] {
        PopoverOverviewSource.ordered(
            orderingCandidates,
            by: overviewOrder
        )
    }

    /// Keyboard and accessibility alternative to dragging the platform handle.
    func moveOverviewSource(_ id: PopoverOverviewSource.ID, up: Bool) {
        let ordered = orderedOverviewSources
        guard let index = ordered.firstIndex(where: { $0.id == id }),
              ordered.indices.contains(index + (up ? -1 : 1)) else { return }
        _ = moveOverviewSource(id, relativeTo: ordered[index + (up ? -1 : 1)].id, after: !up)
    }

    /// Commits only after a drop. Persist before publishing so failed writes
    /// preserve the old order in both settings and the popover.
    @discardableResult
    func moveOverviewSource(
        _ id: PopoverOverviewSource.ID,
        relativeTo target: PopoverOverviewSource.ID,
        after: Bool
    ) -> Bool {
        guard configurationReadable else {
            configurationError = .connectionStorage
            return false
        }
        guard let tokens = PopoverOverviewSource.moving(
            id, relativeTo: target, after: after,
            sources: orderingCandidates, order: overviewOrder
        ) else { return false }
        do {
            try connectionStore.saveOverviewOrder(tokens)
            overviewOrder = tokens
            return true
        } catch {
            configurationError = .connectionStorage
            return false
        }
    }

    /// Enrolls or removes the Codex source row. Persist before publishing so
    /// a failed write keeps the previous enrollment in both places.
    func setCodexEnrolled(_ enrolled: Bool) {
        guard configurationReadable else {
            configurationError = .connectionStorage
            return
        }
        do {
            try connectionStore.saveCodexEnrolled(enrolled)
            codexEnrolled = enrolled
        } catch { configurationError = .connectionStorage }
    }

    /// Toggles whether a connection appears in the popover overview. Purely
    /// presentational: polling, snapshots, and identity stay untouched, and
    /// the settings list keeps showing every added connection.
    func setShowsInOverview(_ visible: Bool, for id: UUID) {
        guard configurationReadable,
              let index = connections.firstIndex(where: { $0.id == id }) else { return }
        var updated = connections
        updated[index].showsInOverview = visible
        do {
            try persistConnections(updated, retiring: retiringCredentialReferences)
            connections = updated
        } catch { configurationError = .connectionStorage }
    }

    /// Codex's popover-visibility switch, mirroring the per-connection
    /// toggles. Persist before publishing so a failed write keeps the
    /// previous visibility.
    func setCodexShowsInOverview(_ visible: Bool) {
        guard configurationReadable else {
            configurationError = .connectionStorage
            return
        }
        do {
            try connectionStore.saveCodexShowsInOverview(visible)
            codexShowsInOverview = visible
        } catch { configurationError = .connectionStorage }
    }

    func selectedBucket(for id: UUID) -> ProviderUsageBucket? {
        guard let connection = connections.first(where: { $0.id == id }), let snapshot = snapshots[id] else { return nil }
        if let selected = connection.selectedBucketID {
            return snapshot.buckets.first(where: { $0.id == selected })
        }
        let percentageBuckets = snapshot.buckets.filter { $0.remainingPercent != nil }
        if !percentageBuckets.isEmpty {
            let standardDurations: [TimeInterval] = [5 * 3_600, 7 * 86_400]
            let preferredDuration = standardDurations.first { duration in
                percentageBuckets.contains { $0.windowDuration == duration }
            }
            let candidates = percentageBuckets.filter {
                preferredDuration == nil || $0.windowDuration == preferredDuration
            }
            return candidates.min {
                let left = $0.remainingPercent!, right = $1.remainingPercent!
                return left == right ? $0.id < $1.id : left < right
            }
        }
        return snapshot.buckets.filter { $0.metric != .unavailable }.sorted { $0.id < $1.id }.first
            ?? snapshot.buckets.sorted { $0.id < $1.id }.first
    }

    private func owns(connection: ProviderConnection, requestID: UUID) -> Bool {
        connections.contains {
            $0.id == connection.id && $0.enabled && $0.identityEpoch == connection.identityEpoch
                && $0.credentialReference == connection.credentialReference
        } && refreshStates[connection.id]?.owns(requestID) == true
    }

    private func invalidate(_ id: UUID) {
        tasks.removeValue(forKey: id)?.cancel()
        refreshStates[id] = nil
    }

    private func persistConnections(_ connections: [ProviderConnection], retiring: [String]) throws {
        let references = Array(Set(retiring)).sorted()
        do { try connectionStore.saveConnections(connections, retiringCredentialReferences: references) }
        catch { throw ProviderUsageErrorCode.connectionStorage }
        retiringCredentialReferences = references
    }

    private func flushRetiredCredentials() throws {
        guard !retiringCredentialReferences.isEmpty else { return }
        var failed: [String] = []
        for reference in retiringCredentialReferences {
            // Defense in depth: never retire a reference still belonging to an active connection.
            guard !connections.contains(where: { $0.credentialReference == reference }) else {
                throw ProviderUsageErrorCode.connectionStorage
            }
            do { try credentialStore.delete(reference: reference) }
            catch { failed.append(reference) }
        }
        try persistConnections(connections, retiring: failed)
        if !failed.isEmpty { throw ProviderUsageErrorCode.credentialStorage }
    }

    private func completeFailure(_ failure: ProviderUsageFailure, connection: ProviderConnection, requestID: UUID) {
        guard owns(connection: connection, requestID: requestID) else { return }
        let id = connection.id
        refreshStates[id]?.failed(at: now(), code: failure.code, retryAt: failure.retryAt)
        tasks[id] = nil
        switch failure.code {
        case .authentication: statuses[id] = .authRequired
        case .rateLimited:
            statuses[id] = .rateLimited(until: refreshStates[id]?.rateLimitUntil ?? now().addingTimeInterval(20))
        default:
            statuses[id] = snapshots[id] == nil ? .unavailable(failure.code) : .stale(failure.code)
        }
    }

    deinit {
        timer?.invalidate()
        for task in tasks.values { task.cancel() }
    }
}
