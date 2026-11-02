import XCTest
@testable import CodexMeterCore

final class DeepSeekMenuBarBalanceFormatterTests: XCTestCase {
    func testKnownCurrencyGlyphsDoNotGainRegionalPrefixes() {
        let fixtures = [
            ("en_US", "CNY", "¥29.35"),
            ("en_US", "USD", "$29.35"),
            ("zh_Hans_CN", "CNY", "¥29.35"),
            ("zh_Hans_CN", "USD", "$29.35"),
            ("zh_Hant_TW", "CNY", "¥29.35"),
            ("zh_Hant_TW", "USD", "$29.35")
        ]
        for (locale, currency, expected) in fixtures {
            XCTAssertEqual(DeepSeekMenuBarBalanceFormatter.string(
                remaining: Decimal(string: "29.35")!, currency: currency, locale: Locale(identifier: locale)),
                expected, "\(locale) \(currency)")
        }
    }

    func testCurrencyGlyphPreservesEightDecimalPlaces() {
        XCTAssertEqual(DeepSeekMenuBarBalanceFormatter.string(
            remaining: Decimal(string: "0.12345678")!, currency: "CNY", locale: Locale(identifier: "en_US")),
            "¥0.12345678")
    }

    func testShortFractionRetainsTwoDecimalPlaces() {
        XCTAssertEqual(DeepSeekMenuBarBalanceFormatter.string(
            remaining: Decimal(string: "29.3")!, currency: "USD", locale: Locale(identifier: "en_US")),
            "$29.30")
    }

    func testCurrencyGlyphPreservesLocalizedGrouping() {
        XCTAssertEqual(DeepSeekMenuBarBalanceFormatter.string(
            remaining: Decimal(string: "12345.67890123")!, currency: "CNY", locale: Locale(identifier: "en_US")),
            "¥12,345.67890123")
    }

    func testZeroBalanceStillShowsCurrencyAndTwoDecimalPlaces() {
        XCTAssertEqual(DeepSeekMenuBarBalanceFormatter.string(
            remaining: 0, currency: "CNY", locale: Locale(identifier: "en_US")),
            "¥0.00")
    }
}
