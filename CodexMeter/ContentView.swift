import AppKit
import SwiftUI

private struct ScrollOnlyPopoverIndicators: ViewModifier {
    @State private var hasScrolled = false

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content
                .scrollIndicators(hasScrolled ? .automatic : .hidden)
                .onScrollPhaseChange { _, phase in
                    // Once scrolling begins, let AppKit own its normal fade-out.
                    if phase == .interacting || phase == .decelerating {
                        hasScrolled = true
                    }
                }
                .onAppear { hasScrolled = false }
                .onDisappear { hasScrolled = false }
        } else {
            content
        }
    }
}

struct ContentView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var providers: ProviderUsageCoordinator
    @ObservedObject var oauth: CodexOAuthUsageService
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openWindow) private var openWindow
    @State private var maximumPopoverHeight = PopoverLayoutMetrics.initialMaximumHeight
    @State private var expandedSources: Set<PopoverOverviewSource.ID> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
                .layoutPriority(1)

            ScrollView {
                scrollableContent
                    .padding(.trailing, 12)
            }
            .modifier(ScrollOnlyPopoverIndicators())
            .clipped()
            .padding(.trailing, -12)

            bottomControls
                .layoutPriority(1)
        }
        .padding(16)
        .frame(width: 380)
        .frame(maxHeight: maximumPopoverHeight)
        .fixedSize(horizontal: false, vertical: true)
        .background {
            PopoverScreenHeightReader { visibleHeight in
                let updatedHeight = PopoverLayoutMetrics.maximumHeight(
                    forScreenVisibleHeight: visibleHeight
                )
                guard abs(maximumPopoverHeight - updatedHeight) > 0.5 else { return }
                maximumPopoverHeight = updatedHeight
            }
        }
        .onAppear {
            if !settings.developerPreviewEnabled {
                providers.setPopoverVisible(true)
                oauth.setPopoverVisible(true)
            }
            settings.refreshLaunchAtLoginStatus()
        }
        .onChange(of: settings.developerPreviewEnabled) { isPreview in
            providers.setPopoverVisible(!isPreview)
            oauth.setPopoverVisible(!isPreview)
        }
        .onDisappear {
            providers.setPopoverVisible(false)
            oauth.setPopoverVisible(false)
        }
        .alert(
            L10n.string("settings.error_title"),
            isPresented: Binding(
                get: { settings.settingsError != nil },
                set: { if !$0 { settings.clearSettingsError() } }
            )
        ) {
            Button(L10n.string("action.ok")) {
                settings.clearSettingsError()
            }

            if settings.settingsDestination != nil {
                Button(L10n.string("action.open_system_settings")) {
                    settings.openRelevantSystemSettings()
                    settings.clearSettingsError()
                }
            }
        } message: {
            Text(settings.settingsError ?? "")
        }
    }

    private var overviewSources: [PopoverOverviewSource] {
        PopoverOverviewSource.ordered(
            PopoverOverviewSource.visibleSources(
                from: providers.connections,
                developerPreviewEnabled: settings.developerPreviewEnabled,
                codexVisible: providers.codexVisibleInOverview
            ),
            by: providers.overviewOrder
        )
    }

    private var scrollableContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            if settings.developerPreviewEnabled {
                previewModeBanner
            }

            if overviewSources.isEmpty {
                emptyOverview
            } else {
                ForEach(overviewSources) { source in
                    Divider()
                    switch source {
                    case .codex:
                        if settings.developerPreviewEnabled {
                            DeveloperQuotaOverviewSection(
                                settings: settings,
                                isExpanded: expansion(for: source.id)
                            )
                        } else {
                            codexOverview
                        }
                    case .provider(let connection):
                        ProviderOverviewSection(
                            connection: connection,
                            providers: providers,
                            settings: settings,
                            isExpanded: expansion(for: source.id)
                        )
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The shell with no enrolled sources still needs one clear way forward.
    private var emptyOverview: some View {
        VStack(spacing: 10) {
            Image(systemName: "square.grid.2x2")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text(L10n.string("overview.empty_title"))
                .font(.subheadline.weight(.semibold))
            Text(L10n.string("overview.empty_hint"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button(L10n.string("overview.empty_action")) {
                openWindow(id: CodexMeterWindowID.settings)
                NSApplication.shared.activate(ignoringOtherApps: true)
            }
            .buttonStyle(.link)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    private func expansion(for id: PopoverOverviewSource.ID) -> Binding<Bool> {
        Binding(
            get: { expandedSources.contains(id) },
            set: { isExpanded in
                if isExpanded {
                    expandedSources.insert(id)
                } else {
                    expandedSources.remove(id)
                }
            }
        )
    }

    private var bottomControls: some View {
        VStack(alignment: .leading, spacing: 14) {
            Divider()
            SettingsSection()
            Divider()
            footer
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(L10n.string("app.title"))
                    .font(.headline)

                Spacer()

                if isRefreshInFlight {
                    ProgressView()
                        .controlSize(.small)
                }

                Button {
                    guard !settings.developerPreviewEnabled else { return }
                    oauth.refresh(reauthorizing: true)
                    providers.refreshAll()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .help(L10n.string("action.refresh_all"))
                .accessibilityLabel(L10n.string("action.refresh_all"))
                .disabled(settings.developerPreviewEnabled)
            }
            if showsSourcePicker {
                Picker(L10n.string("providers.menu_bar_source"), selection: sourceSelection) {
                    // With Codex removed the nil entry is an explicit "none"
                    // instead of the built-in Codex source.
                    if providers.codexEnrolled {
                        Text(L10n.string("oauth.source_title")).tag(nil as String?)
                    } else {
                        Text(L10n.string("providers.menu_bar_none")).tag(nil as String?)
                    }
                    ForEach(providers.connections) { connection in
                        Text(connection.name).tag(Optional(connection.id.uuidString))
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .accessibilityLabel(L10n.string("providers.menu_bar_source"))
                .help(L10n.string("providers.menu_bar_source_help"))
                .disabled(settings.developerPreviewEnabled)
            }
        }
    }

    private var showsSourcePicker: Bool {
        !settings.developerPreviewEnabled && !providers.connections.isEmpty
    }

    private var sourceSelection: Binding<String?> {
        Binding(
            get: {
                guard !settings.developerPreviewEnabled else { return nil }
                return providers.selectedConnectionID?.uuidString
            },
            set: { value in
                guard !settings.developerPreviewEnabled else { return }
                providers.selectedConnectionID = value.flatMap(UUID.init(uuidString:))
            }
        )
    }

    private var isRefreshInFlight: Bool {
        guard !settings.developerPreviewEnabled else { return false }
        return oauth.isBusy || providers.connections.contains {
            $0.enabled && providers.statuses[$0.id]?.isLoading == true
        }
    }

    private var previewModeBanner: some View {
        HStack(spacing: 8) {
            Label(
                L10n.string("developer.preview_mode_active"),
                systemImage: "eye.trianglebadge.exclamationmark"
            )
            .font(.caption)
            .foregroundStyle(.orange)

            Spacer()

            Button(L10n.string("developer.return_to_live")) {
                settings.developerPreviewEnabled = false
            }
            .buttonStyle(.plain)
            .font(.caption)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
    }

    private var visibleOAuthWindows: [CodexUsageWindow] {
        settings.popoverContent.visibleQuotaWindows(from: oauth.windows)
    }

    private var codexOverview: some View {
        PlatformOverviewSection(
            title: L10n.string("oauth.source_title"),
            isExpanded: expansion(for: .codex)
        ) {
            codexStatus
        } summary: {
            if !oauth.windows.isEmpty && visibleOAuthWindows.isEmpty {
                hiddenWindowsMessage
            } else {
                // The collapsed summary keeps every ring the expanded view
                // has (quota plus reset time per window) so nothing needs
                // expanding just to read the gauges; countdowns stay fresh.
                TimelineView(.periodic(from: Date(), by: 60)) { context in
                    OverviewRingRow {
                        ForEach(visibleOAuthWindows) { window in
                            WindowRingItem(
                                label: WindowRingLabels.quota(window.name),
                                value: Double(window.remainingPercent),
                                tint: quotaAttentionTint(
                                    window.attentionLevel(at: context.date),
                                    appearance: settings.developerAppearance,
                                    colorScheme: colorScheme
                                )
                            )
                            WindowRingItem(
                                label: WindowRingLabels.reset(window.name),
                                value: window.remainingTimePercent(at: context.date),
                                tint: settings.developerAppearance.timeColor.swiftUIColor(for: colorScheme)
                            )
                        }
                    }
                }
            }
        } detail: {
            oauthSection
        }
    }

    private var codexStatus: some View {
        VStack(alignment: .leading, spacing: 5) {
            if ProviderUIFixture.isEnabled {
                Label(L10n.string("oauth.fixture_disabled"), systemImage: "eye.trianglebadge.exclamationmark")
                    .foregroundStyle(.orange)
            } else {
                if let planType = oauth.planType {
                    Text(L10n.format("account.chatgpt_format", planType.capitalized))
                        .foregroundStyle(.secondary)
                }
                if let expiration = settings.codexSubscriptionExpiration {
                    codexExpirationRow(expiration)
                }
                if oauth.deviceCode != nil {
                    Label(L10n.string("oauth.login_pending"), systemImage: "globe")
                        .foregroundStyle(.secondary)
                } else if !oauth.isConnected {
                    Text(L10n.string("oauth.login_required"))
                        .foregroundStyle(.secondary)
                }
                if oauth.isBusy {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(L10n.string("loading.usage"))
                    }
                    .foregroundStyle(.secondary)
                }
                if let message = oauth.errorMessage {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
                if oauth.isStale {
                    Label(L10n.string("data.stale"), systemImage: "clock.badge.exclamationmark")
                        .foregroundStyle(.orange)
                }
                if oauth.isConnected && !oauth.isBusy && oauth.errorMessage == nil && !oauth.isStale {
                    Text(L10n.string(oauth.windows.isEmpty ? "providers.status.notQueried" : "providers.status.ready"))
                        .foregroundStyle(.secondary)
                }
                if let updated = oauth.lastUpdated {
                    OverviewUpdatedAt(date: updated)
                }
            }
        }
        .font(.caption)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var hiddenWindowsMessage: some View {
        Text(L10n.string("quota.windows_hidden"))
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func codexExpirationRow(_ expiration: Date) -> some View {
        // Keep the countdown fresh without reopening the popover.
        TimelineView(.periodic(from: Date(), by: 60)) { context in
            Text(codexExpirationSummary(expiration, now: context.date))
                .foregroundStyle(
                    CodexSubscriptionExpiry.daysRemaining(until: expiration, now: context.date) < 0
                        ? Color.orange
                        : Color.secondary
                )
        }
        .font(.caption)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func codexExpirationSummary(_ expiration: Date, now: Date) -> String {
        let days = CodexSubscriptionExpiry.daysRemaining(until: expiration, now: now)
        let countdown: String
        switch days {
        case ..<0: countdown = L10n.string("oauth.expiration_expired")
        case 0: countdown = L10n.string("oauth.expiration_today")
        default: countdown = L10n.format("oauth.expiration_days_remaining_format", days)
        }
        return L10n.format("oauth.expiration_summary_format", L10n.formattedDate(expiration), countdown)
    }

    @ViewBuilder
    private var oauthSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let code = oauth.deviceCode {
                oauthPendingView(code)
            } else if !oauth.isConnected {
                oauthSignInPrompt
            } else if oauth.windows.isEmpty {
                if oauth.errorMessage != nil {
                    Button(L10n.string("action.retry")) {
                        oauth.refresh(reauthorizing: true)
                    }
                    .disabled(oauth.isBusy)
                }
            } else if visibleOAuthWindows.isEmpty {
                hiddenWindowsMessage
            } else {
                oauthQuotaList
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var oauthQuotaList: some View {
        let windows = visibleOAuthWindows
        // Update countdowns and pace locally every minute without another request.
        return TimelineView(.periodic(from: Date(), by: 60)) { context in
            UsageWindowsDetail(windows: windows, now: context.date, appearance: settings.developerAppearance)
        }
    }

    private func oauthPendingView(_ code: CodexOAuthDeviceCode) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.format("oauth.user_code_format", code.userCode))
                .font(.title3.monospaced())
                .textSelection(.enabled)

            HStack {
                Button(L10n.string("oauth.open_browser")) {
                    NSWorkspace.shared.open(code.verificationURL)
                }
                Button(L10n.string("oauth.cancel_login")) {
                    oauth.cancelLogin()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var oauthSignInPrompt: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.string("oauth.experimental_notice"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(L10n.string("oauth.login")) { oauth.beginLogin() }
                .disabled(oauth.isBusy || ProviderUIFixture.isEnabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var footer: some View {
        HStack {
            Spacer()

            Button(L10n.string("action.quit")) {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
    }
}

private enum PopoverLayoutMetrics {
    private static let fallbackScreenHeight: CGFloat = 720
    private static let screenEdgeClearance: CGFloat = 16

    static var initialMaximumHeight: CGFloat {
        maximumHeight(forScreenVisibleHeight: NSScreen.main?.visibleFrame.height)
    }

    static func maximumHeight(forScreenVisibleHeight visibleHeight: CGFloat?) -> CGFloat {
        max(1, (visibleHeight ?? fallbackScreenHeight) - screenEdgeClearance)
    }
}

/// Reports the visible height of the display that actually contains the menu
/// bar popover, including updates after display or scaling changes.
private struct PopoverScreenHeightReader: NSViewRepresentable {
    let onVisibleHeightChange: (CGFloat) -> Void

    func makeNSView(context: Context) -> ScreenTrackingView {
        ScreenTrackingView(onVisibleHeightChange: onVisibleHeightChange)
    }

    func updateNSView(_ nsView: ScreenTrackingView, context: Context) {
        nsView.onVisibleHeightChange = onVisibleHeightChange
        nsView.publishVisibleHeight()
    }

    final class ScreenTrackingView: NSView {
        var onVisibleHeightChange: (CGFloat) -> Void
        private var observers: [NSObjectProtocol] = []

        init(onVisibleHeightChange: @escaping (CGFloat) -> Void) {
            self.onVisibleHeightChange = onVisibleHeightChange
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        deinit {
            removeObservers()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            installObservers()
            publishVisibleHeight()
        }

        func publishVisibleHeight() {
            guard let visibleHeight = window?.screen?.visibleFrame.height else { return }
            let callback = onVisibleHeightChange
            DispatchQueue.main.async {
                callback(visibleHeight)
            }
        }

        private func installObservers() {
            removeObservers()

            if let window {
                observers.append(NotificationCenter.default.addObserver(
                    forName: NSWindow.didChangeScreenNotification,
                    object: window,
                    queue: .main
                ) { [weak self] _ in
                    self?.publishVisibleHeight()
                })
            }

            observers.append(NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.publishVisibleHeight()
            })
        }

        private func removeObservers() {
            observers.forEach(NotificationCenter.default.removeObserver)
            observers.removeAll()
        }
    }
}

/// Opens the shared settings window without expanding the menu bar popover.
private struct SettingsSection: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button {
            openWindow(id: CodexMeterWindowID.settings)
            NSApplication.shared.activate(ignoringOtherApps: true)
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "gearshape")
                Text(L10n.string("settings.title"))
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.string("settings.title"))
    }
}

/// Narrow ring item for the collapsed summary; the even-flow row wraps these
/// onto extra lines instead of compressing them when the popover is full.
private struct WindowRingItem: View {
    let label: String
    let value: Double?
    let tint: Color

    var body: some View {
        VStack(spacing: 4) {
            QuotaRing(value: value, tint: tint, diameter: 34)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.8)
        }
        .frame(width: 48)
    }
}

/// Every visible window reuses the shared expanded-window component so Codex
/// and external providers render per-window groups identically.
private struct UsageWindowsDetail: View {
    let windows: [CodexUsageWindow]
    let now: Date
    let appearance: MenuBarAppearance
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(windows.enumerated()), id: \.element.id) { index, window in
                if index > 0 { Divider() }
                QuotaWindowDetail(
                    title: window.name,
                    percentText: "\(window.remainingPercent)%",
                    quota: Double(window.remainingPercent),
                    quotaTint: quotaAttentionTint(
                        window.attentionLevel(at: now),
                        appearance: appearance,
                        colorScheme: colorScheme
                    ),
                    time: window.remainingTimePercent(at: now),
                    timeTint: appearance.timeColor.swiftUIColor(for: colorScheme),
                    paceText: paceText(for: window),
                    paceHelp: paceHelpText(for: window),
                    resetText: resetText(for: window)
                )
            }
        }
        .padding(.vertical, 4)
    }

    private func paceText(for window: CodexUsageWindow) -> String {
        switch window.pace(at: now) {
        case .onTrack: L10n.string("pace.on_track")
        case .overPace: L10n.string("pace.over")
        case .unavailable: L10n.string("pace.unavailable")
        }
    }

    private func resetText(for window: CodexUsageWindow) -> String {
        if let resetsAt = window.resetsAt {
            return L10n.withBeijingResetClock(
                L10n.format(
                    "quota.reset_remaining_format",
                    L10n.remainingDuration(until: resetsAt, from: now)
                ),
                resetsAt: resetsAt, now: now
            )
        }
        return L10n.string("quota.reset_unavailable")
    }

    private func paceHelpText(for window: CodexUsageWindow) -> String {
        guard let delta = window.paceDelta(at: now) else {
            return L10n.string("pace.unavailable_help")
        }
        return L10n.format("pace.delta_format", delta)
    }
}

/// Shared attention-level tint so summary rings and detail rings never diverge.
private func quotaAttentionTint(
    _ level: QuotaAttentionLevel,
    appearance: MenuBarAppearance,
    colorScheme: ColorScheme
) -> Color {
    switch level {
    case .normal: appearance.normalColor.swiftUIColor(for: colorScheme)
    case .warning: appearance.warningColor.swiftUIColor(for: colorScheme)
    case .critical: appearance.criticalColor.swiftUIColor(for: colorScheme)
    }
}
