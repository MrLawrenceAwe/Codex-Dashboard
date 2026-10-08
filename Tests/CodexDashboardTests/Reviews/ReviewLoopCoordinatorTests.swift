import XCTest
@testable import CodexDashboard

@MainActor
final class ReviewLoopCoordinatorTests: ReviewLoopTestCase {
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
        driver.repositoryRoot = project.path
        await recovered.advance(using: driver, threads: [])
        XCTAssertEqual(driver.createCalls, 1)
        XCTAssertEqual(recovered.loops.map(\.phase), [.paused, .blocked])
        XCTAssertEqual(recovered.loops.last?.message,
                       "This Git checkout already has an active review loop for Example. Stop that loop before starting another.")
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
        XCTAssertEqual(driver.prompts[2], "Review project for bugs and issues." + reviewBoundary)
        XCTAssertFalse(driver.prompts[2].contains("last round's findings"))
        driver.review(priorities: [])
        await coordinator.advance(using: driver, threads: [])
        XCTAssertEqual(coordinator.loops.last?.phase, .completed)
        await coordinator.advance(using: driver, threads: [])
        XCTAssertEqual(driver.createdThreads.count, 2)
    }

    func testReviewCountsAllSectionsAndFixesThemDespiteIncorrectSummaryTotal() async throws {
        let store = ReviewTestStore()
        let coordinator = ReviewLoopCoordinator(store: store)
        var start = startAction(id: "count-sections", kind: .start, projectID: project.id,
                                promptContext: .general, maxRounds: 1, loopID: nil)
        start.focus = .organisationAndNaming
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
        XCTAssertEqual(coordinator.loops.last?.expectedCommit, fullCommit)
        XCTAssertEqual(coordinator.loops.last?.rounds.last?.result?.commit, fullCommit)
        XCTAssertEqual(driver.prompts.count, 2)
    }

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

    func testRepositoryReadFailurePausesUntilResumeWithoutLaunching() async throws {
        let (coordinator, _, driver) = try make()
        driver.failRepository = true
        await coordinator.advance(using: driver, threads: [])
        XCTAssertEqual(coordinator.loops.last?.phase, .paused)
        XCTAssertTrue(driver.createdThreads.isEmpty)
        driver.failRepository = false
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
        driver.failRepository = true
        await coordinator.advance(using: driver, threads: [])
        XCTAssertEqual(coordinator.loops.last?.phase, .paused)
        XCTAssertEqual(driver.prompts.count, 1)
        driver.failRepository = false
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
        for failure in ["dirty", "commit", "ancestry", "branch", "noCommit", "findings"] {
            let (coordinator, _, driver) = try make()
            await coordinator.advance(using: driver, threads: [])
            driver.review(priorities: [.p2])
            await coordinator.advance(using: driver, threads: [])
            await coordinator.advance(using: driver, threads: [])
            driver.finish(findings: failure == "findings" ? 0 : 1, commit: failure == "noCommit" ? "base" : "fixed")
            if failure == "dirty" { driver.clean = false }
            if failure == "commit" { driver.commit = "unexpected" }
            if failure == "ancestry" { driver.ancestor = false }
            if failure == "branch" { driver.branch = "elsewhere" }
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
                                status: ["failed", "interrupted"].contains(failure) ? failure : "completed",
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
            XCTAssertEqual(driver.thread.turns.last?.status, "interrupted")
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
        XCTAssertEqual(driver.thread.turns.last?.status, "completed")
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

    func testStopDuringRepositoryCheckPreventsReviewLaunch() async throws {
        let (coordinator, _, driver) = try make()
        driver.onRepository = { self.stop(coordinator) }
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

    func testPriorityLimitAndExactFollowUpWording() async throws {
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
                    let task = count == 1 ? "Fix the finding and commit" : count == 2 ? "Fix both findings and commit" : "Fix all findings and commit"
                    XCTAssertEqual(driver.prompts.last, task + ". Verify each finding first. Mark invalid findings as withdrawn; if all are invalid, make no commit.")
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
        for focus in ReviewFocus.allCases {
            let store = ReviewTestStore()
            let coordinator = ReviewLoopCoordinator(store: store)
            var start = startAction(id: focus.rawValue, kind: .start, projectID: project.id,
                                    promptContext: .general, maxRounds: 3, loopID: nil)
            start.focus = focus
            start.liveTesting = true
            start.reloadExtensionBeforeTesting = true
            try coordinator.apply(start, projects: [project])
            let saved = try JSONDecoder().decode(ReviewLoop.self, from: JSONEncoder().encode(store.loops[0]))
            XCTAssertEqual(saved.liveTesting, focus.supportsLiveTesting)
            XCTAssertEqual(saved.reloadExtensionBeforeTesting, focus.supportsLiveTesting)
            let driver = ReviewTestDriver()
            await coordinator.advance(using: driver, threads: [])
            XCTAssertEqual(driver.prompts[0].contains("Use code review and live testing to find bugs and issues."), focus.supportsLiveTesting)
            XCTAssertEqual(driver.prompts[0].contains("Use the globally configured chrome-devtools MCP server"), focus.supportsLiveTesting)
            if focus.usesPriorities { driver.review(priorities: [.p1]) }
            else { driver.reviewWithoutPriorities() }
            await coordinator.advance(using: driver, threads: [])
            await coordinator.advance(using: driver, threads: [])
            var withoutLiveTesting = saved
            withoutLiveTesting.liveTesting = false
            let baseFix = ReviewPrompts.fixPrompt(for: withoutLiveTesting, round: try XCTUnwrap(store.loops[0].rounds.last))
            let liveVerification = focus.supportsLiveTesting
                ? "\n\nVerify fixes for findings discovered through live testing using live testing." : ""
            XCTAssertTrue(driver.prompts[1].hasPrefix(baseFix + liveVerification))
            XCTAssertEqual(driver.prompts[1].contains("After changes, run any required build and reload the same extension before live verification."), focus.supportsLiveTesting)
            driver.finish(findings: 1, commit: "fixed")
            await coordinator.advance(using: driver, threads: [])
            await coordinator.advance(using: driver, threads: [])
            XCTAssertEqual(driver.prompts[2].contains("Use code review and live testing to find bugs and issues."), focus.supportsLiveTesting)
            XCTAssertEqual(driver.prompts[2].contains("Use the globally configured chrome-devtools MCP server"), focus.supportsLiveTesting)
        }
    }

    func testMuteMediaCanBeEnabledOnBlockedLoopWithoutResuming() throws {
        let store = ReviewTestStore()
        let coordinator = ReviewLoopCoordinator(store: store)
        var start = startAction(id: "mute", kind: .start, projectID: project.id,
                                promptContext: .general, maxRounds: 3, loopID: nil)
        start.liveTesting = true
        start.muteMedia = true
        try coordinator.apply(start, projects: [project])
        var loop = try XCTUnwrap(store.loops.first)
        XCTAssertTrue(loop.muteMedia)
        loop.phase = .blocked
        loop.muteMedia = false
        loop.rounds = [ReviewRound(number: 1, baseCommit: "base", threadID: "thread")]
        store.loops = [loop]
        let restored = ReviewLoopCoordinator(store: store)
        var action = startAction(id: "mute-update", kind: .setMuteMedia, projectID: nil,
                                 promptContext: nil, maxRounds: nil, loopID: loop.id)
        action.muteMedia = true
        try restored.apply(action, projects: [project])
        XCTAssertTrue(store.loops[0].muteMedia)
        XCTAssertEqual(store.loops[0].phase, .blocked)
        XCTAssertEqual(store.loops[0].rounds, loop.rounds)
        action.muteMedia = false
        try restored.apply(action, projects: [project])
        XCTAssertFalse(store.loops[0].muteMedia)
    }

    func testMuteMediaRequiresLiveTesting() throws {
        let store = ReviewTestStore()
        let coordinator = ReviewLoopCoordinator(store: store)
        var start = startAction(id: "mute-no-live", kind: .start, projectID: project.id,
                                promptContext: .general, maxRounds: 3, loopID: nil)
        start.muteMedia = true
        try coordinator.apply(start, projects: [project])
        XCTAssertFalse(store.loops[0].muteMedia)
        var action = startAction(id: "mute-update", kind: .setMuteMedia, projectID: nil,
                                 promptContext: nil, maxRounds: nil, loopID: store.loops[0].id)
        action.muteMedia = true
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
        var loop = try XCTUnwrap(store.loops.first)
        loop.reloadExtensionBeforeTesting = true
        XCTAssertFalse(ReviewPrompts.reviewPrompt(for: loop).contains("Computer Use"))
    }

    func testReviewFocusPersistsAndDrivesBothTurnsAndNextRound() async throws {
        for focus in ReviewFocus.allCases {
            let store = ReviewTestStore()
            let coordinator = ReviewLoopCoordinator(store: store)
            var start = startAction(id: "focus", kind: .start, projectID: project.id,
                                         promptContext: .general, maxRounds: 3, loopID: nil)
            start.focus = focus
            try coordinator.apply(start, projects: [project])
            let saved = try JSONDecoder().decode(ReviewLoop.self, from: JSONEncoder().encode(store.loops[0]))
            XCTAssertEqual(saved.focus, focus)
            XCTAssertEqual(saved.priorityLimit, focus.usesPriorities ? .p2 : nil)
            let expectedReview: String
            let expectedFix: String
            switch focus {
            case .bugs:
                expectedReview = "Review project for bugs and issues."
                expectedFix = "Fix the finding and commit"
            case .bugsAndPerformance:
                expectedReview = "Review project for bugs, issues, performance and responsiveness."
                expectedFix = "Fix the finding and commit"
            case .organisation:
                expectedReview = "Review code and content for simplification and organisation."
                expectedFix = "Address the finding and commit"
            case .organisationAndNaming:
                expectedReview = "Review code and content for simplification, organisation, and unclear, verbose, over-abbreviated, or misleading names."
                expectedFix = "Address the finding and commit"
            case .content:
                expectedReview = "Review project for content accuracy, clarity, wording, consistency, completeness, presentation, and effectiveness for its intended purpose."
                expectedFix = "Address the finding and commit"
            case .performance:
                expectedReview = "Review project for performance and responsiveness."
                expectedFix = "Address the finding and commit"
            }
            let driver = ReviewTestDriver()
            await coordinator.advance(using: driver, threads: [])
            if focus.usesPriorities { driver.review(priorities: [.p1]) }
            else { driver.reviewWithoutPriorities() }
            await coordinator.advance(using: driver, threads: [])
            await coordinator.advance(using: driver, threads: [])
            let fullFixPrompt = expectedFix + ". Verify each finding first. Mark invalid findings as withdrawn; if all are invalid, make no commit."
            func taskParagraphs(_ prompt: String) -> String {
                prompt.components(separatedBy: "\n\nScope: ").first!
            }
            XCTAssertEqual(driver.prompts.map(taskParagraphs), [expectedReview + reviewBoundary, fullFixPrompt])
            driver.finish(findings: 1, commit: "fixed")
            await coordinator.advance(using: driver, threads: [])
            await coordinator.advance(using: driver, threads: [])
            XCTAssertEqual(driver.prompts.map(taskParagraphs), [expectedReview + reviewBoundary, fullFixPrompt, expectedReview + reviewBoundary])
        }
    }
}
