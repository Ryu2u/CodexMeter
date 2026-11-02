import Foundation

/// Monetary text measures its own column instead of inheriting percentage-only bounds.
struct MenuBarBalanceTextLayout: Equatable {
    let width: Double
    let fontSize: Double
    let truncatesAmount: Bool

    init(amountWidth: Double, captionWidth: Double, appearance: MenuBarAppearance) {
        let appearance = appearance.normalized()
        width = ceil(min(160, max(appearance.textWidth, amountWidth + 2, captionWidth + 2)))
        // The amount always keeps the shared percentage typography; over-limit
        // widths middle-truncate instead of shrinking the font.
        fontSize = appearance.percentageFontSize
        truncatesAmount = amountWidth > width - 2 + 0.001
    }
}
