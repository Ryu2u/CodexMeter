import AppKit
import SwiftUI

enum CodexMeterWindowID {
    static let about = "about"
    static let settings = "app-settings"
}

@main
struct CodexMeterApp: App {
    @StateObject private var settings: AppSettings
    @StateObject private var oauth: CodexOAuthUsageService
    @StateObject private var providers: ProviderUsageCoordinator

    init() {
        // The service and settings UI must share one settings instance so
        // appearance and preview changes take effect immediately.
        let settings = AppSettings()
        _settings = StateObject(wrappedValue: settings)
        let oauth = CodexOAuthUsageService(enabled: !ProviderUIFixture.isEnabled)
        _oauth = StateObject(wrappedValue: oauth)
        // Direct sign-in is the only Codex source, so polling always runs.
        oauth.start()
        let providers = ProviderUIFixture.makeCoordinator()
        _providers = StateObject(wrappedValue: providers)
        providers.start()
    }

    var body: some Scene {
        MenuBarExtra {
            ContentView(
                settings: settings,
                providers: providers,
                oauth: oauth
            )
            .appAppearance(settings.appearanceMode)
        } label: {
            Group {
                if providers.selectedConnectionID != nil && !settings.developerPreviewEnabled {
                    ProviderMenuBarLabel(providers: providers, settings: settings)
                } else {
                    MenuBarProgressView(
                        remainingPercent: menuBarSnapshot.remainingPercent,
                        remainingTimePercent: menuBarSnapshot.remainingTimePercent,
                        title: menuBarSnapshot.title,
                        style: settings.menuBarStyle,
                        attentionLevel: menuBarSnapshot.attentionLevel,
                        isStale: menuBarSnapshot.isStale,
                        appearance: settings.developerAppearance,
                        flashContext: settings.developerPreviewEnabled ? nil : menuFlashContext
                    )
                }
            }
            .background { ProviderFixtureSettingsLauncher() }
        }
        .menuBarExtraStyle(.window)

        Window("CodexMeter", id: CodexMeterWindowID.settings) {
            AppSettingsView(settings: settings,
                            providers: providers, oauth: oauth)
                .appAppearance(settings.appearanceMode)
        }
        .defaultSize(width: 840, height: 700)
        .windowResizability(.contentMinSize)

        Window("CodexMeter", id: CodexMeterWindowID.about) {
            AboutView()
                .appAppearance(settings.appearanceMode)
        }
        .defaultSize(width: 500, height: 620)
        .windowResizability(.contentSize)
    }

    private var menuFlashContext: String? {
        "codex-oauth:" +
            (settings.popoverContent.selectedMenuBarWindow(from: oauth.windows)?.historyID ?? "")
    }

    private var menuBarSnapshot: MenuBarPreviewSnapshot {
        if settings.developerPreviewEnabled {
            return settings.developerPreviewSnapshot
        }

        let window = settings.popoverContent.selectedMenuBarWindow(from: oauth.windows)
        return MenuBarPreviewSnapshot(
            remainingPercent: window?.remainingPercent,
            remainingTimePercent: window?.remainingTimePercent(at: Date()),
            title: window.map { "\($0.remainingPercent)%" }
                ?? (oauth.isBusy && oauth.windows.isEmpty ? "…" : "--"),
            attentionLevel: window?.attentionLevel(at: Date()) ?? .normal,
            isStale: oauth.isStale
        )
    }
}

private extension View {
    /// Synchronizes both SwiftUI content and the AppKit host window. The latter
    /// is required for MenuBarExtra materials to change appearance immediately.
    func appAppearance(_ mode: AppAppearanceMode) -> some View {
        preferredColorScheme(mode.preferredColorScheme)
            .background(WindowAppearanceSynchronizer(mode: mode))
    }
}

private struct WindowAppearanceSynchronizer: NSViewRepresentable {
    let mode: AppAppearanceMode

    func makeNSView(context: Context) -> AppearanceTrackingView {
        AppearanceTrackingView(mode: mode)
    }

    func updateNSView(_ nsView: AppearanceTrackingView, context: Context) {
        nsView.apply(mode: mode)
    }

    final class AppearanceTrackingView: NSView {
        private var mode: AppAppearanceMode

        init(mode: AppAppearanceMode) {
            self.mode = mode
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            applyWindowAppearance()
        }

        func apply(mode: AppAppearanceMode) {
            self.mode = mode
            applyWindowAppearance()
        }

        private func applyWindowAppearance() {
            window?.appearance = mode.windowAppearance
        }
    }
}
