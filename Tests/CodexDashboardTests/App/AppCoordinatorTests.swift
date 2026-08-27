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
