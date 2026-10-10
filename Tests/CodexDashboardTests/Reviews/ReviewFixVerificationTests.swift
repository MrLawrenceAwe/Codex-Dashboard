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
