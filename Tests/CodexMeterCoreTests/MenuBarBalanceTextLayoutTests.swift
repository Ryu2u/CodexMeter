import XCTest
@testable import CodexMeterCore

final class MenuBarBalanceTextLayoutTests: XCTestCase {
    func testAmountWiderThanPercentageColumnGetsItsMeasuredWidth() {
        let layout = MenuBarBalanceTextLayout(amountWidth: 72, captionWidth: 12, appearance: .acceptedV1)

        XCTAssertEqual(layout.width, 74)
        XCTAssertEqual(layout.fontSize, 10.5)
        XCTAssertFalse(layout.truncatesAmount)
    }

    func testShortAmountKeepsPreferredColumnWidth() {
        let layout = MenuBarBalanceTextLayout(amountWidth: 18, captionWidth: 12, appearance: .acceptedV1)

        XCTAssertEqual(layout.width, 40)
        XCTAssertEqual(layout.fontSize, 10.5)
        XCTAssertFalse(layout.truncatesAmount)
    }

    func testPreviewCaptionCanWidenTheColumnWithoutScalingTheAmount() {
        let layout = MenuBarBalanceTextLayout(amountWidth: 18, captionWidth: 62, appearance: .acceptedV1)

        XCTAssertEqual(layout.width, 64)
        XCTAssertEqual(layout.fontSize, 10.5)
        XCTAssertFalse(layout.truncatesAmount)
    }

    func testLongPreciseAmountFitsWithoutRemovingFractionDigits() {
        let layout = MenuBarBalanceTextLayout(amountWidth: 115.25, captionWidth: 12, appearance: .acceptedV1)

        XCTAssertEqual(layout.width, 118)
        XCTAssertEqual(layout.fontSize, 10.5)
        XCTAssertFalse(layout.truncatesAmount)
    }

    func testAmountBeyondWidthLimitKeepsSharedFontAndTruncates() {
        var appearance = MenuBarAppearance.acceptedV1
        appearance.percentageFontSize = 14
        let layout = MenuBarBalanceTextLayout(amountWidth: 200, captionWidth: 12, appearance: appearance)

        XCTAssertEqual(layout.width, 160)
        XCTAssertEqual(layout.fontSize, 14)
        XCTAssertTrue(layout.truncatesAmount)
    }

    func testExtremeAmountKeepsSharedFontAndExplicitTruncation() {
        let layout = MenuBarBalanceTextLayout(amountWidth: 800, captionWidth: 12, appearance: .acceptedV1)

        XCTAssertEqual(layout.width, 160)
        XCTAssertEqual(layout.fontSize, 10.5)
        XCTAssertTrue(layout.truncatesAmount)
    }
}
