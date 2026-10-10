import SwiftUI

/// Shares existing settings objects so reorganizing controls never migrates preferences.
struct AppSettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var updateChecker: UpdateChecker
    @ObservedObject var providers: ProviderUsageCoordinator
    @ObservedObject var oauth: CodexOAuthUsageService
    @State private var selection: String? = "settings.category.general"
    @State private var actionError: String?

    private let categories = [
        ("settings.category.general", "gearshape"),
        ("providers.category", "network"),
        ("settings.category.menu", "menubar.rectangle"),
        ("developer.title", "hammer"),
        ("about.title", "info.circle")
    ]

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(categories, id: \.0) { key, symbol in
                    Label(L10n.string(key), systemImage: symbol).tag(key)
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
        } detail: {
            Group {
                switch selection {
                case "providers.category":
                    ProviderConnectionsView(providers: providers)
                case "settings.category.menu":
                    PopoverCustomizationView(oauth: oauth, settings: settings)
                case "developer.title":
                    DeveloperOptionsView(settings: settings, updateChecker: updateChecker, embedded: true)
                case "about.title":
                    AboutView(settings: settings, updateChecker: updateChecker, embedded: true)
                default:
                    generalSettings
                }
            }
            .navigationTitle(L10n.string(selection ?? "settings.category.general"))
        }
        .frame(minWidth: 760, minHeight: 600)
        .onAppear { settings.refreshLaunchAtLoginStatus() }
        .alert(L10n.string("settings.error_title"), isPresented: Binding(
            get: { settings.settingsError != nil || actionError != nil },
            set: { if !$0 { settings.clearSettingsError(); actionError = nil } }
        )) {
            Button(L10n.string("action.ok")) { settings.clearSettingsError(); actionError = nil }
            if settings.settingsDestination != nil {
                Button(L10n.string("action.open_system_settings")) {
                    settings.openRelevantSystemSettings()
                    settings.clearSettingsError()
                }
            }
        } message: {
            Text(settings.settingsError ?? actionError ?? "")
        }
    }

    private var generalSettings: some View {
        Form {
            Section(L10n.string("oauth.account_section")) {
                OAuthAccountRow(oauth: oauth) { actionError = $0 }
            }
            Section {
                Picker(L10n.string("settings.language"), selection: $settings.language) {
                    ForEach(AppLanguage.allCases) { Text($0.localizedName).tag($0) }
                }
                Picker(L10n.string("settings.appearance"), selection: $settings.appearanceMode) {
                    ForEach(AppAppearanceMode.allCases) { Text($0.localizedName).tag($0) }
                }
                Toggle(L10n.string("settings.launch_at_login"), isOn: Binding(
                    get: { settings.launchAtLoginEnabled }, set: { settings.setLaunchAtLogin($0) }
                ))
            }
        }
        .formStyle(.grouped)
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
