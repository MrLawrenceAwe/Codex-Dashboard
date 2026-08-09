import XCTest

@testable import CodexDashboard

final class ThreadCompletionDetectorTests: XCTestCase {
    @MainActor
    func testNotificationBodyUsesAssistantResponseInsteadOfOpeningPrompt() {
        let thread = ThreadSummary.fixture(
            preview: "Initial user prompt",
            lastAssistantMessage: "  The actual\nCodex response.  "
        )

        XCTAssertEqual(
            MacThreadCompletionNotifier.notificationBody(for: thread),
            "The actual Codex response."
        )
    }

    @MainActor
    func testNotificationBodyUsesNeutralFallbackWithoutAssistantResponse() {
        let thread = ThreadSummary.fixture(
            preview: "Initial user prompt",
            projectName: "Dashboard"
        )

        XCTAssertEqual(
            MacThreadCompletionNotifier.notificationBody(for: thread),
            "Response ready in Dashboard"
        )
    }

    func testInitialSnapshotDoesNotNotifyForExistingIdleOrUnreadThreads() {
        var detector = ThreadCompletionDetector()
        var unread = ThreadSummary.fixture(id: "unread", runState: .idle)
        unread.isUnread = true

        XCTAssertTrue(detector.observe([unread]).isEmpty)
    }

    func testRunningToIdleTransitionProducesCompletion() {
        var detector = ThreadCompletionDetector()
        let running = ThreadSummary.fixture(id: "thread-1", runState: .running)
        let idle = ThreadSummary.fixture(id: "thread-1", runState: .idle)

        XCTAssertTrue(detector.observe([running]).isEmpty)
        XCTAssertEqual(detector.observe([idle]).map(\.id), ["thread-1"])
    }

    func testUnreadTransitionCatchesTurnMissedBetweenActivityPolls() {
        var detector = ThreadCompletionDetector()
        let idle = ThreadSummary.fixture(id: "thread-1", runState: .idle)
        var unread = idle
        unread.isUnread = true

        XCTAssertTrue(detector.observe([idle]).isEmpty)
        XCTAssertEqual(detector.observe([unread]).map(\.id), ["thread-1"])
    }

    func testUnreadTransitionDoesNotDuplicateRunningToIdleCompletion() {
        var detector = ThreadCompletionDetector()
        let running = ThreadSummary.fixture(id: "thread-1", runState: .running)
        let idle = ThreadSummary.fixture(id: "thread-1", runState: .idle)
        var unread = idle
        unread.isUnread = true

        _ = detector.observe([running])
        XCTAssertEqual(detector.observe([idle]).map(\.id), ["thread-1"])
        XCTAssertTrue(detector.observe([unread]).isEmpty)
    }

    func testReadingThreadAllowsFutureUnreadFallback() {
        var detector = ThreadCompletionDetector()
        let read = ThreadSummary.fixture(id: "thread-1", runState: .idle)
        var unread = read
        unread.isUnread = true

        _ = detector.observe([read])
        XCTAssertEqual(detector.observe([unread]).count, 1)
        XCTAssertTrue(detector.observe([read]).isEmpty)
        XCTAssertEqual(detector.observe([unread]).count, 1)
    }
}
