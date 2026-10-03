import XCTest
@testable import CodexDashboard

@MainActor
final class ReviewLoopPresentationTests: ReviewLoopTestCase {
    func testDisplayCountIncludesCompletedRoundsAndExcludesBlockedAndPendingRounds() throws {
        var loop = ReviewLoop(id: UUID(), startActionID: "display", project: project,
                              promptContext: .general, maxRounds: 5)
        loop.rounds = [
            ReviewRound(number: 1, baseCommit: "base", result: ReviewRoundResult(
                outcome: .fixed, addressedFindingCount: 1, commit: "fixed", summary: "Fixed")),
            ReviewRound(number: 2, baseCommit: "fixed", result: ReviewRoundResult(
                outcome: .withdrawn, addressedFindingCount: 0, commit: "", summary: "Withdrawn")),
            ReviewRound(number: 3, baseCommit: "fixed", result: ReviewRoundResult(
                outcome: .blocked, addressedFindingCount: 0, commit: "", summary: "Blocked")),
            ReviewRound(number: 4, baseCommit: "fixed"),
        ]
        let display = try JSONSerialization.jsonObject(with: JSONEncoder().encode(
            ReviewLoopDisplaySnapshot(loop: loop))) as? [String: Any]
        XCTAssertEqual(display?["completedRoundCount"] as? Int, 2)
        XCTAssertEqual(display?["id"] as? String, loop.id.uuidString)
        XCTAssertEqual((display?["rounds"] as? [Any])?.count, 4)
        let saved = try JSONSerialization.jsonObject(with: JSONEncoder().encode(loop)) as? [String: Any]
        XCTAssertNil(saved?["completedRoundCount"], "Derived counts must not be persisted")
    }

    func testProgressTracksSubmittedAndConditionalPrompts() async throws {
        let (coordinator, _, driver) = try make()
        XCTAssertNil(coordinator.progress[coordinator.loops.last!.id.uuidString]?.current)
        XCTAssertEqual(coordinator.progress[coordinator.loops.last!.id.uuidString]?.upcoming?.text, "Review project for bugs and issues." + reviewBoundary)
        await coordinator.advance(using: driver, threads: [])
        XCTAssertEqual(coordinator.progress[coordinator.loops.last!.id.uuidString]?.step, "Reviewing")
        XCTAssertEqual(coordinator.progress[coordinator.loops.last!.id.uuidString]?.current?.text, driver.prompts.last)
        XCTAssertTrue(coordinator.progress[coordinator.loops.last!.id.uuidString]?.upcoming?.note.contains("Only if") == true)
        driver.review(priorities: [.p1, .p2])
        await coordinator.advance(using: driver, threads: [])
        XCTAssertEqual(coordinator.progress[coordinator.loops.last!.id.uuidString]?.step, "Preparing fixes")
        XCTAssertEqual(coordinator.progress[coordinator.loops.last!.id.uuidString]?.upcoming?.text, "Fix both findings and commit. Verify each finding first. Mark invalid findings as withdrawn; if all are invalid, make no commit.")
        await coordinator.advance(using: driver, threads: [])
        XCTAssertEqual(coordinator.progress[coordinator.loops.last!.id.uuidString]?.current?.text, driver.prompts.last)
        XCTAssertEqual(coordinator.progress[coordinator.loops.last!.id.uuidString]?.upcoming?.text, "Review project for bugs and issues." + reviewBoundary)
        try coordinator.apply(action(.pause, for: coordinator), projects: [project])
        XCTAssertTrue(coordinator.progress[coordinator.loops.last!.id.uuidString]?.upcoming?.note.contains("resume") == true)
        driver.finish(findings: 2, commit: "fixed")
        await coordinator.advance(using: driver, threads: [])
        XCTAssertEqual(coordinator.progress[coordinator.loops.last!.id.uuidString]?.step, "Paused")
        XCTAssertEqual(coordinator.progress[coordinator.loops.last!.id.uuidString]?.upcoming?.text, "Review project for bugs and issues." + reviewBoundary)
        try coordinator.apply(action(.stop, for: coordinator), projects: [project])
        XCTAssertNil(coordinator.progress[coordinator.loops.last!.id.uuidString]?.upcoming)
        XCTAssertEqual(coordinator.progress[coordinator.loops.last!.id.uuidString]?.currentLabel, "Latest prompt")
    }

    func testProgressDoesNotQueuePastRoundLimitOrCleanReview() async throws {
        let (coordinator, _, driver) = try make(limit: 1)
        await coordinator.advance(using: driver, threads: [])
        driver.review(priorities: [.p1])
        await coordinator.advance(using: driver, threads: [])
        XCTAssertNotNil(coordinator.progress[coordinator.loops.last!.id.uuidString]?.upcoming)
        await coordinator.advance(using: driver, threads: [])
        XCTAssertNil(coordinator.progress[coordinator.loops.last!.id.uuidString]?.upcoming)
        let (clean, _, cleanDriver) = try make()
        await clean.advance(using: cleanDriver, threads: [])
        cleanDriver.review(priorities: [])
        await clean.advance(using: cleanDriver, threads: [])
        XCTAssertEqual(clean.progress[clean.loops.last!.id.uuidString]?.step, "Complete")
        XCTAssertNil(clean.progress[clean.loops.last!.id.uuidString]?.upcoming)
    }
}
