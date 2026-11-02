import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Opens the actual settings scene only for an explicit isolated Debug UI run.
struct ProviderFixtureSettingsLauncher: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Color.clear.frame(width: 0, height: 0).task {
            guard ProviderUIFixture.isEnabled,
                  CommandLine.arguments.contains("--provider-ui-fixture-settings") else { return }
            openWindow(id: CodexMeterWindowID.settings)
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
    }
}

extension ProviderKind {
    var localizedName: String { L10n.string("providers.kind.\(rawValue)") }
}

extension ProviderRegion {
    var localizedName: String { L10n.string("providers.region.\(rawValue)") }
}

enum ProviderUsagePresentation {
    static func title(_ bucket: ProviderUsageBucket) -> String {
        // A raw title that only repeats the window length (Zhipu's "300m") is
        // replaced by the localized duration. Any other title identifies the
        // window itself (MiniMax model names), so it stays beside the duration
        // instead of being swallowed by it; untimed buckets keep it verbatim.
        guard let duration = bucket.windowDuration, duration.isFinite,
              duration >= 60, duration < Double(Int.max) / 2 else { return bucket.title }
        let durationLabel = self.durationLabel(for: duration)
        guard !ProviderUsageTitleRule.rawTitleRepeatsDuration(bucket.title, windowDuration: duration) else {
            return durationLabel
        }
        return L10n.format("providers.window_title_format", bucket.title, durationLabel)
    }

    private static func durationLabel(for duration: TimeInterval) -> String {
        if duration.truncatingRemainder(dividingBy: 86_400) == 0 {
            return L10n.format("providers.window_days_format", Int(duration / 86_400))
        }
        if duration.truncatingRemainder(dividingBy: 3_600) == 0 {
            return L10n.format("providers.window_hours_format", Int(duration / 3_600))
        }
        return L10n.format("providers.window_minutes_format", Int(duration / 60))
    }

    static func value(_ bucket: ProviderUsageBucket) -> String {
        switch bucket.metric {
        case .money(let remaining, let currency):
            let formatter = NumberFormatter()
            formatter.locale = L10n.locale
            formatter.numberStyle = .currency
            formatter.currencyCode = currency
            formatter.minimumFractionDigits = 2
            formatter.maximumFractionDigits = 8
            return formatter.string(from: NSDecimalNumber(decimal: remaining))
                ?? "\(currency) \(NSDecimalNumber(decimal: remaining).stringValue)"
        case .percentage(let remaining):
            return percentage(remaining)
        case .count(let remaining, let unit):
            let unitLabel = ["requests", "tokens", "credits"].contains(unit)
                ? L10n.string("providers.unit.\(unit)") : unit
            return "\(L10n.formattedInteger(remaining)) \(unitLabel)"
        case .unlimited:
            return L10n.string("providers.unlimited")
        case .unavailable:
            return L10n.string("providers.unavailable")
        }
    }

    static func percentage(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.locale = L10n.locale
        formatter.numberStyle = .percent
        formatter.maximumFractionDigits = 0
        formatter.roundingMode = .halfUp
        return formatter.string(from: NSNumber(value: value / 100)) ?? "--"
    }

    static func boostDescription(_ bucket: ProviderUsageBucket) -> String? {
        guard let multiplier = bucket.quotaBoostMultiplier,
              let remaining = bucket.remainingPercent else { return nil }
        let formatter = NumberFormatter()
        formatter.locale = L10n.locale
        formatter.maximumFractionDigits = 3
        let factor = formatter.string(from: NSNumber(value: multiplier)) ?? String(multiplier)
        return L10n.format("providers.boost_format", factor, percentage(remaining))
    }

    /// `kind` is required so no call site can fall back to the key-based
    /// authentication wording for a connection that has no key to fix.
    static func status(_ status: ProviderConnectionStatus?, kind: ProviderKind) -> String {
        guard let status else { return L10n.string("providers.status.notQueried") }
        switch status {
        case .loading: return L10n.string("loading.usage")
        case .ready: return L10n.string("providers.status.ready")
        case .rateLimited(let until):
            return L10n.format("providers.retry_at_format", L10n.formattedTime(until))
        case .stale, .authRequired, .unavailable:
            return L10n.string(status.failureMessageKey(for: kind) ?? "providers.error.authentication")
        }
    }

    static func attention(_ bucket: ProviderUsageBucket, at date: Date) -> QuotaAttentionLevel {
        guard let remaining = bucket.remainingPercent else { return .normal }
        if remaining < 20 { return .critical }
        if let time = bucket.remainingTimePercent(at: date), remaining < time { return .warning }
        return .normal
    }
}

/// Amounts and counts have no meaningful quota ring without a confirmed total.
struct ProviderMenuBarLabel: View {
    @ObservedObject var providers: ProviderUsageCoordinator
    @ObservedObject var settings: AppSettings
    @State private var pricingDate = Date()

    private var connection: ProviderConnection? {
        providers.connections.first { $0.id == providers.selectedConnectionID }
    }

    var body: some View {
        if let connection, connection.kind == .deepSeek {
            // A TimelineView here can recurse through AppKit status-item sizing.
            deepSeekLabel(connection, at: pricingDate)
                .task(id: connection.id) {
                    pricingDate = Date()
                    while !Task.isCancelled {
                        let seconds = 60 - Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 60)
                        do {
                            try await Task.sleep(nanoseconds: UInt64(min(60, max(0.01, seconds)) * 1_000_000_000))
                        } catch { return }
                        guard !Task.isCancelled else { return }
                        pricingDate = Date()
                    }
                }
        } else if let connection, let bucket = providers.selectedBucket(for: connection.id),
           let remaining = bucket.remainingPercent {
            MenuBarProgressView(
                remainingPercent: Int(remaining.rounded()),
                remainingTimePercent: bucket.remainingTimePercent(at: Date()),
                title: ProviderUsagePresentation.percentage(remaining),
                style: settings.menuBarStyle,
                attentionLevel: ProviderUsagePresentation.attention(bucket, at: Date()),
                isStale: providers.statuses[connection.id]?.isStale ?? true,
                appearance: providerAppearance(connection),
                flashContext: "\(connection.id):\(connection.identityEpoch):\(bucket.id)"
            )
            .accessibilityLabel(accessibilityText(connection, bucket: bucket))
        } else {
            Image(nsImage: amountImage)
                .renderingMode(.original)
                .accessibilityLabel(amountAccessibilityText)
        }
    }

    private func deepSeekLabel(_ connection: ProviderConnection, at date: Date) -> some View {
        let pricing = DeepSeekPricingSchedule.snapshot(at: date)
        var appearance = settings.developerAppearance
        appearance.captionText = L10n.string(
            ProviderUIFixture.isEnabled ? "deepseek.menubar.preview_caption" : "deepseek.menubar.caption")
        let description = deepSeekAccessibilityText(connection, pricing: pricing)
        return MenuBarProgressView(
            remainingPercent: nil,
            remainingTimePercent: nil,
            title: deepSeekBalanceTitle(connection),
            style: .progressAndPercentage,
            attentionLevel: .normal,
            isStale: providers.statuses[connection.id]?.isStale ?? true,
            appearance: appearance,
            pricing: pricing,
            pricingDescription: description
        )
    }

    private func deepSeekBalanceTitle(_ connection: ProviderConnection) -> String {
        if let bucket = providers.selectedBucket(for: connection.id),
           case .money(let remaining, let currency) = bucket.metric {
            return DeepSeekMenuBarBalanceFormatter.string(remaining: remaining, currency: currency, locale: L10n.locale)
        }
        return L10n.string(providers.statuses[connection.id]?.isLoading == true
            ? "loading.usage" : "providers.unavailable")
    }

    private func deepSeekAccessibilityText(_ connection: ProviderConnection, pricing: DeepSeekPricingSnapshot) -> String {
        var parts = [
            connection.name,
            L10n.format("deepseek.menubar.balance_format", deepSeekBalanceTitle(connection)),
            pricing.phase.localizedTitle,
            L10n.format("deepseek.menubar.outer_wait_format", pricingWaitDescription(
                target: pricing.nextPeakAt, fraction: pricing.peakWaitFraction, at: pricing.calculatedAt)),
            L10n.format("deepseek.menubar.inner_wait_format", pricingWaitDescription(
                target: pricing.nextOffPeakAt, fraction: pricing.offPeakWaitFraction, at: pricing.calculatedAt)),
            L10n.string("deepseek.menubar.ring_help"),
            ProviderUsagePresentation.status(providers.statuses[connection.id], kind: connection.kind)
        ]
        if ProviderUIFixture.isEnabled { parts.insert(L10n.string("providers.preview"), at: 0) }
        if providers.statuses[connection.id]?.isStale ?? true { parts.append(L10n.string("data.stale")) }
        if pricing.peakWaitFraction == nil || pricing.offPeakWaitFraction == nil {
            parts.append(L10n.string("deepseek.pricing.calendar_unconfirmed"))
        }
        return parts.joined(separator: "\n")
    }

    private func pricingWaitDescription(target: Date?, fraction: Double?, at date: Date) -> String {
        guard let target else { return L10n.string("deepseek.pricing.time_unconfirmed") }
        let wait = L10n.format("deepseek.menubar.target_format",
                               L10n.remainingDuration(until: target, from: date), L10n.formattedDateTime(target))
        guard fraction != nil else { return "\(wait) · \(L10n.string("deepseek.pricing.progress_unconfirmed"))" }
        return wait
    }

    private func providerAppearance(_ connection: ProviderConnection) -> MenuBarAppearance {
        var appearance = settings.developerAppearance
        appearance.captionText = ProviderUIFixture.isEnabled ? L10n.string("providers.preview") : connection.kind.localizedName
        return appearance
    }

    private func accessibilityText(_ connection: ProviderConnection, bucket: ProviderUsageBucket) -> String {
        var parts = [connection.name, ProviderUsagePresentation.title(bucket), ProviderUsagePresentation.value(bucket)]
        if ProviderUIFixture.isEnabled { parts.insert(L10n.string("providers.preview"), at: 0) }
        if providers.statuses[connection.id]?.isStale == true { parts.append(L10n.string("data.stale")) }
        if let description = ProviderUsagePresentation.boostDescription(bucket) { parts.append(description) }
        return parts.joined(separator: ", ")
    }

    private var amountAccessibilityText: String {
        var parts = [connection?.name ?? "", amountTitle]
        if connection.map({ providers.statuses[$0.id]?.isStale ?? true }) ?? true {
            parts.append(L10n.string("data.stale"))
        }
        return parts.filter { !$0.isEmpty }.joined(separator: ", ")
    }

    private var amountTitle: String {
        guard let connection else { return L10n.string("providers.unavailable") }
        let value = providers.selectedBucket(for: connection.id).map { ProviderUsagePresentation.value($0) }
            ?? (providers.statuses[connection.id]?.isLoading == true ? "…" : "--")
        let prefix = ProviderUIFixture.isEnabled ? L10n.string("providers.preview") : connection.kind.localizedName
        return "\(prefix) \(value)"
    }

    private var amountImage: NSImage {
        let text = amountTitle
        let stale = connection.map { providers.statuses[$0.id]?.isStale ?? true } ?? true
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph
        ]
        let textSize = (text as NSString).size(withAttributes: attributes)
        let width = min(210, ceil(textSize.width) + 6)
        let image = NSImage(size: NSSize(width: width + (stale ? 7 : 0), height: 18), flipped: false) { rect in
            (text as NSString).draw(
                in: NSRect(x: 3, y: (18 - textSize.height) / 2, width: width - 6, height: textSize.height),
                withAttributes: attributes
            )
            if stale {
                NSColor.systemOrange.setFill()
                NSBezierPath(ovalIn: NSRect(x: rect.maxX - 5, y: 7, width: 4, height: 4)).fill()
            }
            return true
        }
        image.isTemplate = false
        return image
    }
}

struct ProviderUsageSection: View {
    let connection: ProviderConnection
    @ObservedObject var providers: ProviderUsageCoordinator
    @ObservedObject var settings: AppSettings
    @Environment(\.colorScheme) private var colorScheme

    private var snapshot: ProviderUsageSnapshot? { providers.snapshots[connection.id] }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let snapshot {
                if snapshot.buckets.count > 1 || connection.selectedBucketID != nil {
                    Picker(L10n.string("providers.menu_metric"), selection: Binding<String?>(
                        get: { connection.selectedBucketID },
                        set: { providers.selectBucket($0, for: connection.id) }
                    )) {
                        Text(L10n.string("providers.automatic")).tag(nil as String?)
                        ForEach(snapshot.buckets) { bucket in
                            Text(ProviderUsagePresentation.title(bucket)).tag(Optional(bucket.id))
                        }
                        if let selected = connection.selectedBucketID,
                           !snapshot.buckets.contains(where: { $0.id == selected }) {
                            Text(L10n.string("providers.selected_unavailable")).tag(Optional(selected))
                        }
                    }
                }
                TimelineView(.periodic(from: Date(), by: 60)) { context in
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(snapshot.buckets) { bucket in
                            if bucket.id != snapshot.buckets.first?.id { Divider() }
                            bucketRow(bucket, at: context.date)
                        }
                    }
                }
            }
            if connection.kind == .deepSeek {
                Divider()
                DeepSeekPricingPeriodsView(settings: settings)
            }
            Text(L10n.string("providers.query_only"))
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func bucketRow(_ bucket: ProviderUsageBucket, at date: Date) -> some View {
        Group {
            if let remaining = bucket.remainingPercent {
                QuotaWindowDetail(
                    title: ProviderUsagePresentation.title(bucket),
                    percentText: ProviderUsagePresentation.value(bucket),
                    boostText: ProviderUsagePresentation.boostDescription(bucket),
                    quota: remaining,
                    quotaTint: quotaTint(bucket, at: date),
                    time: bucket.remainingTimePercent(at: date),
                    timeTint: settings.developerAppearance.timeColor.swiftUIColor(for: colorScheme),
                    paceText: paceText(for: bucket, at: date),
                    resetText: resetText(for: bucket, at: date)
                )
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    if case .money = bucket.metric {
                        Text(L10n.string("providers.remaining_balance"))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    if let reset = resetText(for: bucket, at: date) {
                        Text(reset)
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func paceText(for bucket: ProviderUsageBucket, at date: Date) -> String? {
        guard let remaining = bucket.remainingPercent,
              let time = bucket.remainingTimePercent(at: date) else { return nil }
        return L10n.string(remaining < time ? "providers.over_pace" : "providers.on_pace")
    }

    private func resetText(for bucket: ProviderUsageBucket, at date: Date) -> String? {
        if let reset = bucket.resetsAt {
            return L10n.format("providers.resets_format", L10n.remainingDuration(until: reset, from: date))
        }
        return bucket.remainingPercent == nil ? nil : L10n.string("quota.reset_unavailable")
    }

    private func quotaTint(_ bucket: ProviderUsageBucket, at date: Date) -> Color {
        switch ProviderUsagePresentation.attention(bucket, at: date) {
        case .normal: settings.developerAppearance.normalColor.swiftUIColor(for: colorScheme)
        case .warning: settings.developerAppearance.warningColor.swiftUIColor(for: colorScheme)
        case .critical: settings.developerAppearance.criticalColor.swiftUIColor(for: colorScheme)
        }
    }
}

struct ProviderConnectionsView: View {
    @ObservedObject var providers: ProviderUsageCoordinator
    @ObservedObject var settings: AppSettings
    @ObservedObject var oauth: CodexOAuthUsageService
    private struct EditorTarget: Identifiable {
        let id = UUID()
        let connection: ProviderConnection?
    }
    @State private var editorTarget: EditorTarget?
    @State private var deletingID: UUID?
    @State private var errorMessage: String?
    @State private var orderDrag: PlatformOrderDrag?
    @State private var orderDropTarget: PlatformOrderDropTarget?

    var body: some View {
        Form {
            Section {
                if let error = providers.configurationError {
                    Label(L10n.string("providers.error.\(error.rawValue)"), systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
                Text(L10n.string("providers.privacy"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(L10n.string("providers.connections")) {
                Text(L10n.string("providers.reorder_hint"))
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(providers.orderedOverviewSources) { source in
                    HStack(alignment: .top, spacing: 10) {
                        reorderHandle(for: source)
                            .padding(.top, 8)
                        Group {
                            switch source {
                            case .codex:
                                CodexConnectionSettingsRow(
                                    oauth: oauth,
                                    providers: providers,
                                    settings: settings
                                ) { errorMessage = $0 }
                            case .provider(let connection):
                                connectionRow(connection)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .modifier(PlatformOrderDropModifier(
                        sourceID: source.id,
                        drag: orderDrag,
                        target: $orderDropTarget,
                        commit: commitOrderDrop
                    ))
                }
                if !providers.codexEnrolled {
                    Button {
                        providers.setCodexEnrolled(true)
                    } label: {
                        Label(L10n.string("providers.add_codex"), systemImage: "plus")
                    }
                }
                Button(L10n.string("providers.add")) {
                    editorTarget = EditorTarget(connection: nil)
                }
            }
        }
        .formStyle(.grouped)
        .onDisappear { orderDrag = nil; orderDropTarget = nil }
        .sheet(item: $editorTarget) { target in
            ProviderConnectionEditor(providers: providers, connection: target.connection)
        }
        .confirmationDialog(L10n.string("providers.delete_title"), isPresented: Binding(
            get: { deletingID != nil }, set: { if !$0 { deletingID = nil } }
        )) {
            Button(L10n.string("providers.delete"), role: .destructive) {
                guard let id = deletingID else { return }
                do { try providers.deleteConnection(id) }
                catch let error as ProviderUsageErrorCode {
                    errorMessage = L10n.string("providers.error.\(error.rawValue)")
                }
                catch { errorMessage = L10n.string("providers.error.credentialStorage") }
                deletingID = nil
            }
            Button(L10n.string("action.cancel"), role: .cancel) { deletingID = nil }
        } message: { Text(L10n.string("providers.delete_message")) }
        .alert(L10n.string("settings.error_title"), isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
        )) {
            Button(L10n.string("action.ok")) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    private func connectionRow(_ connection: ProviderConnection) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(connection.enabled ? connection.name : L10n.format("settings.popover.order_disabled_format", connection.name)).font(.headline)
                    Text("\(connection.kind.localizedName) · \(connection.region.localizedName)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle(L10n.string("providers.overview_show"), isOn: Binding(
                    get: { connection.isShownInOverview },
                    set: { providers.setShowsInOverview($0, for: connection.id) }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
                .help(L10n.string("providers.overview_show_help"))
                Button(L10n.string("action.refresh")) { providers.refresh(connection.id) }
                    .disabled(!connection.enabled || providers.statuses[connection.id]?.isLoading == true)
                Button(L10n.string("providers.edit")) {
                    editorTarget = EditorTarget(connection: connection)
                }
                Button(role: .destructive) { deletingID = connection.id } label: {
                    Image(systemName: "trash")
                }
                .help(L10n.string("providers.delete"))
            }
            Text(ProviderUsagePresentation.status(providers.statuses[connection.id], kind: connection.kind))
                .font(.caption).foregroundStyle(.secondary)
            if let snapshot = providers.snapshots[connection.id] {
                Text(L10n.format("status.updated_at_format", L10n.formattedDateTime(snapshot.fetchedAt)))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if ProviderUIFixture.isEnabled && connection.kind == .deepSeek {
                Label(L10n.string("providers.preview"), systemImage: "eye.trianglebadge.exclamationmark")
                    .font(.caption).foregroundStyle(.orange)
                DeepSeekPricingPeriodsView(settings: settings)
            }
        }
        .padding(.vertical, 4)

    }

    private func sourceTitle(_ source: PopoverOverviewSource) -> String {
        switch source {
        case .codex: L10n.string("oauth.source_title")
        case .provider(let connection): connection.enabled ? connection.name
            : L10n.format("settings.popover.order_disabled_format", connection.name)
        }
    }

    private func reorderHandle(for source: PopoverOverviewSource) -> some View {
        let ordered = providers.orderedOverviewSources
        let index = ordered.firstIndex(where: { $0.id == source.id }) ?? 0
        return Image(systemName: "line.3.horizontal")
            .font(.body).foregroundStyle(.secondary)
            .frame(width: 24, height: 24)
            .contentShape(Rectangle())
            .help(L10n.string("providers.reorder_hint"))
            .focusable()
            .onMoveCommand { direction in
                if direction == .up { providers.moveOverviewSource(source.id, up: true) }
                if direction == .down { providers.moveOverviewSource(source.id, up: false) }
            }
            .accessibilityLabel(L10n.format("providers.reorder_handle_format", sourceTitle(source)))
            .accessibilityHint(L10n.string("providers.reorder_hint"))
            .accessibilityAction(named: Text(L10n.string("settings.popover.move_up"))) {
                providers.moveOverviewSource(source.id, up: true)
            }
            .accessibilityAction(named: Text(L10n.string("settings.popover.move_down"))) {
                providers.moveOverviewSource(source.id, up: false)
            }
            .contextMenu {
                Button(L10n.string("settings.popover.move_up")) {
                    providers.moveOverviewSource(source.id, up: true)
                }.disabled(index == 0)
                Button(L10n.string("settings.popover.move_down")) {
                    providers.moveOverviewSource(source.id, up: false)
                }.disabled(index == ordered.count - 1)
            }
            // Keyboard moves keep working while focused; only the prominent
            // focus rectangle is suppressed so the handle never reads as a
            // selection.
            .modifier(SuppressedFocusEffect())
            .onDrag {
                let drag = PlatformOrderDrag(sourceID: source.id)
                orderDrag = drag
                orderDropTarget = nil
                let provider = NSItemProvider()
                // Standard text lets the system drag broker discover the item. Only an
                // ephemeral nonce is exported; the live local session must still match.
                provider.registerDataRepresentation(forTypeIdentifier: PlatformOrderDrag.type.identifier, visibility: .all) { completion in
                    completion(Data(drag.nonce.utf8), nil)
                    return nil
                }
                return provider
            } preview: {
                Label(sourceTitle(source), systemImage: "line.3.horizontal")
                    .padding(8)
            }
    }

    private func commitOrderDrop(
        _ drag: PlatformOrderDrag,
        _ target: PlatformOrderDropTarget,
        _ provider: NSItemProvider
    ) {
        orderDropTarget = nil
        provider.loadDataRepresentation(forTypeIdentifier: PlatformOrderDrag.type.identifier) { data, _ in
            // A canceled/replaced drag, foreign payload, or deleted identity cannot reorder rows.
            Task { @MainActor in
                guard orderDrag == drag else { return }
                orderDrag = nil
                guard data == Data(drag.nonce.utf8) else { return }
                providers.moveOverviewSource(drag.sourceID, relativeTo: target.id, after: target.after)
            }
        }
    }

}

private struct PlatformOrderDrag: Equatable {
    static let type = UTType.utf8PlainText
    let sourceID: PopoverOverviewSource.ID
    let nonce = UUID().uuidString
}

/// Keeps a view focusable without drawing the system focus rectangle, so
/// keyboard-only reordering stays available without the handle reading as a
/// selection.
private struct SuppressedFocusEffect: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 14.0, *) {
            content.focusEffectDisabled()
        } else {
            content
        }
    }
}

private struct PlatformOrderDropTarget: Equatable {
    let id: PopoverOverviewSource.ID
    let after: Bool
}

private struct PlatformOrderDropModifier: ViewModifier {
    let sourceID: PopoverOverviewSource.ID
    let drag: PlatformOrderDrag?
    @Binding var target: PlatformOrderDropTarget?
    let commit: (PlatformOrderDrag, PlatformOrderDropTarget, NSItemProvider) -> Void
    @State private var rowHeight: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .background(GeometryReader { geometry in
                Color.clear
                    .onAppear { rowHeight = geometry.size.height }
                    .onChange(of: geometry.size.height) { rowHeight = $0 }
            })
            .overlay(alignment: target?.after == true ? .bottom : .top) {
                if target?.id == sourceID {
                    Rectangle().fill(Color.accentColor).frame(height: 3)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
            .onDrop(of: [PlatformOrderDrag.type], delegate: PlatformOrderDropDelegate(
                id: sourceID, height: rowHeight, drag: drag, target: $target, commit: commit
            ))
    }
}

private struct PlatformOrderDropDelegate: DropDelegate {
    let id: PopoverOverviewSource.ID
    let height: CGFloat
    let drag: PlatformOrderDrag?
    @Binding var target: PlatformOrderDropTarget?
    let commit: (PlatformOrderDrag, PlatformOrderDropTarget, NSItemProvider) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        drag != nil && drag?.sourceID != id
            && info.hasItemsConforming(to: [PlatformOrderDrag.type])
    }

    func dropEntered(info: DropInfo) {
        guard validateDrop(info: info) else { return }
        target = destination(info)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard validateDrop(info: info) else { return DropProposal(operation: .forbidden) }
        target = destination(info)
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        if target?.id == id { target = nil }
    }

    func performDrop(info: DropInfo) -> Bool {
        guard validateDrop(info: info), let drag else { return false }
        let items = info.itemProviders(for: [PlatformOrderDrag.type])
        guard items.count == 1, let provider = items.first else { return false }
        commit(drag, destination(info), provider)
        return true
    }

    private func destination(_ info: DropInfo) -> PlatformOrderDropTarget {
        PlatformOrderDropTarget(id: id, after: info.location.y >= height / 2)
    }
}

/// Keeps platform-specific authentication and display preferences in one connection row.
private struct CodexConnectionSettingsRow: View {
    @ObservedObject var oauth: CodexOAuthUsageService
    @ObservedObject var providers: ProviderUsageCoordinator
    @ObservedObject var settings: AppSettings
    var onError: (String?) -> Void
    @State private var showsExpiryDraft = false
    @State private var expiryDraftDate = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L10n.string("oauth.source_title")).font(.headline)
                Spacer()
                Toggle(L10n.string("providers.overview_show"), isOn: Binding(
                    get: { providers.codexShowsInOverview },
                    set: { providers.setCodexShowsInOverview($0) }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
                .help(L10n.string("providers.overview_show_help"))
                Button(L10n.string("action.refresh")) { oauth.refresh(reauthorizing: true) }
                    .disabled(oauth.isBusy)
                // Codex is an ordinary removable source. Removal is offered only
                // once no credential remains, so it never deletes account data.
                if !oauth.isConnected && oauth.deviceCode == nil {
                    Button(role: .destructive) {
                        providers.setCodexEnrolled(false)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .help(L10n.string("providers.remove_codex_help"))
                    .accessibilityLabel(L10n.string("providers.remove_codex"))
                }
            }
            OAuthAccountRow(oauth: oauth, onError: onError)
            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.string("settings.codex_expiration"))
                    .font(.subheadline)
                codexExpirationRow
                Text(L10n.string("settings.codex_expiration_hint"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var codexExpirationRow: some View {
        if let expiration = settings.codexSubscriptionExpiration {
            HStack {
                DatePicker(
                    L10n.string("settings.codex_expiration"),
                    selection: Binding(
                        get: { settings.codexSubscriptionExpiration ?? expiration },
                        set: { settings.codexSubscriptionExpiration = $0 }
                    ),
                    displayedComponents: [.date]
                )
                .labelsHidden()
                Spacer()
                Button(L10n.string("settings.codex_expiration_clear"), role: .destructive) {
                    settings.codexSubscriptionExpiration = nil
                }
            }
        } else if showsExpiryDraft {
            // Revealing the picker must not persist anything: the date is a
            // local draft until the explicit save action commits it, so
            // opening the editor never claims the plan expires today.
            HStack {
                DatePicker(
                    L10n.string("settings.codex_expiration"),
                    selection: $expiryDraftDate,
                    displayedComponents: [.date]
                )
                .labelsHidden()
                Spacer()
                Button(L10n.string("action.save")) {
                    settings.codexSubscriptionExpiration = Calendar.current.startOfDay(for: expiryDraftDate)
                    showsExpiryDraft = false
                }
                Button(L10n.string("action.cancel")) {
                    showsExpiryDraft = false
                }
            }
        } else {
            Button(L10n.string("settings.codex_expiration_set")) {
                expiryDraftDate = Calendar.current.startOfDay(for: Date())
                showsExpiryDraft = true
            }
        }
    }
}

/// Account controls for the direct Codex sign-in source.
private struct OAuthAccountRow: View {
    @ObservedObject var oauth: CodexOAuthUsageService
    var onError: (String?) -> Void

    var body: some View {
        if let code = oauth.deviceCode {
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.string("oauth.login_pending"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(L10n.format("oauth.user_code_format", code.userCode))
                    .font(.title3.monospaced())
                    .textSelection(.enabled)
                HStack {
                    Button(L10n.string("oauth.open_browser")) {
                        NSWorkspace.shared.open(code.verificationURL)
                    }
                    Button(L10n.string("oauth.cancel_login")) { oauth.cancelLogin() }
                }
            }
            .padding(.vertical, 4)
        } else if oauth.isConnected {
            HStack {
                Label(L10n.string("oauth.connected"), systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Spacer()
                Button(L10n.string("oauth.disconnect"), role: .destructive) {
                    do { try oauth.disconnect() } catch { onError(L10n.string("oauth.storage_error")) }
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                if let message = oauth.errorMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Text(L10n.string("oauth.experimental_notice"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button(L10n.string("oauth.login")) { oauth.beginLogin() }
                    .disabled(oauth.isBusy)
            }
            .padding(.vertical, 4)
        }
    }
}

private struct ProviderConnectionEditor: View {
    @ObservedObject var providers: ProviderUsageCoordinator
    let connection: ProviderConnection?
    @Environment(\.dismiss) private var dismiss
    @State private var kind: ProviderKind
    @State private var region: ProviderRegion
    @State private var name: String
    @State private var key = ""
    @State private var enabled: Bool
    @State private var errorMessage: String?

    init(providers: ProviderUsageCoordinator, connection: ProviderConnection?) {
        self.providers = providers
        self.connection = connection
        let initialKind = connection?.kind ?? .deepSeek
        _kind = State(initialValue: initialKind)
        _region = State(initialValue: connection?.region ?? (initialKind == .zhipu ? .china : .global))
        _name = State(initialValue: connection?.name ?? "")
        _enabled = State(initialValue: connection?.enabled ?? true)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.string(connection == nil ? "providers.add" : "providers.edit"))
                .font(.headline)
            Form {
                Picker(L10n.string("providers.platform"), selection: $kind) {
                    ForEach(ProviderKind.allCases) { Text($0.localizedName).tag($0) }
                }.disabled(connection != nil)
                if kind == .miniMax {
                    Picker(L10n.string("providers.region"), selection: $region) {
                        ForEach(ProviderRegion.allCases) { Text($0.localizedName).tag($0) }
                    }
                    Text(L10n.string("providers.experimental")).font(.caption).foregroundStyle(.orange)
                    Text(L10n.string("providers.minimax_key_help")).font(.caption).foregroundStyle(.secondary)
                }
                if kind == .zhipu {
                    Text(L10n.string("providers.zhipu_key_help")).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if kind == .claude {
                    Text(L10n.string("providers.experimental")).font(.caption).foregroundStyle(.orange)
                    Text(L10n.string("providers.claude_key_help")).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                TextField(L10n.string("providers.name"), text: $name)
                if kind != .claude {
                    SecureField(L10n.string(credentialLabelKey), text: $key)
                        .textContentType(.password)
                }
                Toggle(L10n.string("providers.enabled"), isOn: $enabled)
            }
            Text(L10n.string("providers.privacy")).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button(L10n.string("action.cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L10n.string("providers.save_query")) {
                    do {
                        try providers.saveConnection(
                            id: connection?.id, kind: kind,
                            region: kind == .deepSeek || kind == .claude ? .global
                                : kind == .zhipu ? .china : region,
                            name: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                ? kind.localizedName : name,
                            key: key, enabled: enabled
                        )
                        key = ""
                        dismiss()
                    } catch let error as ProviderUsageErrorCode {
                        errorMessage = L10n.string("providers.error.\(error.rawValue)")
                    } catch {
                        errorMessage = L10n.string("providers.error.credentialStorage")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(connection == nil && kind != .claude
                    && key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 470)
        .onDisappear { key = "" }
    }

    private var credentialLabelKey: String {
        if kind == .zhipu {
            return connection == nil ? "providers.session_credential" : "providers.replace_session_credential"
        }
        return connection == nil ? "providers.api_key" : "providers.replace_key"
    }
}
