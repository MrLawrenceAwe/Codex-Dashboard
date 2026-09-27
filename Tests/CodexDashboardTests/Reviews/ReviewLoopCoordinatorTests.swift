import XCTest
@testable import CodexDashboard

@MainActor
final class ReviewLoopCoordinatorTests: XCTestCase {
    private let project = ReviewProject(id: "project", name: "Example", path: "/tmp/example")

    private func make(limit: Int = 5) throws -> (ReviewLoopCoordinator, ReviewTestStore, ReviewTestDriver) {
        let store = ReviewTestStore()
        let coordinator = ReviewLoopCoordinator(store: store)
        try coordinator.apply(ReviewLoopAction(id: "start", kind: "start", projectID: project.id,
                                              instructions: "", maxRounds: limit, loopID: nil), projects: [project])
        return (coordinator, store, ReviewTestDriver())
    }

    private func action(_ kind: String, for coordinator: ReviewLoopCoordinator) -> ReviewLoopAction {
        ReviewLoopAction(id: UUID().uuidString, kind: kind, projectID: nil, instructions: nil, maxRounds: nil, loopID: coordinator.loops.last?.id)
    }

    private func stop(_ coordinator: ReviewLoopCoordinator) {
        do { try coordinator.apply(action("stop", for: coordinator), projects: [project]) }
        catch { XCTFail("Could not stop review loop: \(error)") }
    }

    func testConcurrentProjectsKeepIndependentControlsAndRecovery() async throws {
        let (coordinator, store, driver) = try make()
        let second = ReviewProject(id: "second", name: "Second", path: "/tmp/second")
        let start = ReviewLoopAction(id: "second-start", kind: "start", projectID: second.id,
                                     instructions: "", maxRounds: 3, loopID: nil)
        try coordinator.apply(start, projects: [project, second])
        try coordinator.apply(start, projects: [project, second])
        XCTAssertEqual(coordinator.loops.count, 2)
        await coordinator.advance(using: driver, threads: [])
        XCTAssertEqual(driver.createCalls, 2)
        XCTAssertEqual(coordinator.loops.map(\.phase), [.running, .running])
        XCTAssertEqual(Set(coordinator.loops.compactMap { $0.rounds.last?.threadID }).count, 2)
        try coordinator.apply(action("stop", for: coordinator), projects: [project, second])
        XCTAssertEqual(coordinator.loops.map(\.phase), [.running, .stopped])
        let recovered = ReviewLoopCoordinator(store: store)
        XCTAssertEqual(recovered.loops.map(\.phase), [.paused, .stopped])
        XCTAssertEqual(recovered.loops.map(\.id), coordinator.loops.map(\.id))
    }

    func testOneProjectInspectionFailureDoesNotPreventOtherLaunches() async throws {
        let (coordinator, _, driver) = try make()
        let second = ReviewProject(id: "second", name: "Second", path: "/tmp/second")
        try coordinator.apply(ReviewLoopAction(id: "second-start", kind: "start", projectID: second.id,
                                              instructions: "", maxRounds: 3, loopID: nil), projects: [second])
        driver.failingPath = project.path
        await coordinator.advance(using: driver, threads: [])
        XCTAssertEqual(coordinator.loops.map(\.phase), [.paused, .running])
        XCTAssertEqual(driver.createCalls, 1)
    }

    func testProjectsSharingCheckoutDoNotLaunchTogetherAfterRestart() async throws {
        let (coordinator, store, driver) = try make()
        await coordinator.advance(using: driver, threads: [])
        let recovered = ReviewLoopCoordinator(store: store)
        let second = ReviewProject(id: "nested", name: "Nested", path: "/tmp/example/subdir")
        try recovered.apply(ReviewLoopAction(id: "nested-start", kind: "start", projectID: second.id,
                                            instructions: "", maxRounds: 3, loopID: nil), projects: [second])
        driver.repositoryRoot = project.path
        await recovered.advance(using: driver, threads: [])
        XCTAssertEqual(driver.createCalls, 1)
        XCTAssertEqual(recovered.loops.map(\.phase), [.paused, .waiting])
    }

    func testOneActiveLoopPerProjectIncludingPausedAndChangedPath() throws {
        let (coordinator, _, _) = try make()
        let start = ReviewLoopAction(id: "duplicate", kind: "start", projectID: project.id,
                                     instructions: "", maxRounds: 3, loopID: nil)
        XCTAssertThrowsError(try coordinator.apply(start, projects: [project]))
        try coordinator.apply(action("pause", for: coordinator), projects: [project])
        let moved = ReviewProject(id: project.id, name: project.name, path: "/tmp/moved")
        XCTAssertThrowsError(try coordinator.apply(start, projects: [moved]))
        stop(coordinator)
        try coordinator.apply(start, projects: [project])
        XCTAssertEqual(coordinator.loops.count, 2)
        XCTAssertEqual(coordinator.loops.map(\.phase), [.stopped, .waiting])
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
        XCTAssertEqual(driver.createdThreads.count, 1, "Do not launch in the same checkpoint observation")
        await coordinator.advance(using: driver, threads: [])
        XCTAssertEqual(driver.createdThreads, ["thread-1", "thread-2"])
        XCTAssertEqual(driver.prompts[2], "Review project for bugs and issues.")
        XCTAssertFalse(driver.prompts[2].contains("last round's findings"))
        driver.review(priorities: [])
        await coordinator.advance(using: driver, threads: [])
        XCTAssertEqual(coordinator.loops.last?.phase, .completed)
        await coordinator.advance(using: driver, threads: [])
        XCTAssertEqual(driver.createdThreads.count, 2)
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

    func testProgressTracksSubmittedAndConditionalPrompts() async throws {
        let (coordinator, _, driver) = try make()
        XCTAssertNil(coordinator.progress[coordinator.loops.last!.id.uuidString]?.current)
        XCTAssertEqual(coordinator.progress[coordinator.loops.last!.id.uuidString]?.upcoming?.text, "Review project for bugs and issues.")
        await coordinator.advance(using: driver, threads: [])
        XCTAssertEqual(coordinator.progress[coordinator.loops.last!.id.uuidString]?.step, "Reviewing")
        XCTAssertEqual(coordinator.progress[coordinator.loops.last!.id.uuidString]?.current?.text, driver.prompts.last)
        XCTAssertTrue(coordinator.progress[coordinator.loops.last!.id.uuidString]?.upcoming?.note.contains("Only if") == true)
        driver.review(priorities: [.p1, .p2])
        await coordinator.advance(using: driver, threads: [])
        XCTAssertEqual(coordinator.progress[coordinator.loops.last!.id.uuidString]?.step, "Preparing fixes")
        XCTAssertEqual(coordinator.progress[coordinator.loops.last!.id.uuidString]?.upcoming?.text, "Fix both findings; commit once")
        await coordinator.advance(using: driver, threads: [])
        XCTAssertEqual(coordinator.progress[coordinator.loops.last!.id.uuidString]?.current?.text, driver.prompts.last)
        XCTAssertEqual(coordinator.progress[coordinator.loops.last!.id.uuidString]?.upcoming?.text, "Review project for bugs and issues.")
        try coordinator.apply(action("pause", for: coordinator), projects: [project])
        XCTAssertTrue(coordinator.progress[coordinator.loops.last!.id.uuidString]?.upcoming?.note.contains("resume") == true)
        driver.finish(findings: 2, commit: "fixed")
        await coordinator.advance(using: driver, threads: [])
        XCTAssertEqual(coordinator.progress[coordinator.loops.last!.id.uuidString]?.step, "Paused")
        XCTAssertEqual(coordinator.progress[coordinator.loops.last!.id.uuidString]?.upcoming?.text, "Review project for bugs and issues.")
        try coordinator.apply(action("stop", for: coordinator), projects: [project])
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
        try coordinator.apply(action("resume", for: coordinator), projects: [project])
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
        try coordinator.apply(action("resume", for: coordinator), projects: [project])
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
        try coordinator.apply(action("resume", for: coordinator), projects: [project])
        await coordinator.advance(using: driver, threads: [])
        await coordinator.advance(using: driver, threads: [])
        XCTAssertEqual(driver.prompts.count, 2)
        XCTAssertEqual(driver.createdThreads.count, 1)
    }

    func testWaitsForOtherRunningTaskIncludingProjectSubdirectory() async throws {
        let (coordinator, _, driver) = try make()
        let thread = ThreadSummary(id: "other", title: "Other", preview: "Other", projectName: "Example", projectPath: "/tmp/example/Sources", recencyEpochMillis: 1, isPinned: false, model: nil, runState: .running, latestLifecycleEvent: nil, workingTreeStatus: .clean)
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
        try recovered.apply(action("resume", for: recovered), projects: [project])
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
        try recovered.apply(action("resume", for: recovered), projects: [project])
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
        try coordinator.apply(action("pause", for: coordinator), projects: [project])
        XCTAssertEqual(coordinator.loops.last?.phase, .running)
        driver.review(priorities: [.p2])
        await coordinator.advance(using: driver, threads: [])
        await coordinator.advance(using: driver, threads: [])
        driver.finish(findings: 1, commit: "fixed")
        await coordinator.advance(using: driver, threads: [])
        XCTAssertEqual(coordinator.loops.last?.phase, .paused)
        try coordinator.apply(action("stop", for: coordinator), projects: [project])
        await coordinator.advance(using: driver, threads: [])
        XCTAssertEqual(coordinator.loops.last?.phase, .stopped)
        XCTAssertEqual(driver.createdThreads.count, 1)
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
        XCTAssertEqual(coordinator.progress[coordinator.loops.last!.id.uuidString]?.step, "Limit reached")
        XCTAssertEqual(coordinator.loops.last?.message, "All configured review rounds completed.")
        XCTAssertNil(coordinator.progress[coordinator.loops.last!.id.uuidString]?.upcoming)
        try coordinator.apply(action("resume", for: coordinator), projects: [project])
        await coordinator.advance(using: driver, threads: [])
        XCTAssertEqual(coordinator.loops.last?.phase, .limitReached)
        XCTAssertEqual(driver.createdThreads.count, 1)
        let previousID = coordinator.loops.last?.id
        try coordinator.apply(ReviewLoopAction(id: "new-start", kind: "start", projectID: project.id,
                                               instructions: "", maxRounds: 2, loopID: nil), projects: [project])
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
        try coordinator.apply(ReviewLoopAction(id: "start", kind: "start", projectID: project.id, instructions: nil, maxRounds: 5, loopID: nil), projects: [project])
        XCTAssertEqual(coordinator.loops.last?.id, id)
        XCTAssertEqual(coordinator.loops.last?.phase, .completed)
    }

    func testPriorityLimitAndExactFollowUpWording() async throws {
        for limit in ReviewFinding.Priority.allCases {
            for count in 0...3 {
                let store = ReviewTestStore()
                let coordinator = ReviewLoopCoordinator(store: store)
                var start = ReviewLoopAction(id: UUID().uuidString, kind: "start", projectID: project.id,
                                             instructions: nil, maxRounds: 5, loopID: nil)
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
                    XCTAssertEqual(driver.prompts.last, count == 1 ? "Fix the finding; commit once" : count == 2 ? "Fix both findings; commit once" : "Fix all findings; commit once")
                    XCTAssertEqual(driver.createdThreads.count, 1)
                }
            }
        }
    }

    func testPriorityLimitRejectsLowerPriorityAndNeverSendsAddressAllForMixedReport() async throws {
        for priorities: [ReviewFinding.Priority] in [[.p2], [.p1, .p2]] {
            let store = ReviewTestStore()
            let coordinator = ReviewLoopCoordinator(store: store)
            var start = ReviewLoopAction(id: "start", kind: "start", projectID: project.id, instructions: nil, maxRounds: 5, loopID: nil)
            start.priorityLimit = .p1
            try coordinator.apply(start, projects: [project])
            let driver = ReviewTestDriver()
            await coordinator.advance(using: driver, threads: [])
            driver.review(priorities: priorities)
            await coordinator.advance(using: driver, threads: [])
            await coordinator.advance(using: driver, threads: [])
            XCTAssertEqual(coordinator.loops.last?.phase, priorities.count == 1 ? .completed : .blocked)
            XCTAssertEqual(driver.prompts.count, 1)
        }
    }

    func testSeparateModelSelectionsPersistAndApplyToTheirTurns() async throws {
        let store = ReviewTestStore()
        let coordinator = ReviewLoopCoordinator(store: store)
        var start = ReviewLoopAction(id: "selected", kind: "start", projectID: project.id, instructions: nil, maxRounds: 3, loopID: nil)
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

    func testPerformanceReviewIncludesOptionalProjectContext() {
        var loop = ReviewLoop(id: UUID(), startActionID: "performance", project: project,
                              instructions: "(this is a project for personal use)", maxRounds: 3)
        loop.focus = .performance
        XCTAssertEqual(ReviewLoopPresentation.reviewPrompt(for: loop),
                       "Review project for performance and responsiveness (this is a project for personal use).")
    }

    func testReviewFocusPersistsAndDrivesBothTurnsAndNextRound() async throws {
        for focus in ReviewFocus.allCases {
            let store = ReviewTestStore()
            let coordinator = ReviewLoopCoordinator(store: store)
            var start = ReviewLoopAction(id: "focus", kind: "start", projectID: project.id,
                                         instructions: "", maxRounds: 3, loopID: nil)
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
                expectedFix = "Fix the finding; commit once"
            case .organisation:
                expectedReview = "Do a code minimisation and organisation review."
                expectedFix = "Address the finding by minimising and organising the code while preserving behaviour; commit once"
            case .naming:
                expectedReview = "Do a code minimisation and organisation review, and suggest improvements where naming (e.g. folders, files, classes, variables, functions, UI, etc.) is undescriptive, too long, overly abbreviated, or misleading."
                expectedFix = "Address the finding by minimising and organising the code and improving unclear, overly long, abbreviated, or misleading names. Update affected references consistently and preserve behaviour; commit once"
            case .performance:
                expectedReview = "Review project for performance and responsiveness."
                expectedFix = "Address the finding to improve performance and responsiveness. Keep changes proportionate, preserve behaviour, and verify the improvements; commit once"
            }
            let driver = ReviewTestDriver()
            await coordinator.advance(using: driver, threads: [])
            if focus.usesPriorities { driver.review(priorities: [.p1]) }
            else { driver.reviewWithoutPriorities() }
            await coordinator.advance(using: driver, threads: [])
            await coordinator.advance(using: driver, threads: [])
            XCTAssertEqual(driver.prompts, [expectedReview, expectedFix])
            driver.finish(findings: 1, commit: "fixed")
            await coordinator.advance(using: driver, threads: [])
            await coordinator.advance(using: driver, threads: [])
            XCTAssertEqual(driver.prompts, [expectedReview, expectedFix, expectedReview])
        }
    }

    func testFileStoreRoundTripsAndDoesNotOverwriteCorruptData() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("loop.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = ReviewLoopFileStore(url: url)
        let (coordinator, _, _) = try make()
        try store.save(coordinator.loops)
        XCTAssertEqual(try store.load(), coordinator.loops)
        var olderLoop = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(try XCTUnwrap(coordinator.loops.last))) as? [String: Any])
        olderLoop.removeValue(forKey: "speed")
        olderLoop.removeValue(forKey: "focus")
        try JSONSerialization.data(withJSONObject: olderLoop).write(to: url)
        XCTAssertEqual(try store.load().first?.speed, .standard)
        XCTAssertEqual(try store.load().first?.focus, .bugs)
        try Data("broken".utf8).write(to: url)
        let recovered = ReviewLoopCoordinator(store: store)
        XCTAssertNotNil(recovered.error)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "broken")
    }
}

@MainActor
private final class ReviewTestStore: ReviewLoopStoring {
    var loops: [ReviewLoop] = []
    var failSave = false
    func load() throws -> [ReviewLoop] { loops }
    func save(_ loops: [ReviewLoop]) throws {
        if failSave { throw ReviewLoopError("disk full") }
        self.loops = loops
    }
}

@MainActor
private final class ReviewTestDriver: ReviewLoopDriving {
    var clean = true
    var commit = "base"
    var branch = "main"
    var ancestor = true
    var resolvedCommit: String?
    var onResolveCommit: (() -> Void)?
    var failCreate = false
    var failRepository = false
    var failingPath: String?
    var repositoryRoot: String?
    var failReadThread = false
    var createCalls = 0
    var createdThreads: [String] = []
    var prompts: [String] = []
    var selections: [ReviewModelSelection?] = []
    var speeds: [ReviewSpeed] = []
    var thread = ReviewThreadState(cwd: "/tmp/example", turns: [])
    var onRepository: (() -> Void)?
    var onCreateThread: (() -> Void)?
    var onStartTurn: (() -> Void)?
    var onReadThread: (() -> Void)?
    func projects() async throws -> [ReviewProject] { [] }
    func repository(at path: String) async throws -> ReviewRepositoryState {
        await Task.yield()
        onRepository?()
        if failRepository || path == failingPath { throw ReviewLoopError("Git timed out") }
        return ReviewRepositoryState(root: repositoryRoot ?? path, branch: branch, commit: commit, clean: clean)
    }
    func isAncestor(_ commit: String, of head: String, at path: String) async throws -> Bool { ancestor }
    func resolveCommit(_ commit: String, at path: String) async throws -> String {
        onResolveCommit?()
        return resolvedCommit ?? commit
    }
    func createThread(project: ReviewProject, title: String, speed: ReviewSpeed) async throws -> String {
        speeds.append(speed)
        createCalls += 1
        if failCreate { throw ReviewLoopError("Lost response") }
        let id = "thread-\(createdThreads.count + 1)"
        createdThreads.append(id)
        thread = ReviewThreadState(cwd: "/tmp/example", turns: [])
        onCreateThread?()
        return id
    }
    func startTurn(threadID: String, prompt: String, kind: ReviewTurnKind, selection: ReviewModelSelection?, speed: ReviewSpeed) async throws -> String {
        prompts.append(prompt)
        selections.append(selection)
        speeds.append(speed)
        let id = "turn-\(prompts.count)"
        thread = ReviewThreadState(cwd: "/tmp/example", turns: thread.turns + [ReviewTurnState(id: id, status: "inProgress", finalMessage: nil)])
        onStartTurn?()
        return id
    }
    func readThread(_ threadID: String) async throws -> ReviewThreadState {
        onReadThread?()
        if failReadThread { throw ReviewLoopError("Connection timed out") }
        return thread
    }
    func review(priorities: [ReviewFinding.Priority]) {
        let findings = priorities.map { "## [\($0.rawValue)] Example issue\nEvidence and impact" }.joined(separator: "\n\n")
        finishTurn("# Review complete\n\nFindings: \(priorities.count)\n\n## Summary\nReview finished\n\n" + findings)
    }
    func reviewWithoutPriorities() {
        finishTurn("# Review complete\n\nFindings: 1\n\n## Summary\nReview finished\n\n## Simplify the layout\nEvidence and impact")
    }
    func finish(findings: Int, commit: String) {
        self.commit = commit
        finishTurn("# Fixes committed\n\nFindings addressed: \(findings)\nCommit: `\(commit)`\n\n## Summary\nChanges committed")
    }
    private func finishTurn(_ report: String) {
        let last = thread.turns.last!
        thread = ReviewThreadState(cwd: thread.cwd, turns: thread.turns.dropLast() + [
            ReviewTurnState(id: last.id, status: "completed", finalMessage: report)
        ])
    }
}
