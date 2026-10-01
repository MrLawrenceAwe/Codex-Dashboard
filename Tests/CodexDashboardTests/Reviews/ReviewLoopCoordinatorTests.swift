import XCTest
@testable import CodexDashboard

@MainActor
final class ReviewLoopCoordinatorTests: XCTestCase {
    private let project = ReviewProject(id: "project", name: "Example", path: "/tmp/example")

    private func startAction(id: String, kind: ReviewLoopAction.Kind, projectID: String?,
                             promptContext: ReviewPromptContext?, maxRounds: Int?, loopID: UUID?) -> ReviewLoopAction {
        var action = ReviewLoopAction(id: id, kind: kind, projectID: projectID,
                                      promptContext: promptContext, maxRounds: maxRounds, loopID: loopID)
        action.reviewSelection = ReviewModelSelection(modelID: "review-model", reasoningEffort: nil)
        action.fixSelection = ReviewModelSelection(modelID: "fix-model", reasoningEffort: nil)
        return action
    }

    private func make(limit: Int = 5) throws -> (ReviewLoopCoordinator, ReviewTestStore, ReviewTestDriver) {
        let store = ReviewTestStore()
        let coordinator = ReviewLoopCoordinator(store: store)
        try coordinator.apply(startAction(id: "start", kind: .start, projectID: project.id,
                                              promptContext: .general, maxRounds: limit, loopID: nil), projects: [project])
        return (coordinator, store, ReviewTestDriver())
    }

    private func action(_ kind: ReviewLoopAction.Kind, for coordinator: ReviewLoopCoordinator) -> ReviewLoopAction {
        ReviewLoopAction(id: UUID().uuidString, kind: kind, projectID: nil, promptContext: nil, maxRounds: nil, loopID: coordinator.loops.last?.id)
    }

    private func stop(_ coordinator: ReviewLoopCoordinator) {
        do { try coordinator.apply(action(.stop, for: coordinator), projects: [project]) }
        catch { XCTFail("Could not stop review loop: \(error)") }
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

    func testRendererPromptContextDecodesAndBuildsPersonalPrompt() throws {
        let payload = Data("""
        {"id":"start","kind":"start","projectID":"project","promptContext":{"kind":"personal"},"maxRounds":3,"reviewSelection":{"modelID":"review-model"},"fixSelection":{"modelID":"fix-model"}}
        """.utf8)
        let action = try JSONDecoder().decode(ReviewLoopAction.self, from: payload)
        let store = ReviewTestStore()
        let coordinator = ReviewLoopCoordinator(store: store)
        try coordinator.apply(action, projects: [project])
        XCTAssertEqual(coordinator.loops.first?.promptContext, .personal)
        XCTAssertEqual(ReviewPrompts.reviewPrompt(for: try XCTUnwrap(coordinator.loops.first)),
                       "Review project for bugs and issues (this is a project for personal use).")
    }

    func testUnknownReviewActionKindDoesNotDecode() {
        let payload = Data(#"{"id":"unknown","kind":"retry"}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(ReviewLoopAction.self, from: payload))
    }

    func testReviewFileLinksStayInsideTheProject() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("review-files-\(UUID().uuidString)")
        let project = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = project.appendingPathComponent("File.swift")
        try Data("source".utf8).write(to: file)
        let outside = root.appendingPathComponent("outside.swift")
        try Data("outside".utf8).write(to: outside)
        let alias = project.appendingPathComponent("alias.swift")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: outside)

        XCTAssertEqual(ReviewLoopBridge.reviewFileURL("File.swift:12", projectPath: project.path), file)
        XCTAssertEqual(ReviewLoopBridge.reviewFileURL(file.absoluteString, projectPath: project.path), file)
        XCTAssertNil(ReviewLoopBridge.reviewFileURL("../outside.swift", projectPath: project.path))
        XCTAssertNil(ReviewLoopBridge.reviewFileURL(outside.path, projectPath: project.path))
        XCTAssertNil(ReviewLoopBridge.reviewFileURL("alias.swift", projectPath: project.path))
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
        XCTAssertEqual(coordinator.loops.map(\.phase), [.running, .stopped])
        let recovered = ReviewLoopCoordinator(store: store)
        XCTAssertEqual(recovered.loops.map(\.phase), [.paused, .stopped])
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

    func testOneFalsePositiveAndOneFixContinueToNextReview() async throws {
        let (coordinator, _, driver) = try make()
        await coordinator.advance(using: driver, threads: [])
        driver.review(priorities: [.p2, .p2])
        await coordinator.advance(using: driver, threads: [])
        await coordinator.advance(using: driver, threads: [])
        driver.finish(findings: 1, commit: "fixed", withdrawn: [2])
        await coordinator.advance(using: driver, threads: [])
        XCTAssertEqual(coordinator.loops.last?.phase, .waiting)
        XCTAssertEqual(coordinator.loops.last?.rounds.last?.result?.findingCount, 1)
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
        XCTAssertEqual(coordinator.progress[coordinator.loops.last!.id.uuidString]?.upcoming?.text, "Fix both findings and commit. Verify each finding first. Mark invalid findings as withdrawn; if all are invalid, make no commit.")
        await coordinator.advance(using: driver, threads: [])
        XCTAssertEqual(coordinator.progress[coordinator.loops.last!.id.uuidString]?.current?.text, driver.prompts.last)
        XCTAssertEqual(coordinator.progress[coordinator.loops.last!.id.uuidString]?.upcoming?.text, "Review project for bugs and issues.")
        try coordinator.apply(action(.pause, for: coordinator), projects: [project])
        XCTAssertTrue(coordinator.progress[coordinator.loops.last!.id.uuidString]?.upcoming?.note.contains("resume") == true)
        driver.finish(findings: 2, commit: "fixed")
        await coordinator.advance(using: driver, threads: [])
        XCTAssertEqual(coordinator.progress[coordinator.loops.last!.id.uuidString]?.step, "Paused")
        XCTAssertEqual(coordinator.progress[coordinator.loops.last!.id.uuidString]?.upcoming?.text, "Review project for bugs and issues.")
        try coordinator.apply(action(.stop, for: coordinator), projects: [project])
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

    func testInterruptFailureKeepsLoopStoppedAndCanBeRetried() async throws {
        let (coordinator, store, driver) = try make()
        await coordinator.advance(using: driver, threads: [])
        driver.failStopThread = true
        try coordinator.apply(action(.stop, for: coordinator), projects: [project])
        do {
            try await coordinator.stopRunningTask(for: coordinator.loops.last!.id, using: driver)
            XCTFail("Expected interrupt failure")
        } catch { }
        XCTAssertEqual(store.loops.last?.phase, .stopped)
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

    func testPriorityLimitRejectsLowerPriorityAndNeverSendsAddressAllForMixedReport() async throws {
        for priorities: [ReviewFinding.Priority] in [[.p2], [.p1, .p2]] {
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
            XCTAssertEqual(coordinator.loops.last?.phase, priorities.count == 1 ? .completed : .blocked)
            XCTAssertEqual(driver.prompts.count, 1)
        }
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

    func testPerformanceReviewIncludesOptionalProjectContext() {
        var loop = ReviewLoop(id: UUID(), startActionID: "performance", project: project,
                              promptContext: .personal, maxRounds: 3)
        loop.focus = .performance
        XCTAssertEqual(ReviewPrompts.reviewPrompt(for: loop),
                       "Review project for performance and responsiveness (this is a project for personal use).")
    }

    func testReviewsWithoutProjectContextIgnoreSavedContext() throws {
        for focus in [ReviewFocus.organisation, .naming, .content] {
            let store = ReviewTestStore()
            let coordinator = ReviewLoopCoordinator(store: store)
            var action = startAction(id: focus.rawValue, kind: .start, projectID: project.id,
                                     promptContext: .personal, maxRounds: 3, loopID: nil)
            action.focus = focus
            try coordinator.apply(action, projects: [project])
            XCTAssertEqual(store.loops.first?.promptContext, .general)
            XCTAssertFalse(ReviewPrompts.reviewPrompt(for: store.loops[0]).contains("personal use"))

            let savedLoop = ReviewLoop(id: store.loops[0].id, startActionID: action.id,
                                       project: project, promptContext: .personal,
                                       maxRounds: 3, focus: focus)
            XCTAssertFalse(ReviewPrompts.reviewPrompt(for: savedLoop).contains("personal use"))
        }
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
            case .organisation:
                expectedReview = "Do a code and content minimisation and organisation review. Remove duplication and unnecessary complexity while preserving clarity and useful information."
                expectedFix = "Address the finding and commit"
            case .naming:
                expectedReview = "Do a code and content minimisation and organisation review, and suggest improvements where naming (e.g. folders, files, classes, variables, functions, UI, etc.) is undescriptive, too long, overly abbreviated, or misleading. Remove duplication and unnecessary complexity while preserving clarity and useful information."
                expectedFix = "Address the finding and commit"
            case .content:
                expectedReview = "Review project for content accuracy, clarity, wording, consistency, completeness, presentation, and effectiveness for its intended purpose."
                expectedFix = "Address the finding and commit"
            case .performance:
                expectedReview = "Review project for performance and responsiveness."
                expectedFix = "Address the finding to improve performance and responsiveness. Keep changes proportionate and verify the improvements, then commit"
            }
            let driver = ReviewTestDriver()
            await coordinator.advance(using: driver, threads: [])
            if focus.usesPriorities { driver.review(priorities: [.p1]) }
            else { driver.reviewWithoutPriorities() }
            await coordinator.advance(using: driver, threads: [])
            await coordinator.advance(using: driver, threads: [])
            let fullFixPrompt = expectedFix + ". Verify each finding first. Mark invalid findings as withdrawn; if all are invalid, make no commit."
            XCTAssertEqual(driver.prompts, [expectedReview, fullFixPrompt])
            driver.finish(findings: 1, commit: "fixed")
            await coordinator.advance(using: driver, threads: [])
            await coordinator.advance(using: driver, threads: [])
            XCTAssertEqual(driver.prompts, [expectedReview, fullFixPrompt, expectedReview])
        }
    }

    func testFileStoreRoundTripsAndDoesNotOverwriteCorruptData() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("loop.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = ReviewLoopFileStore(url: url)
        let (coordinator, _, _) = try make()
        try store.save(coordinator.loops)
        XCTAssertEqual(try store.load(), coordinator.loops)
        let currentDocument = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual(currentDocument["version"] as? Int, 1)
        XCTAssertNotNil(currentDocument["loops"] as? [[String: Any]])
        var olderLoop = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(try XCTUnwrap(coordinator.loops.last))) as? [String: Any])
        olderLoop.removeValue(forKey: "speed")
        olderLoop.removeValue(forKey: "focus")
        olderLoop.removeValue(forKey: "promptContext")
        olderLoop["instructions"] = "(this is a project for personal use)"
        try JSONSerialization.data(withJSONObject: olderLoop).write(to: url)
        XCTAssertEqual(try store.load().first?.speed, .standard)
        XCTAssertEqual(try store.load().first?.focus, .bugs)
        XCTAssertEqual(try store.load().first?.promptContext, .personal)
        olderLoop["instructions"] = "(saved custom context)"
        try JSONSerialization.data(withJSONObject: olderLoop).write(to: url)
        XCTAssertEqual(try store.load().first?.promptContext, .savedContext("(saved custom context)"))
        try JSONSerialization.data(withJSONObject: [olderLoop]).write(to: url)
        XCTAssertEqual(try store.load().first?.promptContext, .savedContext("(saved custom context)"))
        var futureDocument = currentDocument
        futureDocument["version"] = 2
        try JSONSerialization.data(withJSONObject: futureDocument).write(to: url)
        XCTAssertThrowsError(try store.load())
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
    var failStopThread = false
    var interruptedTurns: [String] = []
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
    func startTurn(threadID: String, projectPath: String, expectedRepository: ReviewRepositoryState,
                   prompt: String, kind: ReviewTurnKind, selection: ReviewModelSelection?, speed: ReviewSpeed) async throws -> String {
        prompts.append(prompt)
        selections.append(selection)
        speeds.append(speed)
        let id = "turn-\(prompts.count)"
        thread = ReviewThreadState(cwd: "/tmp/example", turns: thread.turns + [ReviewTurnState(id: id, status: "inProgress", finalMessage: nil)])
        onStartTurn?()
        return id
    }
    func stopThread(_ threadID: String) async throws {
        if failStopThread { throw ReviewLoopError("Connection timed out") }
        guard let last = thread.turns.last, last.status == "inProgress" else { return }
        interruptedTurns.append(last.id)
        thread = ReviewThreadState(cwd: thread.cwd, turns: thread.turns.dropLast() + [
            ReviewTurnState(id: last.id, status: "interrupted", finalMessage: nil)
        ])
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
    func finish(findings: Int, commit: String, withdrawn: [Int] = []) {
        if commit != "none" { self.commit = commit }
        let withdrawnList = withdrawn.isEmpty ? "none" : withdrawn.map(String.init).joined(separator: ", ")
        finishTurn("\(commit == "none" ? "# Findings withdrawn" : "# Fixes committed")\nFindings addressed: \(findings)\nFindings withdrawn: \(withdrawnList)\nCommit: `\(commit)`\n\n## Summary\nChanges committed")
    }
    func userFollowup() {
        thread = ReviewThreadState(cwd: thread.cwd, turns: thread.turns + [
            ReviewTurnState(id: "followup-\(thread.turns.count + 1)", status: "inProgress", finalMessage: nil)
        ])
    }
    func blockFix() {
        finishTurn("# Fixes blocked\nFindings addressed: 0\nFindings withdrawn: none\nCommit: `none`\n\n## Summary\nMissing evidence")
    }
    private func finishTurn(_ report: String) {
        let last = thread.turns.last!
        thread = ReviewThreadState(cwd: thread.cwd, turns: thread.turns.dropLast() + [
            ReviewTurnState(id: last.id, status: "completed", finalMessage: report)
        ])
    }
}
