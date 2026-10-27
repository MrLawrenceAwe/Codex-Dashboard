import XCTest
@testable import CodexDashboard

@MainActor
final class ReviewLoopStoppingTests: ReviewLoopTestCase {

    func testStopDuringCommitResolutionDoesNotAdvance() async throws {
        let (coordinator, _, driver) = try make()
        await coordinator.advance(using: driver, threads: [])
        driver.review(priorities: [.p2])
        await coordinator.advance(using: driver, threads: [])
        await coordinator.advance(using: driver, threads: [])
        driver.finish(findings: 1, commit: "fixed")
        driver.onResolveCommit = { self.stop(coordinator) }
        await coordinator.advance(using: driver, threads: [])
        XCTAssertEqual(coordinator.loops.last?.phase, .stopped)
        XCTAssertNil(coordinator.loops.last?.rounds.last?.result)
    }

    func testStopInterruptsRunningReviewAndFixTasks() async throws {
        for fixing in [false, true] {
            let (coordinator, store, driver) = try make()
            await coordinator.advance(using: driver, threads: [])
            if fixing {
                driver.review(priorities: [.p1])
                await coordinator.advance(using: driver, threads: [])
                await coordinator.advance(using: driver, threads: [])
            }
            try coordinator.apply(action(.stop, for: coordinator), projects: [project])
            try await coordinator.stopRunningTask(for: coordinator.loops.last!.id, using: driver)
            XCTAssertEqual(driver.interruptedTurns, [fixing ? "turn-2" : "turn-1"])
            XCTAssertEqual(driver.thread.turns.last?.status, .interrupted)
            XCTAssertEqual(store.loops.last?.message, "Stopped loop and its running chat.")
            await coordinator.advance(using: driver, threads: [])
            XCTAssertEqual(driver.prompts.count, fixing ? 2 : 1)
        }
    }

    func testStopWithoutRunningTaskDoesNotInterruptCompletedTurn() async throws {
        let (coordinator, _, driver) = try make()
        await coordinator.advance(using: driver, threads: [])
        driver.review(priorities: [.p1])
        try coordinator.apply(action(.stop, for: coordinator), projects: [project])
        try await coordinator.stopRunningTask(for: coordinator.loops.last!.id, using: driver)
        XCTAssertTrue(driver.interruptedTurns.isEmpty)
        XCTAssertEqual(driver.thread.turns.last?.status, .completed)
    }

    func testInterruptFailureKeepsCheckoutReservedAndCanBeRetried() async throws {
        let (coordinator, store, driver) = try make()
        await coordinator.advance(using: driver, threads: [])
        driver.failStopThread = true
        try coordinator.apply(action(.stop, for: coordinator), projects: [project])
        do {
            try await coordinator.stopRunningTask(for: coordinator.loops.last!.id, using: driver)
            XCTFail("Expected interrupt failure")
        } catch { }
        XCTAssertEqual(store.loops.last?.phase, .stopping)
        XCTAssertTrue(store.loops.last!.message.contains("could not stop its chat"))
        driver.failStopThread = false
        try await coordinator.stopRunningTask(for: coordinator.loops.last!.id, using: driver)
        XCTAssertEqual(driver.interruptedTurns, ["turn-1"])
    }

    func testStopDuringWorkspaceCheckPreventsReviewLaunch() async throws {
        let (coordinator, _, driver) = try make()
        driver.onWorkspace = { self.stop(coordinator) }
        await coordinator.advance(using: driver, threads: [])
        XCTAssertEqual(coordinator.loops.last?.phase, .stopped)
        XCTAssertTrue(driver.createdThreads.isEmpty)
    }

    func testStopDuringThreadCreationRecordsThreadWithoutSendingPrompt() async throws {
        let (coordinator, store, driver) = try make()
        driver.onCreateThread = { self.stop(coordinator) }
        await coordinator.advance(using: driver, threads: [])
        XCTAssertEqual(coordinator.loops.last?.phase, .stopped)
        XCTAssertEqual(store.loops[store.loops.count - 1].rounds.last?.threadID, "thread-1")
        XCTAssertTrue(driver.prompts.isEmpty)
    }

    func testStopDuringPromptSubmissionRecordsTurnWithoutResumingLoop() async throws {
        let (coordinator, store, driver) = try make()
        driver.onStartTurn = { self.stop(coordinator) }
        await coordinator.advance(using: driver, threads: [])
        XCTAssertEqual(coordinator.loops.last?.phase, .stopped)
        XCTAssertEqual(store.loops[store.loops.count - 1].rounds.last?.reviewTurnID, "turn-1")
        XCTAssertEqual(driver.interruptedTurns, ["turn-1"])
        await coordinator.advance(using: driver, threads: [])
        XCTAssertEqual(driver.prompts.count, 1)
    }

    func testStopDuringReviewReadDoesNotSubmitFix() async throws {
        let (coordinator, _, driver) = try make()
        await coordinator.advance(using: driver, threads: [])
        driver.review(priorities: [.p1])
        driver.onReadThread = { self.stop(coordinator) }
        await coordinator.advance(using: driver, threads: [])
        XCTAssertEqual(coordinator.loops.last?.phase, .stopped)
        XCTAssertEqual(driver.prompts.count, 1)
    }

    func testStopDuringFixSubmissionKeepsStoppedPhaseAndTurnID() async throws {
        let (coordinator, store, driver) = try make()
        await coordinator.advance(using: driver, threads: [])
        driver.review(priorities: [.p1])
        await coordinator.advance(using: driver, threads: [])
        driver.onStartTurn = { self.stop(coordinator) }
        await coordinator.advance(using: driver, threads: [])
        XCTAssertEqual(coordinator.loops.last?.phase, .stopped)
        XCTAssertEqual(store.loops[store.loops.count - 1].rounds.last?.fixTurnID, "turn-2")
        XCTAssertEqual(driver.interruptedTurns, ["turn-2"])
    }

    func testPauseFinishesCurrentRoundAndStopDoesNotLaunchMore() async throws {
        let (coordinator, _, driver) = try make()
        await coordinator.advance(using: driver, threads: [])
        try coordinator.apply(action(.pause, for: coordinator), projects: [project])
        XCTAssertEqual(coordinator.loops.last?.phase, .running)
        driver.review(priorities: [.p2])
        await coordinator.advance(using: driver, threads: [])
        await coordinator.advance(using: driver, threads: [])
        driver.finish(findings: 1, commit: "fixed")
        await coordinator.advance(using: driver, threads: [])
        XCTAssertEqual(coordinator.loops.last?.phase, .paused)
        try coordinator.apply(action(.stop, for: coordinator), projects: [project])
        await coordinator.advance(using: driver, threads: [])
        XCTAssertEqual(coordinator.loops.last?.phase, .stopped)
        XCTAssertEqual(driver.createdThreads.count, 1)
    }
    func testDeletedChatReleasesStoppingLoopAndCheckoutAfterRestart() async throws {
        let (coordinator, store, driver) = try make()
        await coordinator.advance(using: driver, threads: [])
        driver.failStopThread = true
        stop(coordinator)
        await coordinator.advance(using: driver, threads: [])
        let recovered = ReviewLoopCoordinator(store: store)
        driver.stopChatMissing = true
        await recovered.advance(using: driver, threads: [])
        XCTAssertEqual(recovered.loops.last?.phase, .stopped)
        XCTAssertTrue(recovered.loops.last?.message.contains("deleted") == true)
        XCTAssertEqual(ReviewLoopCoordinator(store: store).loops.last?.phase, .stopped)
        XCTAssertTrue(driver.interruptedTurns.isEmpty)
        try recovered.apply(startAction(id: "replacement", kind: .start, projectID: project.id,
                                       promptContext: .general, maxRounds: 2, loopID: nil), projects: [project])
    }

    func testFailedStopReservesCheckoutAcrossRestartAndRetriesAutomatically() async throws {
        let (coordinator, store, driver) = try make()
        await coordinator.advance(using: driver, threads: [])
        driver.failStopThread = true
        stop(coordinator)
        await coordinator.advance(using: driver, threads: [])
        XCTAssertEqual(coordinator.loops.last?.phase, .stopping)
        let recovered = ReviewLoopCoordinator(store: store)
        let replacement = startAction(id: "replacement", kind: .start, projectID: project.id,
                                      promptContext: .general, maxRounds: 2, loopID: nil)
        XCTAssertThrowsError(try recovered.apply(replacement, projects: [project]))
        XCTAssertThrowsError(try recovered.apply(action(.delete, for: recovered), projects: [project]))
        try recovered.apply(action(.resume, for: recovered), projects: [project])
        try recovered.apply(action(.pause, for: recovered), projects: [project])
        XCTAssertEqual(recovered.loops.last?.phase, .stopping)

        let nested = ReviewProject(id: "nested", name: "Nested", path: project.path + "/nested")
        try recovered.apply(startAction(id: "nested", kind: .start, projectID: nested.id,
                                        promptContext: .general, maxRounds: 2, loopID: nil), projects: [nested])
        driver.workspaceRoot = project.path
        await recovered.advance(using: driver, threads: [])
        XCTAssertEqual(driver.prompts.count, 1)
        XCTAssertEqual(recovered.loops.map(\.phase), [.stopping, .blocked])
        driver.failStopThread = false
        await recovered.advance(using: driver, threads: [])
        XCTAssertEqual(recovered.loops.first?.phase, .stopped)
        XCTAssertEqual(driver.interruptedTurns, ["turn-1"])
        try recovered.apply(replacement, projects: [project])
    }

    func testStopWaitsForPendingSubmissionBeforeReleasingCheckout() async throws {
        let (coordinator, _, driver) = try make()
        let gate = SubmissionGate()
        driver.onStartTurnAsync = { await gate.suspend() }
        let advance = Task { await coordinator.advance(using: driver, threads: []) }
        await gate.waitUntilStarted()
        stop(coordinator)
        try await coordinator.stopRunningTask(for: coordinator.loops[0].id, using: driver)
        XCTAssertEqual(coordinator.loops[0].phase, .stopping)
        XCTAssertTrue(driver.interruptedTurns.isEmpty)
        XCTAssertThrowsError(try coordinator.apply(startAction(id: "replacement", kind: .start,
            projectID: project.id, promptContext: .general, maxRounds: 2, loopID: nil), projects: [project]))
        gate.release()
        await advance.value
        XCTAssertEqual(coordinator.loops[0].phase, .stopped)
        XCTAssertEqual(coordinator.loops[0].rounds.last?.reviewTurnID, "turn-1")
        XCTAssertEqual(driver.interruptedTurns, ["turn-1"])
    }
}

@MainActor
private final class SubmissionGate {
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var startContinuation: CheckedContinuation<Void, Never>?
    func suspend() async {
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
            startContinuation?.resume()
            startContinuation = nil
        }
    }
    func waitUntilStarted() async {
        if releaseContinuation != nil { return }
        await withCheckedContinuation { startContinuation = $0 }
    }
    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}
