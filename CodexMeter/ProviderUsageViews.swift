import AppKit
import SwiftUI

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
        guard let duration = bucket.windowDuration, duration.isFinite,
              duration >= 60, duration < Double(Int.max) / 2 else { return bucket.title }
        if duration.truncatingRemainder(dividingBy: 86_400) == 0 {
            return L10n.format("providers.bucket_days_format", bucket.title, Int(duration / 86_400))
        }
        if duration.truncatingRemainder(dividingBy: 3_600) == 0 {
            return L10n.format("providers.bucket_hours_format", bucket.title, Int(duration / 3_600))
        }
        return L10n.format("providers.bucket_minutes_format", bucket.title, Int(duration / 60))
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
        formatter.maximumFractionDigits = 1
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

    static func status(_ status: ProviderConnectionStatus?) -> String {
        guard let status else { return L10n.string("providers.status.notQueried") }
        switch status {
        case .loading: return L10n.string("loading.usage")
        case .ready: return L10n.string("providers.status.ready")
        case .stale(let error): return L10n.string("providers.error.\(error.rawValue)")
        case .authRequired: return L10n.string("providers.error.authentication")
        case .rateLimited(let until):
            return L10n.format("providers.retry_at_format", L10n.formattedTime(until))
        case .unavailable(let error): return L10n.string("providers.error.\(error.rawValue)")
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

    private var connection: ProviderConnection? {
        providers.connections.first { $0.id == providers.selectedConnectionID }
    }

    var body: some View {
        if let connection, let bucket = providers.selectedBucket(for: connection.id),
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

    private var status: ProviderConnectionStatus? { providers.statuses[connection.id] }
    private var snapshot: ProviderUsageSnapshot? { providers.snapshots[connection.id] }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if ProviderUIFixture.isEnabled {
                Label(L10n.string("providers.preview"), systemImage: "eye.trianglebadge.exclamationmark")
                    .font(.caption).foregroundStyle(.orange)
            }
            if connection.kind.isExperimental {
                Label(L10n.string("providers.experimental"), systemImage: "flask")
                    .font(.caption).foregroundStyle(.orange)
            }
            if status?.isStale == true {
                Label(L10n.string("data.stale"), systemImage: "clock.badge.exclamationmark")
                    .font(.caption).foregroundStyle(.orange)
            }
            if status?.isLoading == true && snapshot == nil {
                HStack { ProgressView().controlSize(.small); Text(L10n.string("loading.usage")) }
            } else if status?.errorCode != nil || snapshot == nil {
                Text(ProviderUsagePresentation.status(status))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
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
            Text(L10n.string("providers.query_only"))
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func bucketRow(_ bucket: ProviderUsageBucket, at date: Date) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(ProviderUsagePresentation.title(bucket)).font(.subheadline.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Text(ProviderUsagePresentation.value(bucket)).font(.headline.monospacedDigit())
            }
            if let description = ProviderUsagePresentation.boostDescription(bucket) {
                Text(description).font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let remaining = bucket.remainingPercent {
                Text(L10n.string("quota.remaining")).font(.caption2).foregroundStyle(.secondary)
                ProgressView(value: remaining, total: 100)
                    .tint(quotaTint(bucket, at: date)).id(colorScheme)
                if let time = bucket.remainingTimePercent(at: date) {
                    Text(L10n.string("providers.remaining_time")).font(.caption2).foregroundStyle(.secondary)
                    ProgressView(value: time, total: 100)
                        .tint(settings.developerAppearance.timeColor.swiftUIColor(for: colorScheme)).id(colorScheme)
                    Text(L10n.string(remaining < time ? "providers.over_pace" : "providers.on_pace"))
                        .font(.caption2).foregroundStyle(.secondary)
                }
            } else if case .money = bucket.metric {
                Text(L10n.string("providers.remaining_balance")).font(.caption2).foregroundStyle(.secondary)
            }
            if let reset = bucket.resetsAt {
                Text(L10n.format("providers.resets_format", L10n.remainingDuration(until: reset, from: date)))
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
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
    private struct EditorTarget: Identifiable {
        let id = UUID()
        let connection: ProviderConnection?
    }
    @State private var editorTarget: EditorTarget?
    @State private var deletingID: UUID?
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section {
                if let error = providers.configurationError {
                    Label(L10n.string("providers.error.\(error.rawValue)"), systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
                Text(L10n.string("providers.privacy"))
                    .font(.caption).foregroundStyle(.secondary)
                Text(L10n.string("providers.codex_auth"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(L10n.string("providers.connections")) {
                if providers.connections.isEmpty {
                    Text(L10n.string("providers.empty")).foregroundStyle(.secondary)
                }
                ForEach(providers.connections) { connection in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(connection.name).font(.headline)
                                Text("\(connection.kind.localizedName) · \(connection.region.localizedName)")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
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
                        Text(ProviderUsagePresentation.status(providers.statuses[connection.id]))
                            .font(.caption).foregroundStyle(.secondary)
                        if let snapshot = providers.snapshots[connection.id] {
                            Text(L10n.format("status.updated_at_format", L10n.formattedDateTime(snapshot.fetchedAt)))
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }
                Button(L10n.string("providers.add")) {
                    editorTarget = EditorTarget(connection: nil)
                }
            }
        }
        .formStyle(.grouped)
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
        _kind = State(initialValue: connection?.kind ?? .deepSeek)
        _region = State(initialValue: connection?.region ?? .global)
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
                TextField(L10n.string("providers.name"), text: $name)
                SecureField(L10n.string(connection == nil ? "providers.api_key" : "providers.replace_key"), text: $key)
                    .textContentType(.password)
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
                            id: connection?.id, kind: kind, region: kind == .deepSeek ? .global : region,
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
                .disabled(connection == nil && key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 470)
        .onDisappear { key = "" }
    }
}
