import XCTest
@testable import CodexDashboard

@MainActor
final class ReviewLoopQueueTests: ReviewLoopTestCase {
    private func enqueue(_ coordinator: ReviewLoopCoordinator, id: String, project: ReviewProject? = nil) throws {
        let target = project ?? self.project
        var action = startAction(id: id, kind: .queue, projectID: target.id,
                                 promptContext: .personal, maxRounds: 2, loopID: nil)
        action.reviewType = .performance
        try coordinator.apply(action, projects: [target])
    }

    private func cancel(_ coordinator: ReviewLoopCoordinator, at index: Int) throws {
        try coordinator.apply(ReviewLoopAction(id: UUID().uuidString, kind: .stop, projectID: nil,
                                               promptContext: nil, maxRounds: nil,
                                               loopID: coordinator.loops[index].id), projects: [])
    }

    func testQueuePersistsSettingsAndWaitsBehindPausedAndBlockedPredecessor() async throws {
        let (coordinator, store, driver) = try make()
        try enqueue(coordinator, id: "queued")
        try enqueue(coordinator, id: "queued") // Replayed actions do not duplicate work.
        XCTAssertEqual(coordinator.loops.count, 2)
        XCTAssertEqual(coordinator.loops[1].phase, .queued)
        XCTAssertEqual(coordinator.loops[1].reviewType, .performance)
        XCTAssertEqual(coordinator.loops[1].promptContext, .personal)
        XCTAssertEqual(coordinator.loops[1].maxRounds, 2)
        let document = try JSONEncoder().encode(ReviewLoopsDocument(
            version: ReviewLoopsDocument.currentVersion, loops: store.loops))
        store.loops = try ReviewLoopDocumentMigration.decode(document)
        let restored = ReviewLoopCoordinator(store: store)
        XCTAssertEqual(restored.loops[0].phase, .paused)
        await restored.advance(using: driver, threads: [])
        XCTAssertEqual(driver.createCalls, 0)
        XCTAssertEqual(restored.loops[1].phase, .queued)
        store.loops[0].phase = .blocked
        let blocked = ReviewLoopCoordinator(store: store)
        await blocked.advance(using: driver, threads: [])
        XCTAssertEqual(driver.createCalls, 0)
        XCTAssertEqual(blocked.loops[1].phase, .queued)
        try blocked.apply(ReviewLoopAction(id: "resume", kind: .resume, projectID: nil,
                                          promptContext: nil, maxRounds: nil,
                                          loopID: blocked.loops[0].id), projects: [])
        XCTAssertEqual(blocked.loops[0].phase, .waiting)
        await blocked.advance(using: driver, threads: [])
        XCTAssertEqual(blocked.loops[0].phase, .running)
        XCTAssertEqual(blocked.loops[1].phase, .queued)
    }

    func testFIFOQueueStartsOnlyOneLoopAndCancellationReleasesNext() async throws {
        let (coordinator, _, driver) = try make()
        try enqueue(coordinator, id: "second")
        try enqueue(coordinator, id: "third")
        try cancel(coordinator, at: 0)
        await coordinator.advance(using: driver, threads: [])
        XCTAssertEqual(driver.createCalls, 1)
        XCTAssertEqual(coordinator.loops[1].phase, .running)
        XCTAssertEqual(coordinator.loops[2].phase, .queued)
        try cancel(coordinator, at: 1)
        await coordinator.advance(using: driver, threads: [])
        await coordinator.advance(using: driver, threads: [])
        XCTAssertEqual(driver.createCalls, 2)
        XCTAssertEqual(coordinator.loops[1].phase, .stopped)
        XCTAssertEqual(coordinator.loops[2].phase, .running)
    }

    func testCancellingQueuedLoopDoesNotInterruptActiveChat() async throws {
        let (coordinator, _, driver) = try make()
        await coordinator.advance(using: driver, threads: [])
        try enqueue(coordinator, id: "second")
        try cancel(coordinator, at: 1)
        await coordinator.advance(using: driver, threads: [])
        XCTAssertEqual(coordinator.loops[0].phase, .running)
        XCTAssertEqual(coordinator.loops[1].phase, .stopped)
        XCTAssertTrue(driver.interruptedTurns.isEmpty)
        XCTAssertEqual(driver.createCalls, 1)
    }

    func testCanonicalProjectAliasesQueueTogetherWhileOtherProjectsRun() async throws {
        let (coordinator, _, driver) = try make()
        let alias = ReviewProject(id: "alias", name: "Alias", path: "/tmp/example/../example")
        try enqueue(coordinator, id: "alias-loop", project: alias)
        let other = ReviewProject(id: "other", name: "Other", path: "/tmp/other")
        XCTAssertEqual(coordinator.projectChoices(for: [project, alias, other]).map(\.requiresQueue),
                       [true, true, false])
        XCTAssertThrowsError(try coordinator.apply(
            startAction(id: "alias-start", kind: .start, projectID: alias.id,
                        promptContext: .general, maxRounds: 2, loopID: nil), projects: [alias]))
        try enqueue(coordinator, id: "other-loop", project: other)
        await coordinator.advance(using: driver, threads: [])
        XCTAssertEqual(driver.createCalls, 2)
        XCTAssertEqual(coordinator.loops[1].phase, .queued)
        XCTAssertEqual(coordinator.loops[2].phase, .running)
    }

    func testProjectChoicesReleaseAliasesAfterTheLastLoopFinishes() async throws {
        let (coordinator, _, _) = try make()
        let alias = ReviewProject(id: "alias", name: "Alias", path: "/tmp/example/../example")
        XCTAssertTrue(try XCTUnwrap(coordinator.projectChoices(for: [alias]).first).requiresQueue)
        try cancel(coordinator, at: 0)
        XCTAssertFalse(try XCTUnwrap(coordinator.projectChoices(for: [alias]).first).requiresQueue)
    }

    func testCompletedPredecessorReleasesQueueAndLaunchStillChecksWorkspace() async throws {
        let (coordinator, _, driver) = try make()
        try enqueue(coordinator, id: "second")
        await coordinator.advance(using: driver, threads: [])
        driver.review(priorities: [])
        await coordinator.advance(using: driver, threads: [])
        XCTAssertEqual(coordinator.loops[0].phase, .completed)
        driver.clean = false
        await coordinator.advance(using: driver, threads: [])
        XCTAssertEqual(driver.createCalls, 1)
        XCTAssertEqual(coordinator.loops[1].phase, .blocked)
    }
}
