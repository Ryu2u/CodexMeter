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
    @Environment(\.openWindow) private var openWindow
    @State private var maximumPopoverHeight = PopoverLayoutMetrics.initialMaximumHeight

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
            providers.setPopoverVisible(true)
            oauth.setPopoverVisible(true)
            settings.refreshLaunchAtLoginStatus()
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

    private var scrollableContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            if settings.developerPreviewEnabled {
                previewModeBanner
            }

            if selectedConnection == nil && !settings.developerPreviewEnabled && oauth.isStale {
                staleBanner
            }

            Divider()

            if let connection = selectedConnection {
                ProviderUsageSection(connection: connection, providers: providers, settings: settings)
            } else {
                oauthSection
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.string("app.title"))
                        .font(.headline)

                    Text(headerAccountDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if isSelectedRefreshInFlight {
                    ProgressView()
                        .controlSize(.small)
                }

                Button {
                    if selectedConnection != nil {
                        providers.refreshSelected()
                    } else {
                        oauth.refresh(reauthorizing: true)
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .help(L10n.string("action.refresh"))
                .disabled(isSelectedRefreshInFlight)
            }
            if showsSourcePicker {
                Picker(L10n.string("providers.source"), selection: sourceSelection) {
                    Text(L10n.string("oauth.source_title")).tag(nil as String?)
                    ForEach(providers.connections) { connection in
                        Text(connection.name).tag(Optional(connection.id.uuidString))
                    }
                }
                .pickerStyle(.menu)
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

    private var headerAccountDescription: String {
        if selectedConnection != nil { return selectedConnection?.name ?? "" }
        if let planType = oauth.planType {
            return L10n.format("account.chatgpt_format", planType.capitalized)
        }
        return L10n.string("oauth.source_title")
    }

    private var selectedConnection: ProviderConnection? {
        guard !settings.developerPreviewEnabled else { return nil }
        return providers.connections.first { $0.id == providers.selectedConnectionID }
    }

    private var isSelectedRefreshInFlight: Bool {
        if selectedConnection != nil {
            return providers.statuses[selectedConnection?.id ?? UUID()]?.isLoading ?? false
        }
        return oauth.isBusy
    }

    private var staleBanner: some View {
        Label(L10n.string("data.stale"), systemImage: "clock.badge.exclamationmark")
            .font(.caption)
            .foregroundStyle(.orange)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
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

    private var loadingView: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text(L10n.string("loading.usage"))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 90)
    }

    private func errorView(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(L10n.string("error.cannot_read"), systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(L10n.string("action.retry")) {
                oauth.refresh()
            }
        }
        .frame(maxWidth: .infinity, minHeight: 90, alignment: .leading)
    }

    private func inlineErrorView(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle")
            .font(.caption)
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var oauthSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let code = oauth.deviceCode {
                oauthPendingView(code)
            } else if !oauth.isConnected {
                oauthSignInPrompt
            } else if let message = oauth.errorMessage, oauth.windows.isEmpty {
                errorView(message)
            } else if oauth.windows.isEmpty {
                loadingView
            } else {
                if let message = oauth.errorMessage {
                    inlineErrorView(message)
                }

                oauthQuotaList

                if let updated = oauth.lastUpdated {
                    Text(L10n.format("status.updated_at_format", L10n.formattedDateTime(updated)))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var oauthQuotaList: some View {
        // Update countdowns and pace locally every minute without another request.
        TimelineView(.periodic(from: Date(), by: 60)) { context in
            VStack(spacing: 16) {
                ForEach(oauth.windows) { window in
                    UsageWindowRow(
                        window: window,
                        now: context.date,
                        appearance: settings.developerAppearance
                    )

                    if window.id != oauth.windows.last?.id {
                        Divider()
                    }
                }
            }
        }
    }

    private func oauthPendingView(_ code: CodexOAuthDeviceCode) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(L10n.string("oauth.login_pending"), systemImage: "globe")
                .font(.caption)
                .foregroundStyle(.secondary)

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
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private var oauthSignInPrompt: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let message = oauth.errorMessage {
                inlineErrorView(message)
            }
            Text(L10n.string("oauth.experimental_notice"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(L10n.string("oauth.login")) { oauth.beginLogin() }
                .disabled(oauth.isBusy)
        }
        .frame(maxWidth: .infinity, minHeight: 90, alignment: .leading)
    }

    private var footer: some View {
        HStack {
            if let lastUpdated = selectedLastUpdated {
                Text(L10n.format(
                    "status.updated_at_format",
                    L10n.formattedTime(lastUpdated, includingSeconds: true)
                ))
                .font(.caption2)
                .foregroundStyle(.tertiary)
            } else if selectedConnection != nil {
                Text(L10n.string("providers.status.notQueried"))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else {
                Text(L10n.string("oauth.source_title"))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            Button(L10n.string("action.quit")) {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
    }

    private var selectedLastUpdated: Date? {
        if let selectedConnection { return providers.snapshots[selectedConnection.id]?.fetchedAt }
        return oauth.lastUpdated
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

/// Displays quota and time on the same 0...100 scale for direct comparison.
private struct UsageWindowRow: View {
    let window: CodexUsageWindow
    let now: Date
    let appearance: MenuBarAppearance
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(window.name)
                    .font(.subheadline.weight(.semibold))

                Spacer()

                paceLabel
            }

            MetricBar(
                label: L10n.string("quota.remaining"),
                value: Double(window.remainingPercent),
                tint: quotaTint,
                symbol: "battery.75percent"
            )

            MetricBar(
                label: L10n.string("time.remaining"),
                value: window.remainingTimePercent(at: now),
                tint: appearance.timeColor.swiftUIColor(for: colorScheme),
                symbol: "clock"
            )

            HStack {
                if let resetsAt = window.resetsAt {
                    Label(
                        L10n.format(
                            "quota.reset_remaining_format",
                            L10n.remainingDuration(until: resetsAt, from: now)
                        ),
                        systemImage: "hourglass"
                    )
                } else {
                    Label(L10n.string("quota.reset_unavailable"), systemImage: "hourglass")
                }

                Spacer()

                if let resetsAt = window.resetsAt {
                    Text(L10n.format(
                        "quota.reset_format",
                        L10n.formattedDateTime(resetsAt)
                    ))
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var paceLabel: some View {
        switch window.pace(at: now) {
        case .onTrack:
            Label(L10n.string("pace.on_track"), systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .help(paceHelpText)
        case .overPace:
            Label(L10n.string("pace.over"), systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .help(paceHelpText)
        case .unavailable:
            Label(L10n.string("pace.unavailable"), systemImage: "questionmark.circle")
                .foregroundStyle(.secondary)
                .help(L10n.string("pace.unavailable_help"))
        }
    }

    private var paceHelpText: String {
        guard let delta = window.paceDelta(at: now) else {
            return L10n.string("pace.unavailable_help")
        }
        return L10n.format("pace.delta_format", delta)
    }

    private var quotaTint: Color {
        switch window.attentionLevel(at: now) {
        case .normal: appearance.normalColor.swiftUIColor(for: colorScheme)
        case .warning: appearance.warningColor.swiftUIColor(for: colorScheme)
        case .critical: appearance.criticalColor.swiftUIColor(for: colorScheme)
        }
    }
}

private struct MetricBar: View {
    let label: String
    let value: Double?
    let tint: Color
    let symbol: String
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 5) {
            HStack {
                Label(label, systemImage: symbol)
                Spacer()
                Text(value.map { "\(Int($0.rounded()))%" } ?? "—")
                    .monospacedDigit()
            }
            .font(.caption)

            ProgressView(value: value ?? 0, total: 100)
                .tint(tint)
                // AppKit reuses this native control across appearance changes
                // and can reset its tint. Recreate it so SwiftUI reapplies tint.
                .id(colorScheme)
                .opacity(value == nil ? 0.25 : 1)
        }
        .accessibilityElement(children: .combine)
    }
}
