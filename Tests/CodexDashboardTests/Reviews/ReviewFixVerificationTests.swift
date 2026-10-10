import XCTest
@testable import CodexDashboard

@MainActor
final class ReviewFixVerificationTests: ReviewLoopTestCase {
    private func verifying() async throws -> (ReviewLoopCoordinator, ReviewTestStore, ReviewTestDriver) {
        let (coordinator, store, driver) = try make(limit: 1)
        await coordinator.advance(using: driver, threads: [])
        driver.review(priorities: [.p1])
        await coordinator.advance(using: driver, threads: [])
        await coordinator.advance(using: driver, threads: [])
        driver.finish(findings: 1, commit: "fixed")
        store.loops[0].pushToRemote = true
        let recovered = ReviewLoopCoordinator(store: store)
        driver.commit = "later"
        try recovered.apply(action(.resume, for: recovered), projects: [project])
        await recovered.advance(using: driver, threads: [])
        XCTAssertEqual(driver.prompts.count, 3)
        return (recovered, store, driver)
    }

    func testRealDriverRetainsSourceFixReportWhileVerifyingAdvancedHEAD() async throws {
        for completed in [false, true] {
            let (coordinator, _, driver) = try await verifying()
            if completed { driver.review(priorities: []) }
            let connection = VerificationReportDevTools(thread: driver.thread)
            let reader = ReviewLoopDriver(devTools: connection,
                target: DevToolsTarget(id: "test", type: "page", url: nil, webSocketURL: nil))
            let sourceFixTurnID = try XCTUnwrap(coordinator.loops[0].rounds[0].fixVerification?.sourceFixTurnID)
            driver.thread = try await reader.readThread("thread-1", reportTurnIDs: [sourceFixTurnID])
            XCTAssertNotNil(driver.thread.turns[1].finalMessage)
            await coordinator.advance(using: driver, threads: [])
            XCTAssertEqual(coordinator.loops[0].phase, completed ? .limitReached : .running)
            XCTAssertEqual(driver.pushedCommits, completed ? ["fixed"] : [])
        }
    }

    func testRegressionBlockedAndCorrectedVerificationNeedsExplicitResume() async throws {
        let (coordinator, _, driver) = try await verifying()
        driver.review(priorities: [.p1])
        await coordinator.advance(using: driver, threads: [])
        XCTAssertEqual(coordinator.loops[0].phase, .blocked)
        XCTAssertTrue(coordinator.loops[0].message.contains("Example issue"))
        XCTAssertEqual(coordinator.loops[0].completedRoundCount, 0)
        XCTAssertTrue(driver.pushedCommits.isEmpty)
        driver.userFollowup()
        driver.review(priorities: [])
        await coordinator.advance(using: driver, threads: [])
        XCTAssertEqual(coordinator.loops[0].phase, .blocked)
        try coordinator.apply(action(.resume, for: coordinator), projects: [project])
        await coordinator.advance(using: driver, threads: [])
        XCTAssertEqual(coordinator.loops[0].phase, .limitReached)
        XCTAssertEqual(driver.pushedCommits, ["fixed"])
    }

    func testNewHEADNeedsNewVerificationBeforePush() async throws {
        let (coordinator, _, driver) = try await verifying()
        driver.commit = "newer"
        await coordinator.advance(using: driver, threads: [])
        XCTAssertEqual(driver.prompts.count, 3, "Do not submit while verification is running")
        driver.review(priorities: [])
        await coordinator.advance(using: driver, threads: [])
        XCTAssertEqual(driver.prompts.count, 4)
        XCTAssertEqual(coordinator.loops[0].rounds[0].fixVerification?.commit, "newer")
        XCTAssertTrue(driver.pushedCommits.isEmpty)
        driver.review(priorities: [])
        await coordinator.advance(using: driver, threads: [])
        XCTAssertEqual(coordinator.loops[0].rounds[0].result?.verifiedCommit, "newer")
        XCTAssertEqual(coordinator.loops[0].rounds[0].result?.commit, "fixed")
        XCTAssertEqual(driver.pushedCommits, ["fixed"])
    }

    func testFailedVerificationResumesReadOnlyAndKeepsOriginalFix() async throws {
        let (coordinator, _, driver) = try await verifying()
        let latest = driver.thread.turns.last!
        driver.thread = ReviewThreadState(cwd: driver.thread.cwd, turns: driver.thread.turns.dropLast() + [
            ReviewTurnState(id: latest.id, status: "failed", finalMessage: nil)
        ])
        await coordinator.advance(using: driver, threads: [])
        XCTAssertEqual(coordinator.loops[0].phase, .blocked)
        try coordinator.apply(action(.resume, for: coordinator), projects: [project])
        await coordinator.advance(using: driver, threads: [])
        XCTAssertEqual(driver.prompts.count, 4)
        XCTAssertTrue(driver.prompts.last!.contains("read-only verification"))
        driver.review(priorities: [])
        await coordinator.advance(using: driver, threads: [])
        XCTAssertEqual(coordinator.loops[0].rounds[0].result?.commit, "fixed")
    }

    func testVerificationCannotAcceptDirtyCheckoutOrInvalidReport() async throws {
        for failure in ["dirty", "branch", "root", "report", "blocked"] {
            let (coordinator, _, driver) = try await verifying()
            driver.review(priorities: [])
            if failure == "dirty" { driver.clean = false }
            if failure == "branch" { driver.branch = "other" }
            if failure == "root" { driver.repositoryRoot = "/tmp/other" }
            if failure == "report" { driver.finishTurn("Looks fine") }
            if failure == "blocked" { driver.finishTurn("# Review blocked\n\n## Summary\nCould not run checks") }
            await coordinator.advance(using: driver, threads: [])
            XCTAssertEqual(coordinator.loops[0].phase, .blocked, failure)
            XCTAssertNil(coordinator.loops[0].rounds[0].result, failure)
            XCTAssertTrue(driver.pushedCommits.isEmpty, failure)
        }
    }

    func testUnknownVerificationSubmissionIsNeverRepeated() async throws {
        let (_, store, driver) = try await verifying()
        store.loops[0].rounds[0].fixVerification?.turnID = nil
        let recovered = ReviewLoopCoordinator(store: store)
        try recovered.apply(action(.resume, for: recovered), projects: [project])
        await recovered.advance(using: driver, threads: [])
        XCTAssertEqual(recovered.loops[0].phase, .blocked)
        XCTAssertEqual(driver.prompts.count, 3)
    }

    func testManualReloadContinuesVerificationWithReadOnlyPrompt() async throws {
        let (coordinator, _, driver) = try await verifying()
        driver.requestExtensionReload()
        await coordinator.advance(using: driver, threads: [])
        XCTAssertEqual(coordinator.loops[0].phase, .awaitingExtensionReload)
        try coordinator.apply(action(.resume, for: coordinator), projects: [project])
        await coordinator.advance(using: driver, threads: [])
        XCTAssertEqual(driver.prompts.count, 4)
        XCTAssertTrue(driver.prompts.last!.contains("read-only verification"))
        driver.review(priorities: [])
        await coordinator.advance(using: driver, threads: [])
        XCTAssertEqual(coordinator.loops[0].phase, .limitReached)
    }
}

private actor VerificationReportDevTools: DevToolsServing {
    let thread: ReviewThreadState
    init(thread: ReviewThreadState) { self.thread = thread }
    func mainRendererTargets() async -> [DevToolsTarget] { [] }
    func evaluateBoolean(_ expression: String, in target: DevToolsTarget) async throws -> Bool { false }
    func evaluateString(_ expression: String, in target: DevToolsTarget, timeout: Duration) async throws -> String? {
        let prefix = "window.__codexDashboard.reviewRequest("
        let request = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(expression.dropFirst(prefix.count).dropLast().utf8)) as? [String: Any])
        let params = try XCTUnwrap(request["params"] as? [String: Any])
        let result: [String: Any]
        switch request["method"] as? String {
        case "thread/read":
            result = ["thread": ["cwd": thread.cwd,
                "status": ["type": thread.turns.last?.status == "inProgress" ? "active" : "idle"]]]
        case "thread/turns/list":
            result = ["data": thread.turns.map { ["id": $0.id, "status": $0.status] }, "nextCursor": NSNull()]
        case "thread/items/list":
            let turn = try XCTUnwrap(thread.turns.first { $0.id == params["turnId"] as? String })
            let text = try XCTUnwrap(turn.finalMessage)
            result = ["data": [["item": ["type": "agentMessage", "phase": "final", "text": text]]],
                "nextCursor": NSNull()]
        default: throw ReviewLoopError("Unexpected verification request")
        }
        return String(data: try JSONSerialization.data(withJSONObject: ["result": result]), encoding: .utf8)
    }
}
