import XCTest
@testable import CodexDashboard

@MainActor
final class ReviewLoopHistoryTests: ReviewLoopTestCase {
    func testUpdateTimestampPersistsAndHistoryDeletionKeepsOtherTimestamps() throws {
        let (_, store, _) = try make()
        let startedAt = try XCTUnwrap(store.loops.first?.updatedAt)
        XCTAssertEqual(startedAt, Date.now.timeIntervalSince1970, accuracy: 2)
        store.loops[0].phase = .paused
        store.loops[0].updatedAt = 1
        let restored = ReviewLoopCoordinator(store: store)
        XCTAssertEqual(restored.loops[0].updatedAt, 1)
        stop(restored)
        let stopped = try XCTUnwrap(store.loops.first)
        XCTAssertGreaterThan(try XCTUnwrap(stopped.updatedAt), startedAt - 1)
        let decoded = try JSONDecoder().decode(ReviewLoop.self, from: JSONEncoder().encode(stopped))
        XCTAssertEqual(decoded.updatedAt, stopped.updatedAt)
        let display = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(
            ReviewLoopDisplaySnapshot(loop: stopped))) as? [String: Any])
        XCTAssertEqual(display["updatedAt"] as? Double, stopped.updatedAt)

        try restored.apply(startAction(id: "second", kind: .start, projectID: project.id,
                                       promptContext: .general, maxRounds: 2, loopID: nil), projects: [project])
        let active = try XCTUnwrap(store.loops.last)
        try restored.apply(ReviewLoopAction(id: "delete", kind: .delete, projectID: nil,
                                           promptContext: nil, maxRounds: nil, loopID: stopped.id), projects: [project])
        XCTAssertEqual(store.loops, [active])
    }

    func testDeletingPreviousReviewsPreservesActiveLoopsAndSelectedBoundary() throws {
        let store = ReviewTestStore()
        func loop(_ name: String, phase: ReviewLoopPhase) -> ReviewLoop {
            var loop = ReviewLoop(id: UUID(), startActionID: name, project: project,
                                  promptContext: .general, maxRounds: 2)
            loop.phase = phase
            return loop
        }
        let oldest = loop("oldest", phase: .completed)
        let active = loop("active", phase: .paused)
        let middle = loop("middle", phase: .stopped)
        let newest = loop("newest", phase: .limitReached)
        store.loops = [oldest, active, middle, newest]
        let coordinator = ReviewLoopCoordinator(store: store)
        func deletion(_ kind: ReviewLoopAction.Kind, id: UUID? = nil) -> ReviewLoopAction {
            ReviewLoopAction(id: UUID().uuidString, kind: kind, projectID: nil,
                             promptContext: nil, maxRounds: nil, loopID: id)
        }

        try coordinator.apply(deletion(.deleteOlder, id: middle.id), projects: [])
        XCTAssertEqual(coordinator.loops.map(\.id), [active.id, middle.id, newest.id])
        try coordinator.apply(deletion(.delete, id: newest.id), projects: [])
        XCTAssertEqual(coordinator.loops.map(\.id), [active.id, middle.id])
        try coordinator.apply(deletion(.deleteAll), projects: [])
        XCTAssertEqual(coordinator.loops.map(\.id), [active.id])
        XCTAssertEqual(store.loops.map(\.id), [active.id])
        XCTAssertThrowsError(try coordinator.apply(deletion(.delete, id: active.id), projects: []))
    }

    func testFailedReviewDeletionKeepsSavedAndDisplayedHistory() throws {
        let store = ReviewTestStore()
        var finished = ReviewLoop(id: UUID(), startActionID: "old", project: project,
                                  promptContext: .general, maxRounds: 1)
        finished.phase = .completed
        store.loops = [finished]
        let coordinator = ReviewLoopCoordinator(store: store)
        store.failSave = true
        let action = ReviewLoopAction(id: "delete", kind: .deleteAll, projectID: nil,
                                      promptContext: nil, maxRounds: nil, loopID: nil)
        XCTAssertThrowsError(try coordinator.apply(action, projects: []))
        XCTAssertEqual(coordinator.loops, [finished])
        XCTAssertEqual(store.loops, [finished])
    }
}
