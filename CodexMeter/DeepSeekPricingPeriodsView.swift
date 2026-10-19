import SwiftUI

/// Pricing time bars stay independent of the platform's monetary balance.
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
                Label(phaseTitle(snapshot.phase), systemImage: phaseSymbol(snapshot.phase))
                    .font(.caption)
                    .foregroundStyle(phaseColor(snapshot.phase))
                waitRow(titleKey: "deepseek.pricing.next_peak", target: snapshot.nextPeakAt,
                        fraction: snapshot.peakWaitFraction,
                        tint: settings.developerAppearance.warningColor.swiftUIColor(for: colorScheme),
                        at: context.date)
                waitRow(titleKey: "deepseek.pricing.next_off_peak", target: snapshot.nextOffPeakAt,
                        fraction: snapshot.offPeakWaitFraction,
                        tint: settings.developerAppearance.timeColor.swiftUIColor(for: colorScheme),
                        at: context.date)
                Text(L10n.string("deepseek.pricing.local_rule"))
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

    private func phaseTitle(_ phase: DeepSeekPricingPhase) -> String {
        switch phase {
        case .peak: L10n.string("deepseek.pricing.phase_peak")
        case .offPeak: L10n.string("deepseek.pricing.phase_off_peak")
        case .unconfirmed: L10n.string("deepseek.pricing.phase_unconfirmed")
        }
    }

    private func phaseSymbol(_ phase: DeepSeekPricingPhase) -> String {
        switch phase {
        case .peak: "sun.max.fill"
        case .offPeak: "moon.fill"
        case .unconfirmed: "questionmark.circle"
        }
    }

    private func phaseColor(_ phase: DeepSeekPricingPhase) -> Color {
        switch phase {
        case .peak, .unconfirmed: settings.developerAppearance.warningColor.swiftUIColor(for: colorScheme)
        case .offPeak: settings.developerAppearance.timeColor.swiftUIColor(for: colorScheme)
        }
    }
}
