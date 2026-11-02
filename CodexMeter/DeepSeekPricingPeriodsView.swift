import SwiftUI

/// The pricing wait bar stays independent of the platform's monetary balance.
struct DeepSeekPricingPeriodsView: View {
    @ObservedObject var settings: AppSettings
    @Environment(\.colorScheme) private var colorScheme

    private var minuteAnchor: Date {
        Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970 / 60) * 60)
    }

    var body: some View {
        TimelineView(.periodic(from: minuteAnchor, by: 60)) { context in
            let snapshot = DeepSeekPricingSchedule.snapshot(at: context.date)
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.string("deepseek.pricing.title"))
                    .font(.subheadline.weight(.semibold))
                Label(snapshot.phase.localizedTitle, systemImage: snapshot.phase.symbolName)
                    .font(.caption)
                    .foregroundStyle(snapshot.phase.phaseColor(
                        for: settings.developerAppearance, colorScheme: colorScheme))
                // Exactly one bar: it counts down to whatever ends the current
                // phase, so peak waits for off-peak and vice versa.
                if let transition = snapshot.currentPhaseTransition {
                    waitRow(
                        titleKey: transition.phase == .peak
                            ? "deepseek.pricing.next_peak"
                            : "deepseek.pricing.next_off_peak",
                        target: transition.at,
                        fraction: transition.waitFraction,
                        tint: transition.phase == .peak
                            ? settings.developerAppearance.warningColor.swiftUIColor(for: colorScheme)
                            : settings.developerAppearance.timeColor.swiftUIColor(for: colorScheme),
                        at: context.date)
                }
                Text(L10n.string("deepseek.pricing.local_rule"))
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(L10n.string("deepseek.menubar.ring_help"))
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if snapshot.phase == .unconfirmed || snapshot.currentPhaseStart == nil
                    || snapshot.nextPeakAt == nil || snapshot.nextOffPeakAt == nil {
                    Text(L10n.string("deepseek.pricing.calendar_unconfirmed"))
                        .font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Link(L10n.string("deepseek.pricing.rules_link"), destination: DeepSeekPricingSchedule.rulesURL)
                        .font(.caption2)
                }
            }
        }
    }

    private func waitRow(titleKey: String, target: Date?, fraction: Double?, tint: Color, at date: Date) -> some View {
        let countdown = target.map { L10n.remainingDuration(until: $0, from: date) }
            ?? L10n.string("deepseek.pricing.time_unconfirmed")
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(L10n.string(titleKey)).font(.caption)
                Spacer()
                Text(countdown).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            if let fraction {
                ProgressView(value: fraction, total: 1)
                    .tint(tint).id(colorScheme)
                    .accessibilityLabel(L10n.string(titleKey))
                    .accessibilityValue(L10n.format(
                        "deepseek.pricing.progress_accessibility_format",
                        ProviderUsagePresentation.percentage(fraction * 100), countdown))
            } else {
                Text(L10n.string("deepseek.pricing.progress_unconfirmed"))
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

extension DeepSeekPricingPhase {
    var localizedTitle: String {
        switch self {
        case .peak: L10n.string("deepseek.pricing.phase_peak")
        case .offPeak: L10n.string("deepseek.pricing.phase_off_peak")
        case .unconfirmed: L10n.string("deepseek.pricing.phase_unconfirmed")
        }
    }

    var symbolName: String {
        switch self {
        case .peak: "sun.max.fill"
        case .offPeak: "moon.fill"
        case .unconfirmed: "questionmark.circle"
        }
    }

    func phaseColor(for appearance: MenuBarAppearance, colorScheme: ColorScheme) -> Color {
        switch self {
        case .peak, .unconfirmed: appearance.warningColor.swiftUIColor(for: colorScheme)
        case .offPeak: appearance.timeColor.swiftUIColor(for: colorScheme)
        }
    }
}
