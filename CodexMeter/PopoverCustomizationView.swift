import SwiftUI

/// Edits presentation-only popover preferences in the shared settings window.
/// Keeping this outside MenuBarExtra prevents the controls from disappearing
/// whenever the user interacts with a picker or another app window.
struct PopoverCustomizationView: View {
    @ObservedObject var oauth: CodexOAuthUsageService
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            Section {
                Text(L10n.string("settings.popover.description"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section(L10n.string("settings.popover.menu_bar_ring")) {
                Picker(L10n.string("settings.menubar_style"), selection: $settings.menuBarStyle) {
                    ForEach(MenuBarDisplayStyle.allCases) { style in
                        Text(style.localizedName).tag(style)
                    }
                }
                Picker(
                    L10n.string("settings.popover.ring_source"),
                    selection: menuBarWindowSelection
                ) {
                    Text(L10n.string("settings.popover.ring_source.automatic"))
                        .tag(String?.none)

                    ForEach(oauth.windows) { window in
                        Text(window.name)
                            .tag(Optional(window.historyID))
                    }
                }
                .accessibilityHint(L10n.string("settings.popover.ring_source.hint"))
            }

            Section(L10n.string("settings.popover.visible_content")) {
                quotaWindowRows
            }

            Section(L10n.string("settings.popover.preview")) {
                PopoverContentPreview(
                    oauth: oauth,
                    configuration: settings.popoverContent
                )
            }

            Section {
                Button(L10n.string("settings.popover.restore_defaults")) {
                    settings.resetPopoverContent()
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(L10n.string("settings.popover.title"))
        .frame(minWidth: 500, minHeight: 580)
    }

    private var menuBarWindowSelection: Binding<String?> {
        Binding(
            get: {
                let storedID = settings.popoverContent.menuBarQuotaWindowID
                return oauth.windows.contains { $0.historyID == storedID } ? storedID : nil
            },
            set: { settings.setMenuBarQuotaWindowID($0) }
        )
    }

    @ViewBuilder
    private var quotaWindowRows: some View {
        if oauth.windows.isEmpty {
            Text(L10n.string("settings.popover.no_quota_windows"))
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            ForEach(oauth.windows) { window in
                Toggle(
                    window.name,
                    isOn: Binding(
                        get: { settings.popoverContent.isQuotaWindowVisible(window) },
                        set: { settings.setQuotaWindow(window, visible: $0) }
                    )
                )
                .accessibilityLabel(
                    L10n.format("settings.popover.quota_window_format", window.name)
                )
            }
        }
    }
}

/// Shows the currently enabled quota windows in their live order.
private struct PopoverContentPreview: View {
    @ObservedObject var oauth: CodexOAuthUsageService
    let configuration: PopoverContentConfiguration

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.string("app.title"))
                        .font(.subheadline.weight(.semibold))
                    Text(accountDescription)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Image(systemName: "arrow.clockwise")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }

            Divider()

            if previewRows.isEmpty {
                Text(L10n.string("settings.popover.preview_empty"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
            } else {
                ForEach(Array(previewRows.enumerated()), id: \.offset) { index, row in
                    if index > 0 {
                        Divider()
                    }

                    Label(row.title, systemImage: row.symbolName)
                        .font(.caption)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            Divider()

            Label(L10n.string("settings.title"), systemImage: "gearshape")
                .font(.caption)
        }
        .padding(12)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .contain)
    }

    private var accountDescription: String {
        if let planType = oauth.planType {
            return L10n.format("account.chatgpt_format", planType.capitalized)
        }
        return L10n.string("oauth.source_title")
    }

    private var previewRows: [PreviewRow] {
        configuration.visibleQuotaWindows(from: oauth.windows).map {
            PreviewRow(title: $0.name, symbolName: "gauge.with.dots.needle.bottom.50percent")
        }
    }

    private struct PreviewRow {
        let title: String
        let symbolName: String
    }
}
