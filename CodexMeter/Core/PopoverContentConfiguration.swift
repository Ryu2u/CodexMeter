import Foundation

/// Stores presentation-only choices for the menu-bar popover: which quota
/// windows appear, and which window drives the menu bar indicator.
/// Hidden windows continue to refresh with their quota source.
struct PopoverContentConfiguration: Codable, Equatable, Sendable {
    var hiddenQuotaWindowIDs: Set<String>
    var menuBarQuotaWindowID: String?

    static let defaultValue = PopoverContentConfiguration(
        hiddenQuotaWindowIDs: [
            QuotaWindowIdentityKey.make(
                sourceID: "base_model_inference",
                windowDurationMins: 7 * 24 * 60
            )
        ],
        menuBarQuotaWindowID: nil
    )

    init(
        hiddenQuotaWindowIDs: Set<String>,
        menuBarQuotaWindowID: String?
    ) {
        self.hiddenQuotaWindowIDs = hiddenQuotaWindowIDs
        self.menuBarQuotaWindowID = menuBarQuotaWindowID
    }

    func isQuotaWindowVisible(_ window: CodexUsageWindow) -> Bool {
        !hiddenQuotaWindowIDs.contains(window.historyID)
    }

    mutating func setQuotaWindow(_ window: CodexUsageWindow, visible: Bool) {
        if visible {
            hiddenQuotaWindowIDs.remove(window.historyID)
        } else {
            hiddenQuotaWindowIDs.insert(window.historyID)
        }
    }

    func visibleQuotaWindows(from windows: [CodexUsageWindow]) -> [CodexUsageWindow] {
        windows.filter(isQuotaWindowVisible)
    }

    func selectedMenuBarWindow(from windows: [CodexUsageWindow]) -> CodexUsageWindow? {
        if let menuBarQuotaWindowID,
           let selected = windows.first(where: { $0.historyID == menuBarQuotaWindowID }) {
            return selected
        }
        // Automatic mode favors the five-hour limit and falls back to the weekly
        // limit; only unknown quota shapes use the most constrained window.
        for preferredDuration in [300, 10_080] {
            let matches = windows.filter { $0.windowDurationMins == preferredDuration }
            if let match = matches.min(by: { $0.remainingPercent < $1.remainingPercent }) {
                return match
            }
        }
        return windows.min { $0.remainingPercent < $1.remainingPercent }
    }

    func normalized() -> PopoverContentConfiguration {
        self
    }

    private enum CodingKeys: String, CodingKey {
        case hiddenQuotaWindowIDs
        case menuBarQuotaWindowID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hiddenQuotaWindowIDs = try container.decodeIfPresent(
            Set<String>.self,
            forKey: .hiddenQuotaWindowIDs
        ) ?? Self.defaultValue.hiddenQuotaWindowIDs
        menuBarQuotaWindowID = try container.decodeIfPresent(
            String.self,
            forKey: .menuBarQuotaWindowID
        )
    }
}

/// Quota windows can swap positions between refreshes, so identity follows
/// the quota bucket and duration instead of the returned position. The same
/// stable identity keys popover visibility and menu bar window selection.
nonisolated enum QuotaWindowIdentityKey {
    static func make(sourceID: String, windowDurationMins: Int?) -> String {
        let durationPrefix = "duration:"
        guard !sourceID.hasPrefix(durationPrefix),
              let windowDurationMins,
              windowDurationMins > 0 else {
            return sourceID
        }

        let positionalSuffixes = ["-primary", "-secondary"]
        let bucketID = positionalSuffixes.first(where: sourceID.hasSuffix).map {
            String(sourceID.dropLast($0.count))
        } ?? sourceID
        return "\(durationPrefix)\(windowDurationMins):\(bucketID)"
    }
}

extension CodexUsageWindow {
    /// Stable identity shared by popover visibility and menu bar selection.
    nonisolated var historyID: String {
        QuotaWindowIdentityKey.make(
            sourceID: id,
            windowDurationMins: windowDurationMins
        )
    }
}
