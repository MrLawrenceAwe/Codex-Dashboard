import XCTest
@testable import CodexDashboard

@MainActor
final class ReviewLoopResumeTests: ReviewLoopTestCase {
    private func failLatest(_ driver: ReviewTestDriver, status: String) {
        let latest = driver.thread.turns.last!
        driver.thread = ReviewThreadState(cwd: driver.thread.cwd, turns: driver.thread.turns.dropLast() + [
            ReviewTurnState(id: latest.id, status: status, finalMessage: nil)
        ])
    }

    func testResumeContinuesFailedReviewAndFixInSameChatOnce() async throws {
        for fixing in [false, true] {
            for status in ["failed", "interrupted"] {
                let (coordinator, store, driver) = try make(limit: 1)
                await coordinator.advance(using: driver, threads: [])
                if fixing {
                    driver.review(priorities: [.p1])
                    await coordinator.advance(using: driver, threads: [])
                    await coordinator.advance(using: driver, threads: [])
                    driver.clean = false // Preserve edits made before usage ran out.
                    driver.commit = "partial-fix"
                }
                failLatest(driver, status: status)
                await coordinator.advance(using: driver, threads: [])
                XCTAssertEqual(coordinator.loops.last?.phase, .blocked)
                let count = driver.prompts.count
                try coordinator.apply(action(.resume, for: coordinator), projects: [project])
                await coordinator.advance(using: driver, threads: [])
                XCTAssertEqual(driver.prompts.count, count + 1)
                XCTAssertEqual(driver.createdThreads, ["thread-1"])
                XCTAssertEqual(coordinator.loops.last?.rounds.count, 1)
                XCTAssertEqual(driver.selections.last!, fixing ? coordinator.loops.last?.fixSelection : coordinator.loops.last?.reviewSelection)
                XCTAssertTrue(driver.prompts.last!.contains(fixing ? "preserve existing changes" : "read-only review"))
                XCTAssertEqual(coordinator.loops.last?.phase, .running)
                await coordinator.advance(using: driver, threads: [])
                XCTAssertEqual(driver.prompts.count, count + 1, "Polling must not submit another continuation")

                // Recover a submitted continuation after restarting the Dashboard.
                let recovered = ReviewLoopCoordinator(store: store)
                try recovered.apply(action(.resume, for: recovered), projects: [project])
                await recovered.advance(using: driver, threads: [])
                XCTAssertEqual(driver.prompts.count, count + 1, "Resume must leave a running continuation alone")
                driver.clean = true
                if fixing { driver.finish(findings: 1, commit: "fixed") }
                else { driver.review(priorities: []) }
                await recovered.advance(using: driver, threads: [])
                XCTAssertEqual(recovered.loops.last?.phase, fixing ? .limitReached : .completed)
                XCTAssertEqual(recovered.loops.last?.completedRoundCount, 1)
            }
        }
    }

    func testResumeReconcilesFixBehindHEADWithoutRepeatingWork() async throws {
        let (coordinator, store, driver) = try make(limit: 2)
        await coordinator.advance(using: driver, threads: [])
        driver.review(priorities: [.p1])
        await coordinator.advance(using: driver, threads: [])
        await coordinator.advance(using: driver, threads: [])
        driver.finish(findings: 1, commit: "fixed")
        driver.commit = "later"
        // Reproduce a previously blocked checkpoint, including persisted recovery.
        var blocked = store.loops[0]
        blocked.phase = .blocked
        blocked.message = "Commit checkpoint failed: HEAD differs from the reported fix commit."
        blocked.pushToRemote = true
        store.loops = [blocked]
        let recovered = ReviewLoopCoordinator(store: store)
        try recovered.apply(action(.resume, for: recovered), projects: [project])
        await recovered.advance(using: driver, threads: [])
        XCTAssertEqual(recovered.loops[0].phase, .waiting)
        XCTAssertEqual(recovered.loops[0].expectedCommit, "later")
        XCTAssertEqual(recovered.loops[0].rounds[0].result?.commit, "fixed")
        XCTAssertEqual(driver.pushedCommits, ["fixed"])
        XCTAssertEqual(driver.prompts.count, 2)
        await recovered.advance(using: driver, threads: [])
        XCTAssertEqual(recovered.loops[0].rounds.last?.baseCommit, "later")
        XCTAssertEqual(driver.createdThreads.count, 2)
    }

    func testAdvancedHEADIsAcceptedAutomaticallyButWithdrawnFindingsRemainStrict() async throws {
        for withdrawn in [false, true] {
            let (coordinator, _, driver) = try make(limit: 1)
            await coordinator.advance(using: driver, threads: [])
            driver.review(priorities: [.p1])
            await coordinator.advance(using: driver, threads: [])
            await coordinator.advance(using: driver, threads: [])
            driver.finish(findings: withdrawn ? 0 : 1, commit: withdrawn ? "none" : "fixed", withdrawn: withdrawn ? [1] : [])
            driver.commit = "later"
            await coordinator.advance(using: driver, threads: [])
            XCTAssertEqual(coordinator.loops[0].phase, withdrawn ? .blocked : .limitReached)
            XCTAssertEqual(driver.prompts.count, 2)
        }
    }

    func testResumeAfterRestartContinuesInterruptedTurn() async throws {
        let (coordinator, store, driver) = try make()
        await coordinator.advance(using: driver, threads: [])
        failLatest(driver, status: "interrupted")
        let recovered = ReviewLoopCoordinator(store: store)
        try recovered.apply(action(.resume, for: recovered), projects: [project])
        await recovered.advance(using: driver, threads: [])
        XCTAssertEqual(driver.prompts.count, 2)
        XCTAssertEqual(driver.createdThreads.count, 1)
    }

    func testResumeDoesNotRetryFailedContinuationWithoutAnotherClick() async throws {
        let (coordinator, _, driver) = try make()
        await coordinator.advance(using: driver, threads: [])
        failLatest(driver, status: "failed")
        await coordinator.advance(using: driver, threads: [])
        try coordinator.apply(action(.resume, for: coordinator), projects: [project])
        await coordinator.advance(using: driver, threads: [])
        failLatest(driver, status: "failed")
        await coordinator.advance(using: driver, threads: [])
        await coordinator.advance(using: driver, threads: [])
        XCTAssertEqual(coordinator.loops.last?.phase, .blocked)
        XCTAssertEqual(driver.prompts.count, 2)
        try coordinator.apply(action(.resume, for: coordinator), projects: [project])
        await coordinator.advance(using: driver, threads: [])
        XCTAssertEqual(driver.prompts.count, 3)
    }

    func testResumeRejectsChangedReviewCheckoutAndFixBranch() async throws {
        for change in ["dirty-review", "review-commit", "fix-branch", "root"] {
            let (coordinator, _, driver) = try make()
            await coordinator.advance(using: driver, threads: [])
            if change == "fix-branch" {
                driver.review(priorities: [.p1])
                await coordinator.advance(using: driver, threads: [])
                await coordinator.advance(using: driver, threads: [])
                driver.branch = "other"
            }
            failLatest(driver, status: "interrupted")
            await coordinator.advance(using: driver, threads: [])
            let count = driver.prompts.count
            if change == "dirty-review" { driver.clean = false }
            if change == "review-commit" { driver.commit = "other" }
            if change == "root" { driver.repositoryRoot = "/tmp/other" }
            try coordinator.apply(action(.resume, for: coordinator), projects: [project])
            await coordinator.advance(using: driver, threads: [])
            XCTAssertEqual(coordinator.loops.last?.phase, .blocked, change)
            XCTAssertEqual(driver.prompts.count, count, change)
        }
    }

    func testResumingWaitingLoopDoesNotAuthorizeRetryOfLaterFailure() async throws {
        let (coordinator, _, driver) = try make()
        try coordinator.apply(action(.pause, for: coordinator), projects: [project])
        try coordinator.apply(action(.resume, for: coordinator), projects: [project])
        await coordinator.advance(using: driver, threads: [])
        failLatest(driver, status: "failed")
        await coordinator.advance(using: driver, threads: [])
        XCTAssertEqual(coordinator.loops.last?.phase, .blocked)
        XCTAssertEqual(driver.prompts.count, 1)
    }

    func testResumeDoesNotStartAlongsideAnotherRunningChat() async throws {
        let (coordinator, _, driver) = try make()
        await coordinator.advance(using: driver, threads: [])
        failLatest(driver, status: "failed")
        await coordinator.advance(using: driver, threads: [])
        try coordinator.apply(action(.resume, for: coordinator), projects: [project])
        let other = ThreadSummary(id: "other", title: "Other", preview: "Other", projectName: "Example",
                                  checkoutPath: "/tmp/example/Sources", recencyEpochMillis: 1, isPinned: false,
                                  model: nil, runState: .running, latestLifecycleEvent: nil, projectGitStatus: .clean)
        await coordinator.advance(using: driver, threads: [RendererThread(other)])
        XCTAssertEqual(coordinator.loops.last?.phase, .blocked)
        XCTAssertEqual(driver.prompts.count, 1)
    }

    func testStopDuringResumePreflightPreventsContinuation() async throws {
        let (coordinator, _, driver) = try make()
        await coordinator.advance(using: driver, threads: [])
        failLatest(driver, status: "failed")
        await coordinator.advance(using: driver, threads: [])
        try coordinator.apply(action(.resume, for: coordinator), projects: [project])
        driver.onRepository = { self.stop(coordinator) }
        await coordinator.advance(using: driver, threads: [])
        XCTAssertEqual(driver.prompts.count, 1)
        XCTAssertEqual(coordinator.loops.last?.phase, .stopped)
    }
}
