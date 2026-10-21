import XCTest

@testable import CodexDashboard

final class ThreadQuestionTrackerTests: XCTestCase {
    private func thread(_ id: String, question: String?, at date: Date) -> ThreadSummary {
        var thread = ThreadSummary.fixture(id: id)
        thread.latestQuestionEvent = ThreadQuestionEvent(id: question, timestamp: date)
        return thread
    }

    func testBaselineDoesNotOpenHistoricalQuestionsAndNewQuestionOpensOnce() {
        let date = Date()
        let initial = thread("thread", question: "old", at: date.addingTimeInterval(-10))
        // Timestamp predates the observation, modelling a delayed rollout write.
        let next = thread("thread", question: "new", at: date.addingTimeInterval(-1))
        var tracker = ThreadQuestionTracker()
        XCTAssertNil(tracker.observeQuestions(in: [initial], observedAt: date))
        XCTAssertEqual(tracker.observeQuestions(in: [next], observedAt: date.addingTimeInterval(1)), "thread")
        XCTAssertNil(tracker.observeQuestions(in: [next], observedAt: date.addingTimeInterval(2)))
    }

    func testNewlyDiscoveredHistoricalQuestionAndResolvedQuestionAreIgnored() {
        let date = Date()
        var tracker = ThreadQuestionTracker()
        XCTAssertNil(tracker.observeQuestions(in: [], observedAt: date))
        XCTAssertNil(tracker.observeQuestions(in: [thread("old", question: "old", at: date.addingTimeInterval(-1))], observedAt: date.addingTimeInterval(1)))
        XCTAssertNil(tracker.observeQuestions(in: [thread("old", question: nil, at: date.addingTimeInterval(2))], observedAt: date.addingTimeInterval(3)))
    }

    func testNewestEligibleQuestionWinsAndExcludedQuestionsAreConsumed() {
        let date = Date()
        var tracker = ThreadQuestionTracker()
        XCTAssertNil(tracker.observeQuestions(in: [], observedAt: date))
        let threads = [
            thread("first", question: "a", at: date.addingTimeInterval(1)),
            thread("second", question: "b", at: date.addingTimeInterval(2)),
            thread("review", question: "c", at: date.addingTimeInterval(3)),
        ]
        XCTAssertEqual(tracker.observeQuestions(in: threads, excluding: ["review"], observedAt: date.addingTimeInterval(4)), "second")
        XCTAssertNil(tracker.observeQuestions(in: threads, observedAt: date.addingTimeInterval(5)))
    }
}
