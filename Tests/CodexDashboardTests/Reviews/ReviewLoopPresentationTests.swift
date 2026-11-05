import XCTest
@testable import CodexDashboard

@MainActor
final class ReviewLoopPresentationTests: ReviewLoopTestCase {
    func testDisplayCountIncludesCompletedRoundsAndExcludesBlockedAndPendingRounds() throws {
        var loop = ReviewLoop(id: UUID(), startActionID: "display", project: project,
                              promptContext: .general, maxRounds: 5)
        loop.rounds = [
            ReviewRound(number: 1, baseRevision: "base", result: ReviewRoundResult(
                outcome: .fixed, addressedFindingCount: 1, fixCommit: "fixed", summary: "Fixed")),
            ReviewRound(number: 2, baseRevision: "fixed", result: ReviewRoundResult(
                outcome: .withdrawn, addressedFindingCount: 0, fixCommit: nil, summary: "Withdrawn")),
            ReviewRound(number: 3, baseRevision: "fixed", result: ReviewRoundResult(
                outcome: .blocked, addressedFindingCount: 0, fixCommit: nil, summary: "Blocked")),
            ReviewRound(number: 4, baseRevision: "fixed"),
        ]
        let display = try JSONSerialization.jsonObject(with: JSONEncoder().encode(
            ReviewLoopDisplaySnapshot(loop: loop))) as? [String: Any]
        XCTAssertEqual(display?["completedRoundCount"] as? Int, 2)
        XCTAssertEqual(display?["id"] as? String, loop.id.uuidString)
        XCTAssertEqual((display?["rounds"] as? [Any])?.count, 4)
        let saved = try JSONSerialization.jsonObject(with: JSONEncoder().encode(loop)) as? [String: Any]
        XCTAssertNil(saved?["completedRoundCount"], "Derived counts must not be persisted")
        XCTAssertNil(saved?["isFinished"], "Derived phase state must not be persisted")
    }

    func testDisplaySnapshotMarksOnlyTerminalPhasesAsFinished() throws {
        let cases: [(ReviewLoopPhase, Bool)] = [
            (.waiting, false), (.running, false), (.paused, false),
            (.blocked, false), (.awaitingExtensionReload, false), (.stopping, false),
            (.completed, true), (.limitReached, true), (.stopped, true),
        ]
        for (phase, expected) in cases {
            var loop = ReviewLoop(id: UUID(), startActionID: "display", project: project,
                                  promptContext: .general, maxRounds: 5)
            loop.phase = phase
            let display = try JSONSerialization.jsonObject(with: JSONEncoder().encode(
                ReviewLoopDisplaySnapshot(loop: loop))) as? [String: Any]
            XCTAssertEqual(display?["isFinished"] as? Bool, expected, "Phase: \(phase)")
        }
    }

    func testProgressShowsConfiguredAndConditionalPromptPreviews() async throws {
        let (coordinator, _, driver) = try make()
        XCTAssertNil(coordinator.progress[coordinator.loops.last!.id.uuidString]?.current)
        XCTAssertEqual(coordinator.progress[coordinator.loops.last!.id.uuidString]?.upcoming.preview?.text, "Review project for bugs and issues." + reviewBoundary)
        XCTAssertEqual(coordinator.progress[coordinator.loops.last!.id.uuidString]?.upcoming.preview?.note,
                       "After the project is idle and workspace checks pass.")
        await coordinator.advance(using: driver, threads: [])
        XCTAssertEqual(coordinator.progress[coordinator.loops.last!.id.uuidString]?.step, "Reviewing")
        XCTAssertEqual(coordinator.progress[coordinator.loops.last!.id.uuidString]?.current?.text, driver.prompts.last)
        XCTAssertTrue(coordinator.progress[coordinator.loops.last!.id.uuidString]?.upcoming.preview?.note.contains("Only if") == true)
        driver.review(priorities: [.p1, .p2])
        await coordinator.advance(using: driver, threads: [])
        XCTAssertEqual(coordinator.progress[coordinator.loops.last!.id.uuidString]?.step, "Preparing fixes")
        XCTAssertEqual(coordinator.progress[coordinator.loops.last!.id.uuidString]?.upcoming.preview?.note,
                       "After workspace checks pass.")
        XCTAssertEqual(coordinator.progress[coordinator.loops.last!.id.uuidString]?.upcoming.preview?.text, "Fix both findings and commit. Verify each finding first. Mark invalid findings as withdrawn; if all are invalid, make no commit.")
        await coordinator.advance(using: driver, threads: [])
        XCTAssertEqual(coordinator.progress[coordinator.loops.last!.id.uuidString]?.current?.text, driver.prompts.last)
        XCTAssertEqual(coordinator.progress[coordinator.loops.last!.id.uuidString]?.upcoming.preview?.text, "Review project for bugs and issues." + reviewBoundary)
        try coordinator.apply(action(.pause, for: coordinator), projects: [project])
        XCTAssertTrue(coordinator.progress[coordinator.loops.last!.id.uuidString]?.upcoming.preview?.note.contains("resume") == true)
        driver.finish(findings: 2, commit: "fixed")
        await coordinator.advance(using: driver, threads: [])
        XCTAssertEqual(coordinator.progress[coordinator.loops.last!.id.uuidString]?.step, "Paused")
        XCTAssertEqual(coordinator.progress[coordinator.loops.last!.id.uuidString]?.upcoming.preview?.note,
                       "After you resume and workspace checks pass.")
        XCTAssertEqual(coordinator.progress[coordinator.loops.last!.id.uuidString]?.upcoming.preview?.text, "Review project for bugs and issues." + reviewBoundary)
        try coordinator.apply(action(.stop, for: coordinator), projects: [project])
        XCTAssertNil(coordinator.progress[coordinator.loops.last!.id.uuidString]?.upcoming.preview)
    }

    func testProgressDoesNotQueuePastRoundLimitOrCleanReview() async throws {
        let (coordinator, _, driver) = try make(limit: 1)
        await coordinator.advance(using: driver, threads: [])
        driver.review(priorities: [.p1])
        await coordinator.advance(using: driver, threads: [])
        XCTAssertNotNil(coordinator.progress[coordinator.loops.last!.id.uuidString]?.upcoming.preview)
        await coordinator.advance(using: driver, threads: [])
        XCTAssertNil(coordinator.progress[coordinator.loops.last!.id.uuidString]?.upcoming.preview)
        XCTAssertEqual(coordinator.progress[coordinator.loops.last!.id.uuidString]?.upcoming.message,
                       "Final round in progress; no further review scheduled.")
        driver.finish(findings: 1, commit: "fixed")
        await coordinator.advance(using: driver, threads: [])
        XCTAssertEqual(coordinator.progress[coordinator.loops.last!.id.uuidString]?.step, "Round limit reached")
        XCTAssertEqual(coordinator.progress[coordinator.loops.last!.id.uuidString]?.upcoming.message,
                       "No further prompts scheduled.")
        let (clean, _, cleanDriver) = try make()
        await clean.advance(using: cleanDriver, threads: [])
        cleanDriver.review(priorities: [])
        await clean.advance(using: cleanDriver, threads: [])
        XCTAssertEqual(clean.progress[clean.loops.last!.id.uuidString]?.step, "Complete")
        XCTAssertNil(clean.progress[clean.loops.last!.id.uuidString]?.upcoming.preview)
    }

    func testUpcomingPromptEncodesOneStateForRenderer() throws {
        let preview = ReviewPromptPreview(title: "Review", text: "Inspect files", note: "")
        let prompt = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(
            UpcomingReviewPrompt.prompt(preview: preview))) as? [String: Any])
        let unavailable = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(
            UpcomingReviewPrompt.unavailable(message: "No further prompts scheduled."))) as? [String: Any])

        XCTAssertEqual(Set(prompt.keys), ["prompt"])
        XCTAssertEqual((prompt["prompt"] as? [String: [String: String]])?["preview"]?["text"], preview.text)
        XCTAssertEqual(Set(unavailable.keys), ["unavailable"])
        XCTAssertEqual((unavailable["unavailable"] as? [String: String])?["message"], "No further prompts scheduled.")
    }
}
