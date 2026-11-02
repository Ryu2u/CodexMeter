import XCTest
@testable import CodexMeterCore

final class EvenFlowDistributionTests: XCTestCase {
    private func resolve(
        _ sizes: [CGSize],
        width: CGFloat? = nil,
        height: CGFloat? = nil,
        minimumLineGap: CGFloat = 10
    ) -> EvenFlowDistribution.Result {
        EvenFlowDistribution.resolve(
            sizes: sizes,
            proposedWidth: width,
            proposedHeight: height,
            minimumLineGap: minimumLineGap
        )
    }

    func testEmptySizesReturnZeroSize() {
        let result = resolve([])
        XCTAssertEqual(result.placements, [])
        XCTAssertEqual(result.size, .zero)
    }

    func testSingleLineDistributesEvenlyAcrossFullWidth() {
        // Four 48pt-wide rings on a 348pt row: five equal gaps of 31.2pt.
        let sizes = Array(repeating: CGSize(width: 48, height: 60), count: 4)
        let result = resolve(sizes, width: 348)
        XCTAssertEqual(result.size, CGSize(width: 348, height: 60))
        XCTAssertEqual(result.placements.map(\.line), [0, 0, 0, 0])

        let gap: CGFloat = (348 - 4 * 48) / 5
        XCTAssertEqual(result.placements[0].x, gap, accuracy: 0.01)
        XCTAssertEqual(result.placements[1].x, gap * 2 + 48, accuracy: 0.01)
        XCTAssertEqual(result.placements[3].x, gap * 4 + 3 * 48, accuracy: 0.01)
        XCTAssertEqual(result.placements[0].y, 0, accuracy: 0.01)
    }

    func testWrapsIntoLinesWhenWidthTooNarrow() {
        // Two 48pt rings plus the 10pt minimum gap need 106pt, so a 110pt row
        // still fits pairs: lines [0,1] and [2,3].
        let sizes = Array(repeating: CGSize(width: 48, height: 60), count: 4)
        let result = resolve(sizes, width: 110, minimumLineGap: 10)
        XCTAssertEqual(result.placements.map(\.line), [0, 0, 1, 1])
        XCTAssertEqual(result.size.width, 110, accuracy: 0.01)
        // Intrinsic height: two 60pt lines plus three equal 10pt gaps (top,
        // between, bottom), so the rendered gap never drops below the
        // requested minimum.
        XCTAssertEqual(result.size.height, 150, accuracy: 0.01)
        XCTAssertEqual(result.placements[0].y, 10, accuracy: 0.01)
        XCTAssertEqual(result.placements[2].y, 80, accuracy: 0.01)
        let gapBetweenLines = result.placements[2].y - (result.placements[0].y + 60)
        XCTAssertGreaterThanOrEqual(gapBetweenLines, 10)

        let gap = (110.0 - 96.0) / 3.0
        XCTAssertEqual(result.placements[0].x, gap, accuracy: 0.01)
        XCTAssertEqual(result.placements[1].x, gap * 2 + 48, accuracy: 0.01)
        XCTAssertEqual(result.placements[2].x, gap, accuracy: 0.01)
    }

    func testWrappedLinesKeepAtLeastTheMinimumLineGap() {
        // Three wrapped 60pt-wide rows each take their own line; the equal
        // vertical gap stays exactly at the requested minimum.
        let sizes = Array(repeating: CGSize(width: 60, height: 40), count: 3)
        let result = resolve(sizes, width: 60, minimumLineGap: 10)
        XCTAssertEqual(result.placements.map(\.line), [0, 1, 2])
        XCTAssertEqual(result.size.height, 40 * 3 + 10 * 4, accuracy: 0.01)
        for index in 0..<3 {
            XCTAssertEqual(result.placements[index].y, 10 + CGFloat(index) * 50, accuracy: 0.01)
        }
    }

    func testOversizedItemWrapsAloneWithoutNegativeGaps() {
        // A single ring wider than the row occupies its own line with the gap
        // clamped to zero instead of overlapping neighbors.
        let result = resolve([CGSize(width: 120, height: 60), CGSize(width: 40, height: 60)], width: 100)
        XCTAssertEqual(result.placements.map(\.line), [0, 1])
        XCTAssertEqual(result.placements[0].x, 0, accuracy: 0.01)
        XCTAssertEqual(result.placements[1].x, (100 - 40) / 2, accuracy: 0.01)
    }

    func testTallerProposalDistributesLinesEvenlyVertically() {
        // Two 60pt lines inside a 200pt-tall row: three equal vertical gaps of
        // 80/3pt with the block vertically spread edge to edge.
        let sizes = Array(repeating: CGSize(width: 48, height: 60), count: 4)
        let result = resolve(sizes, width: 110, height: 200, minimumLineGap: 10)
        XCTAssertEqual(result.size, CGSize(width: 110, height: 200))

        let gap = (200.0 - 120.0) / 3.0
        XCTAssertEqual(result.placements[0].y, gap, accuracy: 0.01)
        XCTAssertEqual(result.placements[2].y, gap * 2 + 60, accuracy: 0.01)
    }

    func testShorterProposalKeepsIntrinsicHeight() {
        let sizes = Array(repeating: CGSize(width: 48, height: 60), count: 4)
        let result = resolve(sizes, width: 110, height: 50, minimumLineGap: 10)
        XCTAssertEqual(result.size.height, 150, accuracy: 0.01)
    }

    func testItemsTopAlignWithinTheirLine() {
        // A short item (one-line label) sharing a line with taller ones
        // top-aligns so the gauges inside every item line up; only the
        // taller items' labels extend further down.
        let result = resolve([CGSize(width: 48, height: 60), CGSize(width: 48, height: 40)], width: 348)
        XCTAssertEqual(result.placements[0].y, 0, accuracy: 0.01)
        XCTAssertEqual(result.placements[1].y, 0, accuracy: 0.01)
        XCTAssertEqual(result.size.height, 60, accuracy: 0.01)
    }

    func testUnspecifiedWidthKeepsSingleLineWithMinimumGaps() {
        // Without a proposed width nothing wraps; items keep the minimum gap
        // between them and the size hugs the content.
        let sizes = Array(repeating: CGSize(width: 48, height: 60), count: 4)
        let result = resolve(sizes, minimumLineGap: 10)
        XCTAssertEqual(result.placements.map(\.line), [0, 0, 0, 0])
        XCTAssertEqual(result.size, CGSize(width: 48 * 4 + 10 * 3, height: 60))
        XCTAssertEqual(result.placements[1].x, 58, accuracy: 0.01)
        XCTAssertEqual(result.placements[3].x, 174, accuracy: 0.01)
    }
}
