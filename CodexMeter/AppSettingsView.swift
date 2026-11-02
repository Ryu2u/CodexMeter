import SwiftUI

/// Shares existing settings objects so reorganizing controls never migrates preferences.
struct AppSettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var providers: ProviderUsageCoordinator
    @ObservedObject var oauth: CodexOAuthUsageService
    // Platforms & Connections is the most-used category, so it leads the
    // sidebar and is the default landing page of the settings window.
    @State private var selection: String? = "providers.category"

    private let categories = [
        ("providers.category", "network"),
        ("settings.category.general", "gearshape"),
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
                    ProviderConnectionsView(providers: providers, settings: settings, oauth: oauth)
                case "settings.category.menu":
                    PopoverCustomizationView(oauth: oauth, settings: settings)
                case "developer.title":
                    DeveloperOptionsView(settings: settings, embedded: true)
                case "about.title":
                    AboutView(embedded: true)
                default:
                    generalSettings
                }
            }
            .navigationTitle(L10n.string(selection ?? "settings.category.general"))
        }
        .frame(minWidth: 760, minHeight: 600)
        .onAppear { settings.refreshLaunchAtLoginStatus() }
        .alert(L10n.string("settings.error_title"), isPresented: Binding(
            get: { settings.settingsError != nil },
            set: { if !$0 { settings.clearSettingsError() } }
        )) {
            Button(L10n.string("action.ok")) { settings.clearSettingsError() }
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

    private var generalSettings: some View {
        Form {
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
