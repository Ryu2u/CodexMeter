import XCTest
@testable import CodexMeterCore

final class PopoverContentConfigurationTests: XCTestCase {
    func testDefaultsKeepReserveQuotaHiddenWithoutMenuBarSelection() {
        let configuration = PopoverContentConfiguration.defaultValue
        let fiveHour = makeWindow(id: "codex-primary", name: "5h", duration: 300, used: 20)
        let weekly = makeWindow(
            id: "codex-secondary",
            name: "Weekly quota",
            duration: 10_080,
            used: 30
        )
        let reserve = makeWindow(
            id: "base_model_inference-primary",
            name: "GPT-Reserve · Weekly quota",
            duration: 10_080,
            used: 0
        )

        XCTAssertTrue(configuration.isQuotaWindowVisible(fiveHour))
        XCTAssertTrue(configuration.isQuotaWindowVisible(weekly))
        XCTAssertFalse(configuration.isQuotaWindowVisible(reserve))
        XCTAssertNil(configuration.menuBarQuotaWindowID)
    }

    func testQuotaWindowsCanBeHiddenIndependentlyByStableIdentity() {
        var configuration = PopoverContentConfiguration.defaultValue
        let fiveHour = makeWindow(id: "codex-primary", name: "5h", duration: 300, used: 20)
        let weekly = makeWindow(id: "codex-secondary", name: "Weekly", duration: 10_080, used: 30)

        configuration.setQuotaWindow(fiveHour, visible: false)

        XCTAssertFalse(configuration.isQuotaWindowVisible(fiveHour))
        XCTAssertTrue(configuration.isQuotaWindowVisible(weekly))
        XCTAssertEqual(configuration.visibleQuotaWindows(from: [fiveHour, weekly]), [weekly])
    }

    func testSlotSuffixesDoNotSplitTheSameQuotaBucket() {
        // The quota slots can swap between refreshes, so identity follows the
        // quota bucket and duration instead of the slot position.
        let primary = makeWindow(id: "codex-primary", name: "Weekly", duration: 10_080, used: 10)
        let secondary = makeWindow(id: "codex-secondary", name: "Weekly", duration: 10_080, used: 40)

        XCTAssertEqual(primary.historyID, secondary.historyID)
    }

    func testSelectedMenuBarWindowUsesPersistedStableIdentity() {
        var configuration = PopoverContentConfiguration.defaultValue
        let fiveHour = makeWindow(id: "codex-primary", name: "5h", duration: 300, used: 80)
        let weekly = makeWindow(id: "codex-secondary", name: "Weekly", duration: 10_080, used: 20)

        configuration.menuBarQuotaWindowID = weekly.historyID

        XCTAssertEqual(configuration.selectedMenuBarWindow(from: [fiveHour, weekly]), weekly)
    }

    func testMissingMenuBarSelectionFallsBackToPreferredWindow() {
        var configuration = PopoverContentConfiguration.defaultValue
        configuration.menuBarQuotaWindowID = "duration:999:missing"
        let fiveHour = makeWindow(id: "codex-primary", name: "5h", duration: 300, used: 80)
        let weekly = makeWindow(id: "codex-secondary", name: "Weekly", duration: 10_080, used: 20)

        XCTAssertEqual(configuration.selectedMenuBarWindow(from: [weekly, fiveHour]), fiveHour)
    }

    func testAutomaticSelectionPrefersFiveHourOverMoreConstrainedWeekly() {
        let configuration = PopoverContentConfiguration.defaultValue
        let fiveHour = makeWindow(id: "codex-primary", name: "5h", duration: 300, used: 20)
        let weekly = makeWindow(
            id: "codex-secondary",
            name: "Weekly quota",
            duration: 10_080,
            used: 90
        )

        XCTAssertEqual(configuration.selectedMenuBarWindow(from: [fiveHour, weekly]), fiveHour)
    }

    func testAutomaticSelectionFallsBackToWeeklyWhenFiveHourMissing() {
        let configuration = PopoverContentConfiguration.defaultValue
        let weekly = makeWindow(id: "codex-secondary", name: "Weekly quota", duration: 10_080, used: 40)
        let daily = makeWindow(id: "other-daily", name: "Daily", duration: 1_440, used: 5)

        XCTAssertEqual(configuration.selectedMenuBarWindow(from: [daily, weekly]), weekly)
    }

    func testAutomaticSelectionUsesLowestRemainingAcrossWeeklyBuckets() {
        let configuration = PopoverContentConfiguration.defaultValue
        let reserve = makeWindow(
            id: "base_model_inference-primary",
            name: "GPT-Reserve · Weekly quota",
            duration: 10_080,
            used: 90
        )
        let weekly = makeWindow(
            id: "codex-secondary",
            name: "Weekly quota",
            duration: 10_080,
            used: 76
        )

        XCTAssertEqual(configuration.selectedMenuBarWindow(from: [reserve, weekly]), reserve)
    }

    func testAutomaticSelectionUsesMostConstrainedForUnknownQuotaShapes() {
        let configuration = PopoverContentConfiguration.defaultValue
        let sixHour = makeWindow(id: "plan-a", name: "6h", duration: 360, used: 90)
        let daily = makeWindow(id: "plan-b", name: "Daily", duration: 1_440, used: 10)

        XCTAssertEqual(configuration.selectedMenuBarWindow(from: [sixHour, daily]), sixHour)
    }

    func testDecodingEmptyPreferencesUsesCurrentDefaults() throws {
        let configuration = try JSONDecoder().decode(
            PopoverContentConfiguration.self,
            from: Data("{}".utf8)
        )

        XCTAssertEqual(configuration, .defaultValue)
    }

    func testDecodingIgnoresRemovedSectionPreferences() throws {
        let legacy = """
        {
          "sectionOrder": ["quotaWindows", "resetCredits"],
          "hiddenSections": ["quotaHistory"],
          "hiddenQuotaWindowIDs": ["duration:300:codex"],
          "menuBarQuotaWindowID": "duration:10080:codex"
        }
        """

        let configuration = try JSONDecoder().decode(
            PopoverContentConfiguration.self,
            from: Data(legacy.utf8)
        )

        XCTAssertEqual(configuration.hiddenQuotaWindowIDs, ["duration:300:codex"])
        XCTAssertEqual(configuration.menuBarQuotaWindowID, "duration:10080:codex")
    }

    private func makeWindow(
        id: String,
        name: String,
        duration: Int,
        used: Int
    ) -> CodexUsageWindow {
        CodexUsageWindow(
            id: id,
            name: name,
            usedPercent: used,
            windowDurationMins: duration,
            resetsAt: Date(timeIntervalSince1970: 2_000_000_000)
        )
    }
}
