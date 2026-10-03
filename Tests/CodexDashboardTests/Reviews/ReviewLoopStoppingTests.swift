import XCTest
@testable import CodexDashboard

@MainActor
final class ReviewLoopStoppingTests: ReviewLoopTestCase {
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
        driver.repositoryRoot = project.path
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
