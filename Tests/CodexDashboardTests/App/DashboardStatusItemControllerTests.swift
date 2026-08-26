import XCTest

@testable import CodexDashboard

@MainActor
final class DashboardStatusItemControllerTests: XCTestCase {
    private let positionKey = "NSStatusItem Preferred Position CodexDashboardStatusItem"

    func testRegistersVisibleDefaultStatusItemPosition() throws {
        let defaults = try makeDefaults()

        DashboardStatusItemController.registerDefaultPosition(in: defaults)

        XCTAssertEqual(defaults.integer(forKey: positionKey), 450)
    }

    func testPreservesUserSelectedStatusItemPosition() throws {
        let defaults = try makeDefaults()
        defaults.set(720, forKey: positionKey)

        DashboardStatusItemController.registerDefaultPosition(in: defaults)

        XCTAssertEqual(defaults.integer(forKey: positionKey), 720)
    }

    func testAccountUsageTitlesIncludeLimitsCountdownsAndBankedResets() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let usage = CodexAccountUsage(
            fiveHour: CodexUsageWindow(
                usedPercent: 18,
                resetsAt: now.addingTimeInterval(2 * 60 * 60 + 15 * 60)
            ),
            weekly: CodexUsageWindow(
                usedPercent: 42,
                resetsAt: now.addingTimeInterval(3 * 24 * 60 * 60 + 4 * 60 * 60)
            ),
            bankedResets: CodexBankedResetSummary(
                availableCount: 2,
                nextExpiration: now.addingTimeInterval(24 * 60 * 60)
            )
        )

        let titles = AccountUsageMenuFormatter.titles(
            for: .available(CodexAccountUsageSnapshot(usage: usage, fetchedAt: now)),
            now: now,
            locale: Locale(identifier: "en_GB"),
            timeZone: TimeZone(secondsFromGMT: 0)!
        )

        XCTAssertEqual(titles, [
            "5-hour: 82% remaining · resets in 2h 15m (18 May 2033 at 5:48)",
            "Weekly: 58% remaining · resets in 3d 4h (21 May 2033 at 7:33)",
            "Banked resets: 2 available · next expires in 1d (19 May 2033 at 3:33)",
        ])
    }

    func testStaleAccountUsageIsClearlyMarked() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let snapshot = CodexAccountUsageSnapshot(
            usage: CodexAccountUsage(
                fiveHour: CodexUsageWindow(usedPercent: 25, resetsAt: nil),
                weekly: nil
            ),
            fetchedAt: now
        )

        let titles = AccountUsageMenuFormatter.titles(
            for: .stale(snapshot),
            now: now
        )

        XCTAssertEqual(titles.first, "5-hour: 75% remaining")
        XCTAssertTrue(titles.last?.hasPrefix("Usage may be stale · updated ") == true)
    }

    func testInactiveAccountUsageIsClearlyMarkedAsCached() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let snapshot = CodexAccountUsageSnapshot(
            usage: CodexAccountUsage(
                fiveHour: CodexUsageWindow(usedPercent: 10, resetsAt: nil),
                weekly: CodexUsageWindow(usedPercent: 30, resetsAt: nil)
            ),
            fetchedAt: now
        )

        let titles = AccountUsageMenuFormatter.titles(
            for: .stale(snapshot),
            now: now,
            staleLabel: "Cached usage"
        )

        XCTAssertEqual(titles[0], "5-hour: 90% remaining")
        XCTAssertEqual(titles[1], "Weekly: 70% remaining")
        XCTAssertTrue(titles[2].hasPrefix("Cached usage · updated "))
    }

    func testLoadingAndUnavailableAccountUsageHaveUsefulPlaceholders() {
        XCTAssertEqual(
            AccountUsageMenuFormatter.titles(for: .loading(previous: nil)),
            ["Loading usage details…"]
        )
        XCTAssertEqual(
            AccountUsageMenuFormatter.titles(for: .unavailable),
            ["Usage details unavailable"]
        )
    }

    func testDashboardActionAvailabilityIsSharedAcrossPresentations() {
        let mounted = DashboardActionPresentation(
            connectionState: .dashboardMounted,
            isPerformingAction: false,
            isCheckingCompatibility: false
        )
        XCTAssertTrue(mounted.canOpen)
        XCTAssertTrue(mounted.canRestart)
        XCTAssertTrue(mounted.canDisable)

        let checking = DashboardActionPresentation(
            connectionState: .codexClosed,
            isPerformingAction: false,
            isCheckingCompatibility: true
        )
        XCTAssertFalse(checking.canOpen)
        XCTAssertFalse(checking.canRestart)
        XCTAssertFalse(checking.canDisable)

        let busy = DashboardActionPresentation(
            connectionState: .rendererAvailable,
            isPerformingAction: true,
            isCheckingCompatibility: false
        )
        XCTAssertFalse(busy.canOpen)
        XCTAssertFalse(busy.canRestart)
        XCTAssertFalse(busy.canDisable)
    }

    private func makeDefaults() throws -> UserDefaults {
        let suiteName = "DashboardStatusItemControllerTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        return defaults
    }
}
