import SwiftUI

struct PlatformOverviewSection<Status: View, Summary: View, Detail: View>: View {
    let title: String
    @Binding var isExpanded: Bool
    private let status: Status
    private let summary: Summary
    private let detail: Detail

    init(
        title: String,
        isExpanded: Binding<Bool>,
        @ViewBuilder status: () -> Status,
        @ViewBuilder summary: () -> Summary,
        @ViewBuilder detail: () -> Detail
    ) {
        self.title = title
        _isExpanded = isExpanded
        self.status = status()
        self.summary = summary()
        self.detail = detail()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(title)
                            .font(.headline)
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                        status
                        if !isExpanded {
                            summary
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
            .accessibilityHint(L10n.string("providers.toggle_details_hint"))

            if isExpanded {
                detail.padding(.top, 10)
            }
        }
    }
}

struct OverviewMetricRow: View {
    let title: String
    let value: String

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title).fixedSize()
                Spacer(minLength: 8)
                Text(value).monospacedDigit().fixedSize()
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                Text(value).monospacedDigit().fixedSize()
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.caption)
        .foregroundStyle(.primary)
        .accessibilityElement(children: .combine)
    }
}

/// Compact circular gauge for a 0...100 value; nil draws a muted ring and a dash.
struct QuotaRing: View {
    let value: Double?
    let tint: Color
    let diameter: CGFloat

    private var ringLineWidth: CGFloat { max(3, diameter / 8.5) }

    private var centerText: String {
        value.map { "\(Int($0.rounded()))%" } ?? "—"
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.1), lineWidth: ringLineWidth)
            if let value {
                Circle()
                    .trim(from: 0, to: max(0.01, min(1, value / 100)))
                    .stroke(tint, style: StrokeStyle(lineWidth: ringLineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            Text(centerText)
                .font(diameter <= 38 ? .caption2 : .caption)
                .monospacedDigit()
                .minimumScaleFactor(0.6)
        }
        .frame(width: diameter, height: diameter)
        .accessibilityElement(children: .combine)
    }
}

/// One expanded quota window shared by Codex and external providers: a
/// semibold title with the rounded percentage on the right, the optional
/// boost note, large quota and remaining-time rings, then the pace and reset
/// lines. Both platforms must render identically, so keep every layout
/// choice here instead of at the call sites.
struct QuotaWindowDetail: View {
    let title: String
    let percentText: String
    var boostText: String? = nil
    let quota: Double?
    let quotaTint: Color
    let time: Double?
    let timeTint: Color
    let paceText: String?
    var paceHelp: String? = nil
    let resetText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Text(percentText)
                    .font(.headline.monospacedDigit())
            }
            if let boostText {
                Text(boostText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            OverviewRingRow {
                if let quota {
                    OverviewRingItem(
                        label: L10n.string("quota.remaining"),
                        value: quota,
                        tint: quotaTint,
                        diameter: 44
                    )
                }
                if let time {
                    OverviewRingItem(
                        label: L10n.string("providers.remaining_time"),
                        value: time,
                        tint: timeTint,
                        diameter: 44
                    )
                }
            }
            if let paceText {
                Text(paceText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .help(paceHelp ?? paceText)
            }
            if let resetText {
                Text(resetText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// A ring with its label wrapped underneath instead of stretching the row.
struct OverviewRingItem: View {
    let label: String
    let value: Double?
    let tint: Color
    var diameter: CGFloat = 34

    var body: some View {
        VStack(spacing: 4) {
            QuotaRing(value: value, tint: tint, diameter: diameter)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.85)
        }
        .frame(width: diameter + 26)
    }
}

/// Shared label rule for the collapsed summary rings of one percentage
/// window, on Codex and external providers alike: the quota ring shows the
/// window title verbatim, and the reset ring appends the reset wording to
/// that same title, so a platform with several windows never renders two
/// indistinguishable rings. The expanded `QuotaWindowDetail` keeps its
/// generic ring labels because each card already shows the title above them.
enum WindowRingLabels {
    static func quota(_ title: String) -> String { title }
    static func reset(_ title: String) -> String {
        L10n.format("quota.window_reset_format", title)
    }
}

/// Ring rows spread their gauges evenly across the full row width and wrap
/// onto extra lines instead of compressing; gauges always keep ideal size.
struct OverviewRingRow<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        EvenFlowLayout(minimumLineGap: 10) { content }
            .frame(maxWidth: .infinity)
    }
}

/// SwiftUI adapter for the unit-tested EvenFlowDistribution math: rings keep
/// their ideal size and only their positions come from the distribution.
private struct EvenFlowLayout: Layout {
    var minimumLineGap: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        return EvenFlowDistribution.resolve(
            sizes: sizes,
            proposedWidth: proposal.width,
            proposedHeight: proposal.height,
            minimumLineGap: minimumLineGap
        ).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let result = EvenFlowDistribution.resolve(
            sizes: sizes,
            proposedWidth: bounds.width,
            proposedHeight: bounds.height,
            minimumLineGap: minimumLineGap
        )
        for (index, subview) in subviews.enumerated() {
            let placement = result.placements[index]
            subview.place(
                at: CGPoint(x: bounds.minX + placement.x, y: bounds.minY + placement.y),
                anchor: .topLeading,
                proposal: .unspecified
            )
        }
    }
}

struct OverviewUpdatedAt: View {
    let date: Date

    var body: some View {
        Text(L10n.format("status.updated_at_format", L10n.formattedTime(date, includingSeconds: true)))
            .font(.caption2)
            .foregroundStyle(.secondary)
    }
}

struct ProviderOverviewSection: View {
    let connection: ProviderConnection
    @ObservedObject var providers: ProviderUsageCoordinator
    @ObservedObject var settings: AppSettings
    @Binding var isExpanded: Bool
    @Environment(\.colorScheme) private var colorScheme

    private var status: ProviderConnectionStatus? { providers.statuses[connection.id] }
    private var snapshot: ProviderUsageSnapshot? { providers.snapshots[connection.id] }
    private var date: Date { Date() }
    private var ringBuckets: [ProviderUsageBucket] {
        snapshot?.buckets.filter { $0.remainingPercent != nil } ?? []
    }
    private var textBuckets: [ProviderUsageBucket] {
        snapshot?.buckets.filter { $0.remainingPercent == nil } ?? []
    }

    var body: some View {
        PlatformOverviewSection(title: connection.name, isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 5) {
                if ProviderUIFixture.isEnabled {
                    Label(L10n.string("providers.preview"), systemImage: "eye.trianglebadge.exclamationmark")
                        .foregroundStyle(.orange)
                }
                if connection.kind == .miniMax {
                    Label(L10n.string("providers.experimental"), systemImage: "flask")
                        .foregroundStyle(.orange)
                }
                if status?.isLoading == true {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(ProviderUsagePresentation.status(status, kind: connection.kind))
                    }
                    .foregroundStyle(.secondary)
                } else if status?.errorCode != nil {
                    Label(ProviderUsagePresentation.status(status, kind: connection.kind),
                          systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                } else {
                    Text(ProviderUsagePresentation.status(status, kind: connection.kind))
                        .foregroundStyle(.secondary)
                }
                if status?.isStale == true, snapshot != nil {
                    Label(L10n.string("data.stale"), systemImage: "clock.badge.exclamationmark")
                        .foregroundStyle(.orange)
                }
                if let snapshot {
                    OverviewUpdatedAt(date: snapshot.fetchedAt)
                }
            }
            .font(.caption)
            .fixedSize(horizontal: false, vertical: true)
        } summary: {
            if snapshot != nil {
                VStack(alignment: .leading, spacing: 7) {
                    if connection.kind == .deepSeek {
                        // Balance rows render as text without rings, so keep
                        // the current Beijing-time pricing phase visible in
                        // the collapsed state too; it is a local calendar
                        // calculation and never an extra request.
                        TimelineView(.periodic(from: Date(), by: 60)) { context in
                            let phase = DeepSeekPricingSchedule.snapshot(at: context.date).phase
                            Label(phase.localizedTitle, systemImage: phase.symbolName)
                                .font(.caption)
                                .foregroundStyle(phase.phaseColor(
                                    for: settings.developerAppearance, colorScheme: colorScheme))
                        }
                    }
                    if !ringBuckets.isEmpty {
                        // Like the Codex summary, every percentage window shows
                        // both its quota ring and its reset-time ring, labeled
                        // by the shared rule so multi-window platforms stay
                        // distinguishable without expanding.
                        TimelineView(.periodic(from: Date(), by: 60)) { context in
                            OverviewRingRow {
                                ForEach(ringBuckets) { bucket in
                                    OverviewRingItem(
                                        label: WindowRingLabels.quota(
                                            ProviderUsagePresentation.title(bucket)),
                                        value: bucket.remainingPercent,
                                        tint: quotaTint(bucket, at: context.date)
                                    )
                                    if let time = bucket.remainingTimePercent(at: context.date) {
                                        OverviewRingItem(
                                            label: WindowRingLabels.reset(
                                                ProviderUsagePresentation.title(bucket)),
                                            value: time,
                                            tint: settings.developerAppearance.timeColor.swiftUIColor(for: colorScheme)
                                        )
                                    }
                                }
                            }
                        }
                    }
                    ForEach(ringBuckets) { bucket in
                        if let description = ProviderUsagePresentation.boostDescription(bucket) {
                            Text(description)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    ForEach(textBuckets) { bucket in
                        VStack(alignment: .leading, spacing: 3) {
                            OverviewMetricRow(
                                title: ProviderUsagePresentation.title(bucket),
                                value: ProviderUsagePresentation.value(bucket)
                            )
                            if let description = ProviderUsagePresentation.boostDescription(bucket) {
                                Text(description)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
        } detail: {
            ProviderUsageSection(connection: connection, providers: providers, settings: settings)
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

struct DeveloperQuotaOverviewSection: View {
    @ObservedObject var settings: AppSettings
    @Binding var isExpanded: Bool
    @Environment(\.colorScheme) private var colorScheme

    private var snapshot: MenuBarPreviewSnapshot { settings.developerPreviewSnapshot }

    var body: some View {
        PlatformOverviewSection(title: L10n.string("oauth.source_title"), isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 5) {
                Text(L10n.string("developer.preview_source"))
                    .foregroundStyle(.secondary)
                if snapshot.isStale {
                    Label(L10n.string("data.stale"), systemImage: "clock.badge.exclamationmark")
                        .foregroundStyle(.orange)
                }
                if settings.developerPreviewPreset == .longText {
                    Text(snapshot.title)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .font(.caption)
        } summary: {
            OverviewRingRow {
                OverviewRingItem(
                    label: L10n.string("quota.remaining"),
                    value: snapshot.remainingPercent.map(Double.init),
                    tint: quotaTint
                )
                OverviewRingItem(
                    label: L10n.string("time.remaining"),
                    value: snapshot.remainingTimePercent,
                    tint: settings.developerAppearance.timeColor.swiftUIColor(for: colorScheme)
                )
            }
        } detail: {
            VStack(alignment: .leading, spacing: 10) {
                OverviewRingRow {
                    OverviewRingItem(
                        label: L10n.string("quota.remaining"),
                        value: snapshot.remainingPercent.map(Double.init),
                        tint: quotaTint,
                        diameter: 44
                    )
                    OverviewRingItem(
                        label: L10n.string("time.remaining"),
                        value: snapshot.remainingTimePercent,
                        tint: settings.developerAppearance.timeColor.swiftUIColor(for: colorScheme),
                        diameter: 44
                    )
                }
                if let quota = snapshot.remainingPercent, let time = snapshot.remainingTimePercent {
                    Label(
                        L10n.string(Double(quota) >= time ? "pace.on_track" : "pace.over"),
                        systemImage: Double(quota) >= time ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(Double(quota) >= time ? Color.green : Color.orange)
                } else {
                    Label(L10n.string("pace.unavailable"), systemImage: "questionmark.circle")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption)
        }
    }

    private var quotaTint: Color {
        switch snapshot.attentionLevel {
        case .normal: settings.developerAppearance.normalColor.swiftUIColor(for: colorScheme)
        case .warning: settings.developerAppearance.warningColor.swiftUIColor(for: colorScheme)
        case .critical: settings.developerAppearance.criticalColor.swiftUIColor(for: colorScheme)
        }
    }
}
