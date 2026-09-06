import XCTest
@testable import CodexDashboard

final class TaskCompletionObserverTests: XCTestCase {
    func testBaselineAndAbortsAreIgnoredAndAllNewCompletionsAreReturnedOnce() {
        var observer = TaskCompletionObserver()
        let now = Date()
        let started = ThreadLifecycleEvent(kind: .started, timestamp: now)
        let baseline: [ThreadSummary] = [
            .fixture(id: "one", runState: .running, latestLifecycleEvent: started),
            .fixture(id: "two", runState: .running, latestLifecycleEvent: started),
            .fixture(id: "abort", runState: .running, latestLifecycleEvent: started),
            .fixture(id: "historical", latestLifecycleEvent: .init(kind: .completed, timestamp: now)),
        ]
        XCTAssertTrue(observer.recordSnapshotAndFindCompletions(in: baseline, observedAt: now).isEmpty)
        let updated: [ThreadSummary] = [
            .fixture(id: "one", latestLifecycleEvent: .init(kind: .completed, timestamp: now.addingTimeInterval(1))),
            .fixture(id: "two", latestLifecycleEvent: .init(kind: .completed, timestamp: now.addingTimeInterval(2))),
            .fixture(id: "abort", latestLifecycleEvent: .init(kind: .aborted, timestamp: now.addingTimeInterval(3))),
        ]
        XCTAssertEqual(observer.recordSnapshotAndFindCompletions(in: updated).map(\.id), ["two", "one"])
        XCTAssertTrue(observer.recordSnapshotAndFindCompletions(in: updated).isEmpty)
        XCTAssertTrue(observer.recordSnapshotAndFindCompletions(in: []).isEmpty)
        XCTAssertTrue(observer.recordSnapshotAndFindCompletions(in: updated).isEmpty)
    }

    func testTaskStartedAndCompletedBetweenPollsIsIncludedButOldHistoryIsNot() {
        var observer = TaskCompletionObserver()
        let now = Date()
        _ = observer.recordSnapshotAndFindCompletions(in: [], observedAt: now)
        let completions = observer.recordSnapshotAndFindCompletions(in: [
            .fixture(id: "new", latestLifecycleEvent: .init(kind: .completed, timestamp: now.addingTimeInterval(1))),
            .fixture(id: "old", latestLifecycleEvent: .init(kind: .completed, timestamp: now.addingTimeInterval(-1))),
        ], observedAt: now.addingTimeInterval(2))
        XCTAssertEqual(completions.map(\.id), ["new"])
    }

    func testOlderSnapshotDoesNotReplayACompletion() {
        var observer = TaskCompletionObserver()
        let now = Date()
        let started = ThreadSummary.fixture(latestLifecycleEvent: .init(kind: .started, timestamp: now))
        let completed = ThreadSummary.fixture(latestLifecycleEvent: .init(kind: .completed, timestamp: now.addingTimeInterval(1)))
        _ = observer.recordSnapshotAndFindCompletions(in: [started], observedAt: now)
        XCTAssertEqual(observer.recordSnapshotAndFindCompletions(in: [completed]).count, 1)
        XCTAssertTrue(observer.recordSnapshotAndFindCompletions(in: [started]).isEmpty)
        XCTAssertTrue(observer.recordSnapshotAndFindCompletions(in: [completed]).isEmpty)
    }
}
