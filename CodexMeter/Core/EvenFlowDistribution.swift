import CoreGraphics

/// Pure layout math for ring rows: items wrap into lines inside the proposed
/// width, every line spreads its items edge to edge with equal horizontal
/// gaps, and lines spread vertically with equal gaps as well — never closer
/// than the minimum line gap once a row wraps. A single-line row keeps its
/// natural height without edge padding. Items top-align within their line so
/// the gauges inside them line up even when their labels wrap differently.
/// The SwiftUI side only feeds measured ideal sizes in and applies the
/// returned positions, so the distribution rules stay unit-testable without
/// a render pass.
struct EvenFlowDistribution {
    struct Placement: Equatable {
        var x: CGFloat
        var y: CGFloat
        var line: Int
    }

    struct Result: Equatable {
        var placements: [Placement]
        var size: CGSize
    }

    static func resolve(
        sizes: [CGSize],
        proposedWidth: CGFloat?,
        proposedHeight: CGFloat?,
        minimumLineGap: CGFloat
    ) -> Result {
        guard !sizes.isEmpty else { return Result(placements: [], size: .zero) }

        // Greedy wrap: an item joins the current line while it fits with the
        // minimum gap; anything wider than the row still takes its own line.
        var lines: [[(index: Int, size: CGSize)]] = []
        var current: [(index: Int, size: CGSize)] = []
        var currentWidth: CGFloat = 0
        for (index, size) in sizes.enumerated() {
            if !current.isEmpty {
                let fits = proposedWidth
                    .map { currentWidth + minimumLineGap + size.width <= $0 + 0.001 }
                    ?? true
                if !fits {
                    lines.append(current)
                    current = []
                    currentWidth = 0
                }
            }
            currentWidth += (current.isEmpty ? 0 : minimumLineGap) + size.width
            current.append((index, size))
        }
        if !current.isEmpty { lines.append(current) }

        let lineHeights = lines.map { line in line.map(\.size.height).max() ?? 0 }
        let lineWidths = lines.map { line in line.map(\.size.width).reduce(0, +) }
        let totalLineHeight = lineHeights.reduce(0, +)
        // Space-evenly shares lineCount + 1 vertical gaps, so the intrinsic
        // height must reserve every one of them; otherwise the rendered gap
        // shrinks below the requested minimum. A single-line row keeps its
        // natural height because there is nothing to separate.
        let minimumVerticalGap = lines.count > 1 ? minimumLineGap : 0
        let intrinsicHeight = totalLineHeight + minimumVerticalGap * CGFloat(lines.count + 1)

        // Without a proposed width nothing spreads: the size hugs the content,
        // including the minimum gaps between neighboring items.
        let intrinsicWidths = lines.indices.map { lineWidths[$0] + minimumLineGap * CGFloat(lines[$0].count - 1) }
        let width = proposedWidth ?? (intrinsicWidths.max() ?? 0)
        let height = max(intrinsicHeight, proposedHeight ?? 0)

        // Space-evenly: the items of a line share count + 1 equal horizontal
        // gaps, and the lines share lineCount + 1 equal vertical gaps.
        let verticalGap = max(0, (height - totalLineHeight) / CGFloat(lines.count + 1))

        var placements = [Placement](repeating: Placement(x: 0, y: 0, line: 0), count: sizes.count)
        for (lineIndex, line) in lines.enumerated() {
            let lineTop = verticalGap * CGFloat(lineIndex + 1)
                + lineHeights[..<lineIndex].reduce(0, +)
            let gap: CGFloat
            var leading: CGFloat
            if let proposedWidth {
                gap = max(0, (proposedWidth - lineWidths[lineIndex]) / CGFloat(line.count + 1))
                leading = gap
            } else {
                gap = minimumLineGap
                leading = 0
            }
            for entry in line {
                // Items top-align within their line: the gauges inside the
                // items (always leading) line up across the row even when
                // their trailing labels wrap to different line counts.
                placements[entry.index] = Placement(
                    x: leading,
                    y: lineTop,
                    line: lineIndex
                )
                leading += gap + entry.size.width
            }
        }

        return Result(placements: placements, size: CGSize(width: width, height: height))
    }
}
