import XCTest

@testable import CodexDashboard

@MainActor
final class AppCoordinatorTests: XCTestCase {
    enum AccountTestError: Error { case mountFailed }

    func testUnavailableAccountPopoverUsesSlowRetry() {
        XCTAssertEqual(
            AccountPopoverActionListener.Schedule.unavailableRetry(active: true),
            .seconds(10)
        )
        XCTAssertEqual(
            AccountPopoverActionListener.Schedule.unavailableRetry(active: false),
            .seconds(60)
        )
    }

    func testLiveProjectMonitoringKeepsRunningAndUnreadProjectsWithinItsBound() {
        let historicalThreads = (0..<70).map { index in
            ThreadSummary.fixture(
                id: "historical-\(index)",
                projectPath: "/tmp/historical-\(index)",
                recencyEpochMillis: Int64(1_000 - index)
            )
        }
        let priorityThreads = [
            ThreadSummary.fixture(
                id: "running", projectPath: "/tmp/running", recencyEpochMillis: 1, runState: .running
            ),
            ThreadSummary.fixture(
                id: "unread", projectPath: "/tmp/unread", recencyEpochMillis: 2, isUnread: true
            ),
        ]

        let paths = AppCoordinator.liveMonitoredProjectPaths(in: historicalThreads + priorityThreads)

        XCTAssertEqual(paths.count, 60)
        XCTAssertTrue(paths.contains("/tmp/running"))
        XCTAssertTrue(paths.contains("/tmp/unread"))
    }

    func waitUntil(
        timeout: Duration = .seconds(2),
        condition: @escaping () async -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        let conditionWasMet = await condition()
        XCTAssertTrue(conditionWasMet)
    }
}
