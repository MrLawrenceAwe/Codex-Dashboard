import XCTest
@testable import CodexDashboard

@MainActor
final class ReviewLoopCoordinatorTests: ReviewLoopTestCase {
    func testPreserveUICopyIsSavedOnlyForStructureReviews() throws {
        for reviewType in ReviewType.allCases {
            let store = ReviewTestStore()
            let coordinator = ReviewLoopCoordinator(store: store)
            var start = startAction(id: reviewType.rawValue, kind: .start, projectID: project.id,
                                    promptContext: .general, maxRounds: 3, loopID: nil)
            start.reviewType = reviewType
            start.preserveUICopy = true
            try coordinator.apply(start, projects: [project])
            let saved = try JSONDecoder().decode(ReviewLoop.self, from: JSONEncoder().encode(store.loops[0]))
            XCTAssertEqual(saved.preserveUICopy, reviewType.supportsPreservingUICopy)
        }
    }

    func testStartRequiresBothModels() throws {
        let coordinator = ReviewLoopCoordinator(store: ReviewTestStore())
        var action = startAction(id: "start", kind: .start, projectID: project.id,
                                 promptContext: nil, maxRounds: 3, loopID: nil)
        action.reviewSelection = nil
        XCTAssertThrowsError(try coordinator.apply(action, projects: [project]))
        action.reviewSelection = ReviewModelSelection(modelID: "review-model", reasoningEffort: nil)
        action.fixSelection = nil
        XCTAssertThrowsError(try coordinator.apply(action, projects: [project]))
        action.fixSelection = ReviewModelSelection(modelID: "", reasoningEffort: nil)
        XCTAssertThrowsError(try coordinator.apply(action, projects: [project]))
        XCTAssertTrue(coordinator.loops.isEmpty)
    }

    func testConcurrentProjectsKeepIndependentControlsAndRecovery() async throws {
        let (coordinator, store, driver) = try make()
        let second = ReviewProject(id: "second", name: "Second", path: "/tmp/second")
        let start = startAction(id: "second-start", kind: .start, projectID: second.id,
                                     promptContext: .general, maxRounds: 3, loopID: nil)
        try coordinator.apply(start, projects: [project, second])
        try coordinator.apply(start, projects: [project, second])
        XCTAssertEqual(coordinator.loops.count, 2)
        await coordinator.advance(using: driver, threads: [])
        XCTAssertEqual(driver.createCalls, 2)
        XCTAssertEqual(coordinator.loops.map(\.phase), [.running, .running])
        XCTAssertEqual(Set(coordinator.loops.compactMap { $0.rounds.last?.threadID }).count, 2)
        try coordinator.apply(action(.stop, for: coordinator), projects: [project, second])
        XCTAssertEqual(coordinator.loops.map(\.phase), [.running, .stopping])
        let recovered = ReviewLoopCoordinator(store: store)
        XCTAssertEqual(recovered.loops.map(\.phase), [.paused, .stopping])
        XCTAssertEqual(recovered.loops.map(\.id), coordinator.loops.map(\.id))
    }

    func testOneProjectInspectionFailureDoesNotPreventOtherLaunches() async throws {
        let (coordinator, _, driver) = try make()
        let second = ReviewProject(id: "second", name: "Second", path: "/tmp/second")
        try coordinator.apply(startAction(id: "second-start", kind: .start, projectID: second.id,
                                              promptContext: .general, maxRounds: 3, loopID: nil), projects: [second])
        driver.failingPath = project.path
        await coordinator.advance(using: driver, threads: [])
        XCTAssertEqual(coordinator.loops.map(\.phase), [.paused, .running])
        XCTAssertEqual(driver.createCalls, 1)
    }

    func testProjectsSharingCheckoutShowConflictAfterRestart() async throws {
        let (coordinator, store, driver) = try make()
        await coordinator.advance(using: driver, threads: [])
        let recovered = ReviewLoopCoordinator(store: store)
        let second = ReviewProject(id: "nested", name: "Nested", path: "/tmp/example/subdir")
        try recovered.apply(startAction(id: "nested-start", kind: .start, projectID: second.id,
                                            promptContext: .general, maxRounds: 3, loopID: nil), projects: [second])
        driver.workspaceRoot = project.path
        await recovered.advance(using: driver, threads: [])
        XCTAssertEqual(driver.createCalls, 1)
        XCTAssertEqual(recovered.loops.map(\.phase), [.paused, .blocked])
        XCTAssertEqual(recovered.loops.last?.message,
                       "This project folder already has an active review loop for Example. Stop that loop before starting another.")
    }

    func testOneActiveLoopPerProjectIncludingPausedAndChangedPath() throws {
        let (coordinator, _, _) = try make()
        let start = startAction(id: "duplicate", kind: .start, projectID: project.id,
                                     promptContext: .general, maxRounds: 3, loopID: nil)
        XCTAssertThrowsError(try coordinator.apply(start, projects: [project]))
        try coordinator.apply(action(.pause, for: coordinator), projects: [project])
        let moved = ReviewProject(id: project.id, name: project.name, path: "/tmp/moved")
        XCTAssertThrowsError(try coordinator.apply(start, projects: [moved]))
        stop(coordinator)
        try coordinator.apply(start, projects: [project])
        XCTAssertEqual(coordinator.loops.count, 2)
        XCTAssertEqual(coordinator.loops.map(\.phase), [.stopped, .waiting])
    }

    func testPushPreferenceAndFailureRetryPreserveVerifiedFix() async throws {
        let store = ReviewTestStore()
        let coordinator = ReviewLoopCoordinator(store: store)
        var start = startAction(id: "push", kind: .start, projectID: project.id,
                                promptContext: .general, maxRounds: 1, loopID: nil)
        start.pushToRemote = true
        try coordinator.apply(start, projects: [project])
        let driver = ReviewTestDriver()
        await coordinator.advance(using: driver, threads: [])
        driver.review(priorities: [.p1])
        await coordinator.advance(using: driver, threads: [])
        await coordinator.advance(using: driver, threads: [])
        driver.finish(findings: 1, commit: "fixed")
        driver.failPush = true
        await coordinator.advance(using: driver, threads: [])
        XCTAssertEqual(coordinator.loops.last?.phase, .blocked)
        XCTAssertEqual(coordinator.loops.last?.message, "Remote push failed")
        XCTAssertNil(coordinator.loops.last?.rounds.last?.result)
        XCTAssertEqual(coordinator.loops.last?.completedRoundCount, 0)
        XCTAssertEqual(store.loops.last?.pushToRemote, true)
        driver.failPush = false
        try coordinator.apply(action(.resume, for: coordinator), projects: [project])
        await coordinator.advance(using: driver, threads: [])
        XCTAssertEqual(driver.pushedCommits, ["fixed"])
        XCTAssertEqual(driver.prompts.count, 2, "Retry the push without creating another fix turn")
        XCTAssertEqual(coordinator.loops.last?.phase, .limitReached)
        XCTAssertEqual(coordinator.loops.last?.completedRoundCount, 1)
        XCTAssertTrue(coordinator.loops.last?.message.contains("pushed to remote") == true)
    }

    func testFixCommitThenFreshReviewThenCleanStops() async throws {
        let (coordinator, store, driver) = try make()
        await coordinator.advance(using: driver, threads: [])
        XCTAssertEqual(driver.createdThreads, ["thread-1"])
        XCTAssertEqual(driver.speeds, [.standard, .standard])
        XCTAssertEqual(store.loops[store.loops.count - 1].rounds.first?.reviewTurnID, "turn-1")
        driver.review(priorities: [.p1, .p2])
        await coordinator.advance(using: driver, threads: []) // read review
        XCTAssertEqual(driver.prompts.count, 1)
        await coordinator.advance(using: driver, threads: []) // send fix
        XCTAssertEqual(driver.createdThreads.count, 1)
        XCTAssertEqual(driver.prompts.count, 2)
        driver.finish(findings: 2, commit: "fixed")
        await coordinator.advance(using: driver, threads: [])
        XCTAssertEqual(coordinator.loops.last?.phase, .waiting)
        XCTAssertTrue(driver.pushedCommits.isEmpty)
        XCTAssertEqual(driver.createdThreads.count, 1, "Do not launch in the same checkpoint observation")
        await coordinator.advance(using: driver, threads: [])
        XCTAssertEqual(driver.createdThreads, ["thread-1", "thread-2"])
        XCTAssertEqual(driver.prompts[2], ReviewPrompts.reviewPrompt(for: try XCTUnwrap(store.loops.last)))
        driver.review(priorities: [])
        await coordinator.advance(using: driver, threads: [])
        XCTAssertEqual(coordinator.loops.last?.phase, .completed)
        XCTAssertNil(coordinator.loops.last?.rounds.last?.result?.fixCommit)
        XCTAssertEqual(coordinator.loops.last?.rounds.last?.result?.verifiedRevision, "fixed")
        await coordinator.advance(using: driver, threads: [])
        XCTAssertEqual(driver.createdThreads.count, 2)
    }

    func testReviewCountsAllSectionsAndFixesThemDespiteIncorrectSummaryTotal() async throws {
        let store = ReviewTestStore()
        let coordinator = ReviewLoopCoordinator(store: store)
        var start = startAction(id: "count-sections", kind: .start, projectID: project.id,
                                promptContext: .general, maxRounds: 1, loopID: nil)
        start.reviewType = .organisationAndNaming
        try coordinator.apply(start, projects: [project])
        let driver = ReviewTestDriver()
        await coordinator.advance(using: driver, threads: [])
        let findings = (1...22).map { "## Improvement \($0)\nDescription and location." }.joined(separator: "\n\n")
        driver.finishTurn("# Review complete\n\n## Summary\nFound 21 improvements.\n\n" + findings)
        await coordinator.advance(using: driver, threads: [])
        XCTAssertEqual(coordinator.loops.last?.phase, .running)
        XCTAssertEqual(store.loops.last?.rounds.last?.review?.findings.count, 22)
        XCTAssertEqual(store.loops.last?.rounds.last?.review?.findings.last?.title, "Improvement 22")
        await coordinator.advance(using: driver, threads: [])
        XCTAssertEqual(driver.prompts.count, 2)
        XCTAssertTrue(driver.prompts[1].hasPrefix("Address all findings and commit"))
        driver.finish(findings: 22, commit: "fixed")
        await coordinator.advance(using: driver, threads: [])
        XCTAssertEqual(coordinator.loops.last?.phase, .limitReached)
        XCTAssertEqual(coordinator.loops.last?.completedRoundCount, 1)
        XCTAssertEqual(coordinator.loops.last?.rounds.last?.result?.addressedFindingCount, 22)
    }

    func testOneFalsePositiveAndOneFixContinueToNextReview() async throws {
        let (coordinator, _, driver) = try make()
        await coordinator.advance(using: driver, threads: [])
        driver.review(priorities: [.p2, .p2])
        await coordinator.advance(using: driver, threads: [])
        await coordinator.advance(using: driver, threads: [])
        driver.finish(findings: 1, commit: "fixed", withdrawn: [2])
        await coordinator.advance(using: driver, threads: [])
        XCTAssertEqual(coordinator.loops.last?.phase, .waiting)
        XCTAssertEqual(coordinator.loops.last?.rounds.last?.result?.addressedFindingCount, 1)
        await coordinator.advance(using: driver, threads: [])
        XCTAssertEqual(driver.createdThreads.count, 2)
    }

    func testAllFindingsWithdrawnStopsWithoutCommit() async throws {
        let (coordinator, _, driver) = try make()
        await coordinator.advance(using: driver, threads: [])
        driver.review(priorities: [.p2])
        await coordinator.advance(using: driver, threads: [])
        await coordinator.advance(using: driver, threads: [])
        driver.finish(findings: 0, commit: "none", withdrawn: [1])
        await coordinator.advance(using: driver, threads: [])
        XCTAssertEqual(coordinator.loops.last?.phase, .completed)
        XCTAssertEqual(coordinator.loops.last?.rounds.last?.result?.outcome, .withdrawn)
        XCTAssertNil(coordinator.loops.last?.rounds.last?.result?.fixCommit)
        XCTAssertEqual(coordinator.loops.last?.rounds.last?.result?.verifiedRevision, "base")
        XCTAssertEqual(driver.createdThreads.count, 1)
    }

    func testShortReportedCommitIsResolvedAndStoredInFull() async throws {
        let (coordinator, _, driver) = try make()
        await coordinator.advance(using: driver, threads: [])
        driver.review(priorities: [.p1, .p2])
        await coordinator.advance(using: driver, threads: [])
        await coordinator.advance(using: driver, threads: [])
        driver.finish(findings: 2, commit: "35bdc02")
        let fullCommit = "35bdc02" + String(repeating: "a", count: 33)
        driver.resolvedCommit = fullCommit
        driver.commit = fullCommit
        await coordinator.advance(using: driver, threads: [])
        XCTAssertEqual(coordinator.loops.last?.phase, .waiting)
        XCTAssertEqual(coordinator.loops.last?.expectedRevision, fullCommit)
        XCTAssertEqual(coordinator.loops.last?.rounds.last?.result?.fixCommit, fullCommit)
        XCTAssertEqual(driver.prompts.count, 2)
    }

    func testBlockedFixResumesAfterChatAnswerWithoutNewChatOrRound() async throws {
        let (coordinator, store, driver) = try make(limit: 1)
        await coordinator.advance(using: driver, threads: [])
        driver.review(priorities: [.p1])
        await coordinator.advance(using: driver, threads: [])
        await coordinator.advance(using: driver, threads: [])
        driver.blockFix()
        await coordinator.advance(using: driver, threads: [])
        XCTAssertEqual(coordinator.loops.last?.phase, .blocked)
        XCTAssertFalse(try XCTUnwrap(coordinator.loops.last).phase.isFinished)
        await coordinator.advance(using: driver, threads: [])
        XCTAssertEqual(driver.prompts.count, 2)
        XCTAssertThrowsError(try coordinator.apply(startAction(id: "other", kind: .start,
            projectID: project.id, promptContext: .general, maxRounds: 1, loopID: nil), projects: [project]))

        driver.userFollowup()
        try coordinator.apply(action(.resume, for: coordinator), projects: [project])
        await coordinator.advance(using: driver, threads: [])
        XCTAssertEqual(coordinator.loops.last?.phase, .running)
        // Follow-up authorization survives a Dashboard restart.
        let recovered = ReviewLoopCoordinator(store: store)
        driver.finish(findings: 1, commit: "fixed-by-codex")
        try recovered.apply(action(.resume, for: recovered), projects: [project])
        await recovered.advance(using: driver, threads: [])
        XCTAssertEqual(driver.createdThreads, ["thread-1"])
        XCTAssertEqual(driver.prompts.count, 2, "Resume never repeats a fix prompt")
        XCTAssertEqual(recovered.loops.last?.phase, .limitReached)
        XCTAssertEqual(recovered.loops.last?.completedRoundCount, 1)
        XCTAssertEqual(recovered.loops.last?.rounds.count, 1)
        XCTAssertEqual(recovered.loops.last?.rounds.last?.fixTurnID, "followup-3")
    }

    func testBlockedResumeStillRequiresCleanOriginalBranchAndValidCommit() async throws {
        let (coordinator, _, driver) = try make()
        await coordinator.advance(using: driver, threads: [])
        driver.review(priorities: [.p1])
        await coordinator.advance(using: driver, threads: [])
        await coordinator.advance(using: driver, threads: [])
        driver.blockFix()
        await coordinator.advance(using: driver, threads: [])
        driver.userFollowup()
        driver.finish(findings: 1, commit: "fixed")
        driver.clean = false
        try coordinator.apply(action(.resume, for: coordinator), projects: [project])
        await coordinator.advance(using: driver, threads: [])
        XCTAssertEqual(coordinator.loops.last?.phase, .blocked)
        driver.clean = true
        driver.branch = "other"
        try coordinator.apply(action(.resume, for: coordinator), projects: [project])
        await coordinator.advance(using: driver, threads: [])
        XCTAssertEqual(coordinator.loops.last?.phase, .blocked)
        driver.branch = "main"
        driver.ancestor = false
        try coordinator.apply(action(.resume, for: coordinator), projects: [project])
        await coordinator.advance(using: driver, threads: [])
        XCTAssertEqual(coordinator.loops.last?.phase, .blocked)
        driver.ancestor = true
        try coordinator.apply(action(.resume, for: coordinator), projects: [project])
        await coordinator.advance(using: driver, threads: [])
        XCTAssertEqual(coordinator.loops.last?.phase, .waiting)
        XCTAssertEqual(driver.createdThreads.count, 1)
        XCTAssertEqual(driver.prompts.count, 2)
    }

    func testResumeWithoutResolvingBlockedChatDoesNotRepeatWork() async throws {
        let (coordinator, _, driver) = try make()
        await coordinator.advance(using: driver, threads: [])
        driver.review(priorities: [.p1])
        await coordinator.advance(using: driver, threads: [])
        await coordinator.advance(using: driver, threads: [])
        driver.blockFix()
        await coordinator.advance(using: driver, threads: [])
        try coordinator.apply(action(.resume, for: coordinator), projects: [project])
        await coordinator.advance(using: driver, threads: [])
        XCTAssertEqual(coordinator.loops.last?.phase, .blocked)
        XCTAssertEqual(driver.createdThreads.count, 1)
        XCTAssertEqual(driver.prompts.count, 2)
        driver.userFollowup()
        driver.blockFix()
        try coordinator.apply(action(.resume, for: coordinator), projects: [project])
        await coordinator.advance(using: driver, threads: [])
        XCTAssertEqual(coordinator.loops.last?.phase, .blocked)
        driver.userFollowup()
        driver.finish(findings: 1, commit: "fixed")
        try coordinator.apply(action(.resume, for: coordinator), projects: [project])
        await coordinator.advance(using: driver, threads: [])
        XCTAssertEqual(coordinator.loops.last?.phase, .waiting)
        XCTAssertEqual(driver.createdThreads.count, 1)
    }

    func testDirtyCheckoutDoesNotLaunchOrCommit() async throws {
        let (coordinator, _, driver) = try make()
        driver.clean = false
        await coordinator.advance(using: driver, threads: [])
        XCTAssertEqual(coordinator.loops.last?.phase, .blocked)
        XCTAssertTrue(driver.createdThreads.isEmpty)
    }

    func testWorkspaceReadFailurePausesUntilResumeWithoutLaunching() async throws {
        let (coordinator, _, driver) = try make()
        driver.failWorkspace = true
        await coordinator.advance(using: driver, threads: [])
        XCTAssertEqual(coordinator.loops.last?.phase, .paused)
        XCTAssertTrue(driver.createdThreads.isEmpty)
        driver.failWorkspace = false
        await coordinator.advance(using: driver, threads: [])
        XCTAssertTrue(driver.createdThreads.isEmpty)
        try coordinator.apply(action(.resume, for: coordinator), projects: [project])
        await coordinator.advance(using: driver, threads: [])
        XCTAssertEqual(driver.createdThreads, ["thread-1"])
    }

    func testThreadReadFailurePausesAndReconcilesKnownTurnAfterResume() async throws {
        let (coordinator, _, driver) = try make()
        await coordinator.advance(using: driver, threads: [])
        driver.review(priorities: [])
        driver.failReadThread = true
        await coordinator.advance(using: driver, threads: [])
        XCTAssertEqual(coordinator.loops.last?.phase, .paused)
        XCTAssertEqual(coordinator.loops.last?.rounds.last?.threadID, "thread-1")
        driver.failReadThread = false
        try coordinator.apply(action(.resume, for: coordinator), projects: [project])
        await coordinator.advance(using: driver, threads: [])
        XCTAssertEqual(coordinator.loops.last?.phase, .completed)
        XCTAssertEqual(driver.prompts.count, 1)
    }

    func testCheckpointReadFailureDoesNotSubmitFixBeforeResume() async throws {
        let (coordinator, _, driver) = try make()
        await coordinator.advance(using: driver, threads: [])
        driver.review(priorities: [.p2])
        driver.failWorkspace = true
        await coordinator.advance(using: driver, threads: [])
        XCTAssertEqual(coordinator.loops.last?.phase, .paused)
        XCTAssertEqual(driver.prompts.count, 1)
        driver.failWorkspace = false
        try coordinator.apply(action(.resume, for: coordinator), projects: [project])
        await coordinator.advance(using: driver, threads: [])
        await coordinator.advance(using: driver, threads: [])
        XCTAssertEqual(driver.prompts.count, 2)
        XCTAssertEqual(driver.createdThreads.count, 1)
    }

    func testWaitsForOtherRunningTaskIncludingProjectSubdirectory() async throws {
        let (coordinator, _, driver) = try make()
        let thread = ThreadSummary(id: "other", title: "Other", preview: "Other", projectName: "Example", checkoutPath: "/tmp/example/Sources", recencyEpochMillis: 1, isPinned: false, model: nil, runState: .running, latestLifecycleEvent: nil, projectGitStatus: .clean)
        await coordinator.advance(using: driver, threads: [RendererThread(thread)])
        XCTAssertEqual(coordinator.loops.last?.phase, .waiting)
        XCTAssertTrue(driver.createdThreads.isEmpty)
        await coordinator.advance(using: driver, threads: [])
        XCTAssertEqual(driver.createdThreads.count, 1)
    }

    func testRejectsDirtyTreeWrongCommitAndRewrittenHistory() async throws {
        for failure in ["dirty", "commit", "ancestry", "branch", "root", "noCommit", "findings"] {
            let (coordinator, _, driver) = try make()
            await coordinator.advance(using: driver, threads: [])
            driver.review(priorities: [.p2])
            await coordinator.advance(using: driver, threads: [])
            await coordinator.advance(using: driver, threads: [])
            driver.finish(findings: failure == "findings" ? 0 : 1, commit: failure == "noCommit" ? "base" : "fixed")
            if failure == "dirty" { driver.clean = false }
            if failure == "commit" { driver.commit = "unexpected"; driver.ancestor = false }
            if failure == "ancestry" { driver.ancestor = false }
            if failure == "branch" { driver.branch = "elsewhere" }
            if failure == "root" { driver.workspaceRoot = "/tmp/other" }
            await coordinator.advance(using: driver, threads: [])
            XCTAssertEqual(coordinator.loops.last?.phase, .blocked, failure)
            await coordinator.advance(using: driver, threads: [])
            XCTAssertEqual(driver.createdThreads.count, 1, failure)
        }
    }

    func testReviewEditsBlockBeforeAnyFixPromptOrPush() async throws {
        let (coordinator, _, driver) = try make()
        await coordinator.advance(using: driver, threads: [])
        driver.review(priorities: [.p1])
        driver.clean = false
        await coordinator.advance(using: driver, threads: [])
        XCTAssertEqual(coordinator.loops.last?.phase, .blocked)
        XCTAssertTrue(coordinator.loops.last?.message.contains("Uncommitted changes appeared during the review") == true)
        XCTAssertEqual(driver.prompts.count, 1)
        XCTAssertTrue(driver.pushedCommits.isEmpty)
        XCTAssertFalse(coordinator.loops.last?.rounds.last?.fixRequested ?? true)
    }

    func testReviewMustNotChangeCheckoutAndP3OnlyDoesNotTriggerFix() async throws {
        let (coordinator, _, driver) = try make()
        await coordinator.advance(using: driver, threads: [])
        driver.review(priorities: [.p3])
        await coordinator.advance(using: driver, threads: [])
        XCTAssertEqual(coordinator.loops.last?.phase, .completed)
        XCTAssertEqual(driver.prompts.count, 1, "Never send address-all for P3-only or empty reviews")

        let (changed, _, changedDriver) = try make()
        await changed.advance(using: changedDriver, threads: [])
        changedDriver.review(priorities: [])
        changedDriver.commit = "unexpected"
        await changed.advance(using: changedDriver, threads: [])
        XCTAssertEqual(changed.loops.last?.phase, .blocked)
    }

    func testInterruptionInvalidReportAndChangedTurnBlock() async throws {
        for failure in ["failed", "interrupted", "malformed", "newTurn", "moved"] {
            let (coordinator, _, driver) = try make()
            await coordinator.advance(using: driver, threads: [])
            driver.review(priorities: [])
            driver.thread = ReviewThreadState(cwd: failure == "moved" ? "/tmp/another" : project.path, turns: [
                ReviewTurnState(id: failure == "newTurn" ? "another-turn" : "turn-1",
                                status: ["failed", "interrupted"].contains(failure) ? ReviewTurnStatus(rawValue: failure)! : .completed,
                                finalMessage: failure == "malformed" ? "Done" : driver.thread.turns.last?.finalMessage)
            ])
            await coordinator.advance(using: driver, threads: [])
            XCTAssertEqual(coordinator.loops.last?.phase, .blocked, failure)
        }
    }

    func testRestartPausesAndReconcilesKnownRoundWithoutResending() async throws {
        let (first, store, driver) = try make()
        await first.advance(using: driver, threads: [])
        let recovered = ReviewLoopCoordinator(store: store)
        XCTAssertEqual(recovered.loops.last?.phase, .paused)
        await recovered.advance(using: driver, threads: [])
        XCTAssertEqual(driver.prompts.count, 1)
        try recovered.apply(action(.resume, for: recovered), projects: [project])
        await recovered.advance(using: driver, threads: [])
        XCTAssertEqual(recovered.loops.last?.phase, .running)
        XCTAssertEqual(driver.prompts.count, 1)
        driver.review(priorities: [])
        await recovered.advance(using: driver, threads: [])
        XCTAssertEqual(recovered.loops.last?.phase, .completed)
    }

    func testUnknownLaunchIsNeverRetried() async throws {
        let (coordinator, store, driver) = try make()
        driver.failCreate = true
        await coordinator.advance(using: driver, threads: [])
        XCTAssertEqual(coordinator.loops.last?.phase, .blocked)
        store.loops[store.loops.count - 1].phase = .running // Simulate process loss before the failure was saved.
        let recovered = ReviewLoopCoordinator(store: store)
        try recovered.apply(action(.resume, for: recovered), projects: [project])
        await recovered.advance(using: driver, threads: [])
        XCTAssertEqual(recovered.loops.last?.phase, .blocked)
        XCTAssertEqual(driver.createCalls, 1)
    }

    func testStorageFailurePreventsRemoteSideEffectAndFurtherWork() async throws {
        let (coordinator, store, driver) = try make()
        store.failSave = true
        await coordinator.advance(using: driver, threads: [])
        XCTAssertTrue(driver.createdThreads.isEmpty)
        XCTAssertNotNil(coordinator.error)
        store.failSave = false
        await coordinator.advance(using: driver, threads: [])
        XCTAssertTrue(driver.createdThreads.isEmpty)
    }

    func testRoundLimitFinishesConfiguredWorkWithoutLaunchingAnotherTask() async throws {
        let (coordinator, _, driver) = try make(limit: 1)
        await coordinator.advance(using: driver, threads: [])
        driver.review(priorities: [.p2])
        await coordinator.advance(using: driver, threads: [])
        await coordinator.advance(using: driver, threads: [])
        driver.finish(findings: 1, commit: "fixed")
        await coordinator.advance(using: driver, threads: [])
        XCTAssertEqual(coordinator.loops.last?.phase, .limitReached)
        XCTAssertEqual(coordinator.progress[coordinator.loops.last!.id.uuidString]?.step, "Round limit reached")
        XCTAssertEqual(coordinator.loops.last?.message, "All configured review rounds completed.")
        XCTAssertNil(coordinator.progress[coordinator.loops.last!.id.uuidString]?.upcoming)
        try coordinator.apply(action(.resume, for: coordinator), projects: [project])
        await coordinator.advance(using: driver, threads: [])
        XCTAssertEqual(coordinator.loops.last?.phase, .limitReached)
        XCTAssertEqual(driver.createdThreads.count, 1)
        let previousID = coordinator.loops.last?.id
        try coordinator.apply(startAction(id: "new-start", kind: .start, projectID: project.id,
                                               promptContext: .general, maxRounds: 2, loopID: nil), projects: [project])
        XCTAssertNotEqual(coordinator.loops.last?.id, previousID)
        XCTAssertEqual(coordinator.loops.last?.phase, .waiting)
    }

    func testSavedPausedLoopAtRoundLimitBecomesLimitReached() async throws {
        let (coordinator, store, driver) = try make(limit: 1)
        await coordinator.advance(using: driver, threads: [])
        driver.review(priorities: [.p2])
        await coordinator.advance(using: driver, threads: [])
        await coordinator.advance(using: driver, threads: [])
        driver.finish(findings: 1, commit: "fixed")
        await coordinator.advance(using: driver, threads: [])
        store.loops[store.loops.count - 1].phase = .paused
        let restored = ReviewLoopCoordinator(store: store)
        XCTAssertEqual(restored.loops.last?.phase, .limitReached)
        XCTAssertEqual(store.loops[store.loops.count - 1].phase, .limitReached)
    }

    func testReplayedStartActionDoesNotCreateSecondLoopAfterCompletion() async throws {
        let (coordinator, _, driver) = try make()
        await coordinator.advance(using: driver, threads: [])
        driver.review(priorities: [])
        await coordinator.advance(using: driver, threads: [])
        let id = coordinator.loops.last?.id
        try coordinator.apply(startAction(id: "start", kind: .start, projectID: project.id, promptContext: nil, maxRounds: 5, loopID: nil), projects: [project])
        XCTAssertEqual(coordinator.loops.last?.id, id)
        XCTAssertEqual(coordinator.loops.last?.phase, .completed)
    }

    func testPriorityLimitControlsFixSubmissionForEachFindingCount() async throws {
        for limit in ReviewFinding.Priority.allCases {
            for count in 0...3 {
                let store = ReviewTestStore()
                let coordinator = ReviewLoopCoordinator(store: store)
                var start = startAction(id: UUID().uuidString, kind: .start, projectID: project.id,
                                             promptContext: nil, maxRounds: 5, loopID: nil)
                start.priorityLimit = limit
                try coordinator.apply(start, projects: [project])
                let driver = ReviewTestDriver()
                await coordinator.advance(using: driver, threads: [])
                driver.review(priorities: Array(repeating: limit, count: count))
                await coordinator.advance(using: driver, threads: [])
                await coordinator.advance(using: driver, threads: [])
                if count == 0 {
                    XCTAssertEqual(coordinator.loops.last?.phase, .completed)
                    XCTAssertEqual(driver.prompts.count, 1)
                } else {
                    let loop = try XCTUnwrap(store.loops.last)
                    XCTAssertEqual(driver.prompts.count, 2)
                    XCTAssertEqual(driver.prompts.last, ReviewPrompts.fixPrompt(for: loop, round: try XCTUnwrap(loop.rounds.last)))
                    XCTAssertEqual(driver.createdThreads.count, 1)
                }
            }
        }
    }

    func testPriorityLimitFiltersMixedReportsAndCompletesLowerPriorityOnlyReview() async throws {
        for priorities: [ReviewFinding.Priority] in [[.p2], [.p2, .p1, .p3]] {
            let store = ReviewTestStore()
            let coordinator = ReviewLoopCoordinator(store: store)
            var start = startAction(id: "start", kind: .start, projectID: project.id, promptContext: nil, maxRounds: 5, loopID: nil)
            start.priorityLimit = .p1
            try coordinator.apply(start, projects: [project])
            let driver = ReviewTestDriver()
            await coordinator.advance(using: driver, threads: [])
            driver.review(priorities: priorities)
            await coordinator.advance(using: driver, threads: [])
            await coordinator.advance(using: driver, threads: [])
            XCTAssertEqual(coordinator.loops.last?.phase, priorities.count == 1 ? .completed : .running)
            XCTAssertEqual(driver.prompts.count, priorities.count == 1 ? 1 : 2)
            XCTAssertEqual(coordinator.loops.last?.rounds.last?.review?.findings.count, priorities.count)
            if priorities.count > 1 {
                XCTAssertTrue(driver.prompts.last!.contains("- Finding 2: [P1]"))
                XCTAssertFalse(driver.prompts.last!.contains("[P2]"))
                XCTAssertFalse(driver.prompts.last!.contains("[P3]"))
                driver.finish(findings: 0, commit: "none", withdrawn: [1])
                await coordinator.advance(using: driver, threads: [])
                XCTAssertEqual(coordinator.loops.last?.phase, .blocked, "Excluded finding numbers cannot be withdrawn")
                driver.finish(findings: 0, commit: "none", withdrawn: [2])
                try coordinator.apply(action(.resume, for: coordinator), projects: [project])
                await coordinator.advance(using: driver, threads: [])
                XCTAssertEqual(coordinator.loops.last?.phase, .completed)
                XCTAssertEqual(driver.prompts.count, 2)
            }
        }
    }

    func testPreviouslyBlockedMixedPriorityReviewResumesWithoutFollowUp() async throws {
        let (coordinator, store, driver) = try make()
        await coordinator.advance(using: driver, threads: [])
        driver.review(priorities: [.p3, .p2])
        store.loops[0].phase = .blocked
        store.loops[0].message = "The review included findings outside the selected priority limit."
        let recovered = ReviewLoopCoordinator(store: store)
        try recovered.apply(action(.resume, for: recovered), projects: [project])
        await recovered.advance(using: driver, threads: [])
        await recovered.advance(using: driver, threads: [])
        XCTAssertEqual(recovered.loops.last?.phase, .running)
        XCTAssertEqual(driver.createdThreads.count, 1)
        XCTAssertEqual(driver.prompts.count, 2)
        XCTAssertTrue(driver.prompts.last!.contains("- Finding 2: [P2]"))
        XCTAssertFalse(driver.prompts.last!.contains("[P3]"))
        driver.finish(findings: 1, commit: "fixed")
        await recovered.advance(using: driver, threads: [])
        XCTAssertEqual(recovered.loops.last?.phase, .waiting)
        XCTAssertEqual(recovered.loops.last?.rounds.last?.result?.addressedFindingCount, 1)
    }

    func testSeparateModelSelectionsPersistAndApplyToTheirTurns() async throws {
        let store = ReviewTestStore()
        let coordinator = ReviewLoopCoordinator(store: store)
        var start = startAction(id: "selected", kind: .start, projectID: project.id, promptContext: nil, maxRounds: 3, loopID: nil)
        start.reviewSelection = ReviewModelSelection(modelID: "review-model", reasoningEffort: "high")
        start.fixSelection = ReviewModelSelection(modelID: "fix-model", reasoningEffort: "low")
        start.speed = .fast
        try coordinator.apply(start, projects: [project])
        let driver = ReviewTestDriver()
        await coordinator.advance(using: driver, threads: [])
        driver.review(priorities: [.p1])
        await coordinator.advance(using: driver, threads: [])
        await coordinator.advance(using: driver, threads: [])
        XCTAssertEqual(driver.selections, [start.reviewSelection, start.fixSelection])
        XCTAssertEqual(driver.speeds, [.fast, .fast, .fast])
        XCTAssertEqual(store.loops[store.loops.count - 1].reviewSelection, start.reviewSelection)
        XCTAssertEqual(store.loops[store.loops.count - 1].fixSelection, start.fixSelection)
        XCTAssertEqual(store.loops[store.loops.count - 1].speed, .fast)
        driver.finish(findings: 1, commit: "fixed")
        await coordinator.advance(using: driver, threads: [])
        await coordinator.advance(using: driver, threads: [])
        XCTAssertEqual(driver.selections, [start.reviewSelection, start.fixSelection, start.reviewSelection])
        XCTAssertEqual(driver.speeds, [.fast, .fast, .fast, .fast, .fast])
    }

    func testLiveTestingPersistsAndReachesReviewsAndFixVerification() async throws {
        for reviewType in ReviewType.allCases {
            let store = ReviewTestStore()
            let coordinator = ReviewLoopCoordinator(store: store)
            var start = startAction(id: reviewType.rawValue, kind: .start, projectID: project.id,
                                    promptContext: .general, maxRounds: 3, loopID: nil)
            start.reviewType = reviewType
            start.liveTesting = true
            start.reloadExtensionBeforeTesting = true
            try coordinator.apply(start, projects: [project])
            let saved = try JSONDecoder().decode(ReviewLoop.self, from: JSONEncoder().encode(store.loops[0]))
            XCTAssertEqual(saved.liveTesting, reviewType.supportsLiveTesting)
            XCTAssertEqual(saved.reloadExtensionBeforeTesting, reviewType.supportsLiveTesting)
            let driver = ReviewTestDriver()
            await coordinator.advance(using: driver, threads: [])
            let expectedReview = ReviewPrompts.reviewPrompt(for: saved)
            XCTAssertEqual(driver.prompts, [expectedReview])
            if reviewType.usesPriorities { driver.review(priorities: [.p1]) }
            else { driver.reviewWithoutPriorities() }
            await coordinator.advance(using: driver, threads: [])
            await coordinator.advance(using: driver, threads: [])
            let loop = try XCTUnwrap(store.loops.last)
            let expectedFix = ReviewPrompts.fixPrompt(for: loop, round: try XCTUnwrap(loop.rounds.last))
            XCTAssertEqual(driver.prompts, [expectedReview, expectedFix])
            driver.finish(findings: 1, commit: "fixed")
            await coordinator.advance(using: driver, threads: [])
            await coordinator.advance(using: driver, threads: [])
            XCTAssertEqual(driver.prompts, [expectedReview, expectedFix, expectedReview])
        }
    }

    func testMuteTestPlaybackCanBeEnabledOnBlockedLoopWithoutResuming() throws {
        let store = ReviewTestStore()
        let coordinator = ReviewLoopCoordinator(store: store)
        var start = startAction(id: "mute", kind: .start, projectID: project.id,
                                promptContext: .general, maxRounds: 3, loopID: nil)
        start.liveTesting = true
        start.muteTestPlayback = true
        try coordinator.apply(start, projects: [project])
        var loop = try XCTUnwrap(store.loops.first)
        XCTAssertTrue(loop.muteTestPlayback)
        loop.phase = .blocked
        loop.muteTestPlayback = false
        loop.rounds = [ReviewRound(number: 1, baseRevision: "base", threadID: "thread")]
        store.loops = [loop]
        let restored = ReviewLoopCoordinator(store: store)
        var action = startAction(id: "mute-update", kind: .setMuteTestPlayback, projectID: nil,
                                 promptContext: nil, maxRounds: nil, loopID: loop.id)
        action.muteTestPlayback = true
        try restored.apply(action, projects: [project])
        XCTAssertTrue(store.loops[0].muteTestPlayback)
        XCTAssertEqual(store.loops[0].phase, .blocked)
        XCTAssertEqual(store.loops[0].rounds, loop.rounds)
        action.muteTestPlayback = false
        try restored.apply(action, projects: [project])
        XCTAssertFalse(store.loops[0].muteTestPlayback)
    }

    func testMuteTestPlaybackRequiresLiveTesting() throws {
        let store = ReviewTestStore()
        let coordinator = ReviewLoopCoordinator(store: store)
        var start = startAction(id: "mute-no-live", kind: .start, projectID: project.id,
                                promptContext: .general, maxRounds: 3, loopID: nil)
        start.muteTestPlayback = true
        try coordinator.apply(start, projects: [project])
        XCTAssertFalse(store.loops[0].muteTestPlayback)
        var action = startAction(id: "mute-update", kind: .setMuteTestPlayback, projectID: nil,
                                 promptContext: nil, maxRounds: nil, loopID: store.loops[0].id)
        action.muteTestPlayback = true
        XCTAssertThrowsError(try coordinator.apply(action, projects: [project]))
    }

    func testExtensionOptionRequiresLiveTesting() throws {
        let store = ReviewTestStore()
        let coordinator = ReviewLoopCoordinator(store: store)
        var start = startAction(id: "extension", kind: .start, projectID: project.id,
                                promptContext: .general, maxRounds: 3, loopID: nil)
        start.reloadExtensionBeforeTesting = true
        try coordinator.apply(start, projects: [project])
        XCTAssertFalse(try XCTUnwrap(store.loops.first).reloadExtensionBeforeTesting)
    }

    func testReviewTypePersistsAndDrivesBothTurnsAndNextRound() async throws {
        for reviewType in ReviewType.allCases {
            let store = ReviewTestStore()
            let coordinator = ReviewLoopCoordinator(store: store)
            var start = startAction(id: "reviewType", kind: .start, projectID: project.id,
                                         promptContext: .general, maxRounds: 3, loopID: nil)
            start.reviewType = reviewType
            try coordinator.apply(start, projects: [project])
            let saved = try JSONDecoder().decode(ReviewLoop.self, from: JSONEncoder().encode(store.loops[0]))
            XCTAssertEqual(saved.reviewType, reviewType)
            XCTAssertEqual(saved.priorityLimit, reviewType.usesPriorities ? .p2 : nil)
            let expectedReview = ReviewPrompts.reviewPrompt(for: saved)
            let driver = ReviewTestDriver()
            await coordinator.advance(using: driver, threads: [])
            if reviewType.usesPriorities { driver.review(priorities: [.p1]) }
            else { driver.reviewWithoutPriorities() }
            await coordinator.advance(using: driver, threads: [])
            await coordinator.advance(using: driver, threads: [])
            let loop = try XCTUnwrap(store.loops.last)
            let expectedFix = ReviewPrompts.fixPrompt(for: loop, round: try XCTUnwrap(loop.rounds.last))
            XCTAssertEqual(driver.prompts, [expectedReview, expectedFix])
            driver.finish(findings: 1, commit: "fixed")
            await coordinator.advance(using: driver, threads: [])
            await coordinator.advance(using: driver, threads: [])
            XCTAssertEqual(driver.prompts, [expectedReview, expectedFix, expectedReview])
        }
    }
}
