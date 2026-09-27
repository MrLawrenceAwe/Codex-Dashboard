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
        ReviewLoopAction(id: UUID().uuidString, kind: kind, projectID: nil, instructions: nil, maxRounds: nil, loopID: coordinator.loop?.id)
    }

    private func stop(_ coordinator: ReviewLoopCoordinator) {
        do { try coordinator.apply(action("stop", for: coordinator), projects: [project]) }
        catch { XCTFail("Could not stop review loop: \(error)") }
    }

    func testFixCommitThenFreshReviewThenCleanStops() async throws {
        let (coordinator, store, driver) = try make()
        await coordinator.advance(using: driver, threads: [])
        XCTAssertEqual(driver.createdThreads, ["thread-1"])
        XCTAssertEqual(store.loop?.rounds.first?.reviewTurnID, "turn-1")
        driver.review(priorities: [.p1, .p2])
        await coordinator.advance(using: driver, threads: []) // read review
        XCTAssertEqual(driver.prompts.count, 1)
        await coordinator.advance(using: driver, threads: []) // send fix
        XCTAssertEqual(driver.createdThreads.count, 1)
        XCTAssertEqual(driver.prompts.count, 2)
        driver.finish(findings: 2, commit: "fixed")
        await coordinator.advance(using: driver, threads: [])
        XCTAssertEqual(coordinator.loop?.phase, .waiting)
        XCTAssertEqual(driver.createdThreads.count, 1, "Do not launch in the same checkpoint observation")
        await coordinator.advance(using: driver, threads: [])
        XCTAssertEqual(driver.createdThreads, ["thread-1", "thread-2"])
        XCTAssertEqual(driver.prompts[2], "Review project for bugs and issues.")
        XCTAssertFalse(driver.prompts[2].contains("last round's findings"))
        driver.review(priorities: [])
        await coordinator.advance(using: driver, threads: [])
        XCTAssertEqual(coordinator.loop?.phase, .completed)
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
        XCTAssertEqual(coordinator.loop?.phase, .waiting)
        XCTAssertEqual(coordinator.loop?.expectedCommit, fullCommit)
        XCTAssertEqual(coordinator.loop?.rounds.last?.result?.commit, fullCommit)
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
        XCTAssertEqual(coordinator.loop?.phase, .stopped)
        XCTAssertNil(coordinator.loop?.rounds.last?.result)
    }

    func testProgressTracksSubmittedAndConditionalPrompts() async throws {
        let (coordinator, _, driver) = try make()
        XCTAssertNil(coordinator.progress?.current)
        XCTAssertEqual(coordinator.progress?.upcoming?.text, "Review project for bugs and issues.")
        await coordinator.advance(using: driver, threads: [])
        XCTAssertEqual(coordinator.progress?.step, "Reviewing")
        XCTAssertEqual(coordinator.progress?.current?.text, driver.prompts.last)
        XCTAssertTrue(coordinator.progress?.upcoming?.note.contains("Only if") == true)
        driver.review(priorities: [.p1, .p2])
        await coordinator.advance(using: driver, threads: [])
        XCTAssertEqual(coordinator.progress?.step, "Preparing fixes")
        XCTAssertEqual(coordinator.progress?.upcoming?.text, "Address both and commit")
        await coordinator.advance(using: driver, threads: [])
        XCTAssertEqual(coordinator.progress?.current?.text, driver.prompts.last)
        XCTAssertEqual(coordinator.progress?.upcoming?.text, "Review project for bugs and issues.")
        try coordinator.apply(action("pause", for: coordinator), projects: [project])
        XCTAssertTrue(coordinator.progress?.upcoming?.note.contains("resume") == true)
        driver.finish(findings: 2, commit: "fixed")
        await coordinator.advance(using: driver, threads: [])
        XCTAssertEqual(coordinator.progress?.step, "Paused")
        XCTAssertEqual(coordinator.progress?.upcoming?.text, "Review project for bugs and issues.")
        try coordinator.apply(action("stop", for: coordinator), projects: [project])
        XCTAssertNil(coordinator.progress?.upcoming)
        XCTAssertEqual(coordinator.progress?.currentLabel, "Latest prompt")
    }

    func testProgressDoesNotQueuePastRoundLimitOrCleanReview() async throws {
        let (coordinator, _, driver) = try make(limit: 1)
        await coordinator.advance(using: driver, threads: [])
        driver.review(priorities: [.p1])
        await coordinator.advance(using: driver, threads: [])
        XCTAssertNotNil(coordinator.progress?.upcoming)
        await coordinator.advance(using: driver, threads: [])
        XCTAssertNil(coordinator.progress?.upcoming)
        let (clean, _, cleanDriver) = try make()
        await clean.advance(using: cleanDriver, threads: [])
        cleanDriver.review(priorities: [])
        await clean.advance(using: cleanDriver, threads: [])
        XCTAssertEqual(clean.progress?.step, "Complete")
        XCTAssertNil(clean.progress?.upcoming)
    }

    func testDirtyCheckoutDoesNotLaunchOrCommit() async throws {
        let (coordinator, _, driver) = try make()
        driver.clean = false
        await coordinator.advance(using: driver, threads: [])
        XCTAssertEqual(coordinator.loop?.phase, .blocked)
        XCTAssertTrue(driver.createdThreads.isEmpty)
    }

    func testWaitsForOtherRunningTaskIncludingProjectSubdirectory() async throws {
        let (coordinator, _, driver) = try make()
        let thread = ThreadSummary(id: "other", title: "Other", preview: "Other", projectName: "Example", projectPath: "/tmp/example/Sources", recencyEpochMillis: 1, isPinned: false, model: nil, runState: .running, latestLifecycleEvent: nil, workingTreeStatus: .clean)
        await coordinator.advance(using: driver, threads: [RendererThread(thread)])
        XCTAssertEqual(coordinator.loop?.phase, .waiting)
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
            XCTAssertEqual(coordinator.loop?.phase, .blocked, failure)
            await coordinator.advance(using: driver, threads: [])
            XCTAssertEqual(driver.createdThreads.count, 1, failure)
        }
    }

    func testReviewMustNotChangeCheckoutAndP3OnlyDoesNotTriggerFix() async throws {
        let (coordinator, _, driver) = try make()
        await coordinator.advance(using: driver, threads: [])
        driver.review(priorities: [.p3])
        await coordinator.advance(using: driver, threads: [])
        XCTAssertEqual(coordinator.loop?.phase, .completed)
        XCTAssertEqual(driver.prompts.count, 1, "Never send address-all for P3-only or empty reviews")

        let (changed, _, changedDriver) = try make()
        await changed.advance(using: changedDriver, threads: [])
        changedDriver.review(priorities: [])
        changedDriver.commit = "unexpected"
        await changed.advance(using: changedDriver, threads: [])
        XCTAssertEqual(changed.loop?.phase, .blocked)
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
            XCTAssertEqual(coordinator.loop?.phase, .blocked, failure)
        }
    }

    func testRestartPausesAndReconcilesKnownRoundWithoutResending() async throws {
        let (first, store, driver) = try make()
        await first.advance(using: driver, threads: [])
        let recovered = ReviewLoopCoordinator(store: store)
        XCTAssertEqual(recovered.loop?.phase, .paused)
        await recovered.advance(using: driver, threads: [])
        XCTAssertEqual(driver.prompts.count, 1)
        try recovered.apply(action("resume", for: recovered), projects: [project])
        await recovered.advance(using: driver, threads: [])
        XCTAssertEqual(recovered.loop?.phase, .running)
        XCTAssertEqual(driver.prompts.count, 1)
        driver.review(priorities: [])
        await recovered.advance(using: driver, threads: [])
        XCTAssertEqual(recovered.loop?.phase, .completed)
    }

    func testUnknownLaunchIsNeverRetried() async throws {
        let (coordinator, store, driver) = try make()
        driver.failCreate = true
        await coordinator.advance(using: driver, threads: [])
        XCTAssertEqual(coordinator.loop?.phase, .blocked)
        store.loop?.phase = .running // Simulate process loss before the failure was saved.
        let recovered = ReviewLoopCoordinator(store: store)
        try recovered.apply(action("resume", for: recovered), projects: [project])
        await recovered.advance(using: driver, threads: [])
        XCTAssertEqual(recovered.loop?.phase, .blocked)
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
        XCTAssertEqual(coordinator.loop?.phase, .running)
        driver.review(priorities: [.p2])
        await coordinator.advance(using: driver, threads: [])
        await coordinator.advance(using: driver, threads: [])
        driver.finish(findings: 1, commit: "fixed")
        await coordinator.advance(using: driver, threads: [])
        XCTAssertEqual(coordinator.loop?.phase, .paused)
        try coordinator.apply(action("stop", for: coordinator), projects: [project])
        await coordinator.advance(using: driver, threads: [])
        XCTAssertEqual(coordinator.loop?.phase, .stopped)
        XCTAssertEqual(driver.createdThreads.count, 1)
    }

    func testStopDuringRepositoryCheckPreventsReviewLaunch() async throws {
        let (coordinator, _, driver) = try make()
        driver.onRepository = { self.stop(coordinator) }
        await coordinator.advance(using: driver, threads: [])
        XCTAssertEqual(coordinator.loop?.phase, .stopped)
        XCTAssertTrue(driver.createdThreads.isEmpty)
    }

    func testStopDuringThreadCreationRecordsThreadWithoutSendingPrompt() async throws {
        let (coordinator, store, driver) = try make()
        driver.onCreateThread = { self.stop(coordinator) }
        await coordinator.advance(using: driver, threads: [])
        XCTAssertEqual(coordinator.loop?.phase, .stopped)
        XCTAssertEqual(store.loop?.rounds.last?.threadID, "thread-1")
        XCTAssertTrue(driver.prompts.isEmpty)
    }

    func testStopDuringPromptSubmissionRecordsTurnWithoutResumingLoop() async throws {
        let (coordinator, store, driver) = try make()
        driver.onStartTurn = { self.stop(coordinator) }
        await coordinator.advance(using: driver, threads: [])
        XCTAssertEqual(coordinator.loop?.phase, .stopped)
        XCTAssertEqual(store.loop?.rounds.last?.reviewTurnID, "turn-1")
        await coordinator.advance(using: driver, threads: [])
        XCTAssertEqual(driver.prompts.count, 1)
    }

    func testStopDuringReviewReadDoesNotSubmitFix() async throws {
        let (coordinator, _, driver) = try make()
        await coordinator.advance(using: driver, threads: [])
        driver.review(priorities: [.p1])
        driver.onReadThread = { self.stop(coordinator) }
        await coordinator.advance(using: driver, threads: [])
        XCTAssertEqual(coordinator.loop?.phase, .stopped)
        XCTAssertEqual(driver.prompts.count, 1)
    }

    func testStopDuringFixSubmissionKeepsStoppedPhaseAndTurnID() async throws {
        let (coordinator, store, driver) = try make()
        await coordinator.advance(using: driver, threads: [])
        driver.review(priorities: [.p1])
        await coordinator.advance(using: driver, threads: [])
        driver.onStartTurn = { self.stop(coordinator) }
        await coordinator.advance(using: driver, threads: [])
        XCTAssertEqual(coordinator.loop?.phase, .stopped)
        XCTAssertEqual(store.loop?.rounds.last?.fixTurnID, "turn-2")
    }

    func testRoundLimitDoesNotReportCleanOrLaunchAnotherTask() async throws {
        let (coordinator, _, driver) = try make(limit: 1)
        await coordinator.advance(using: driver, threads: [])
        driver.review(priorities: [.p2])
        await coordinator.advance(using: driver, threads: [])
        await coordinator.advance(using: driver, threads: [])
        driver.finish(findings: 1, commit: "fixed")
        await coordinator.advance(using: driver, threads: [])
        XCTAssertEqual(coordinator.loop?.phase, .paused)
        try coordinator.apply(action("resume", for: coordinator), projects: [project])
        await coordinator.advance(using: driver, threads: [])
        XCTAssertEqual(coordinator.loop?.phase, .paused)
        XCTAssertEqual(driver.createdThreads.count, 1)
    }

    func testReplayedStartActionDoesNotCreateSecondLoopAfterCompletion() async throws {
        let (coordinator, _, driver) = try make()
        await coordinator.advance(using: driver, threads: [])
        driver.review(priorities: [])
        await coordinator.advance(using: driver, threads: [])
        let id = coordinator.loop?.id
        try coordinator.apply(ReviewLoopAction(id: "start", kind: "start", projectID: project.id, instructions: nil, maxRounds: 5, loopID: nil), projects: [project])
        XCTAssertEqual(coordinator.loop?.id, id)
        XCTAssertEqual(coordinator.loop?.phase, .completed)
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
                    XCTAssertEqual(coordinator.loop?.phase, .completed)
                    XCTAssertEqual(driver.prompts.count, 1)
                } else {
                    XCTAssertEqual(driver.prompts.last, count == 1 ? "Address and commit" : count == 2 ? "Address both and commit" : "Address all and commit")
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
            XCTAssertEqual(coordinator.loop?.phase, priorities.count == 1 ? .completed : .blocked)
            XCTAssertEqual(driver.prompts.count, 1)
        }
    }

    func testModelSelectionPersistsAndAppliesToReviewAndFix() async throws {
        let store = ReviewTestStore()
        let coordinator = ReviewLoopCoordinator(store: store)
        var start = ReviewLoopAction(id: "selected", kind: "start", projectID: project.id, instructions: nil, maxRounds: 3, loopID: nil)
        start.selection = ReviewModelSelection(model: "selected-model", effort: "high")
        try coordinator.apply(start, projects: [project])
        let driver = ReviewTestDriver()
        await coordinator.advance(using: driver, threads: [])
        driver.review(priorities: [.p1])
        await coordinator.advance(using: driver, threads: [])
        await coordinator.advance(using: driver, threads: [])
        XCTAssertEqual(driver.selections, [start.selection, start.selection])
        XCTAssertEqual(store.loop?.selection, start.selection)
        driver.finish(findings: 1, commit: "fixed")
        await coordinator.advance(using: driver, threads: [])
        await coordinator.advance(using: driver, threads: [])
        XCTAssertEqual(driver.selections, [start.selection, start.selection, start.selection])
    }

    func testFileStoreRoundTripsAndDoesNotOverwriteCorruptData() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("loop.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = ReviewLoopFileStore(url: url)
        let (coordinator, _, _) = try make()
        try store.save(try XCTUnwrap(coordinator.loop))
        XCTAssertEqual(try store.load(), coordinator.loop)
        try Data("broken".utf8).write(to: url)
        let recovered = ReviewLoopCoordinator(store: store)
        XCTAssertNotNil(recovered.error)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "broken")
    }
}

@MainActor
private final class ReviewTestStore: ReviewLoopStoring {
    var loop: ReviewLoop?
    var failSave = false
    func load() throws -> ReviewLoop? { loop }
    func save(_ loop: ReviewLoop) throws {
        if failSave { throw ReviewLoopError("disk full") }
        self.loop = loop
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
    var createCalls = 0
    var createdThreads: [String] = []
    var prompts: [String] = []
    var selections: [ReviewModelSelection?] = []
    var thread = ReviewThreadState(cwd: "/tmp/example", turns: [])
    var onRepository: (() -> Void)?
    var onCreateThread: (() -> Void)?
    var onStartTurn: (() -> Void)?
    var onReadThread: (() -> Void)?
    func projects() async throws -> [ReviewProject] { [] }
    func repository(at path: String) async throws -> ReviewRepositoryState {
        onRepository?()
        return ReviewRepositoryState(root: "/tmp/example", branch: branch, commit: commit, clean: clean)
    }
    func isAncestor(_ commit: String, of head: String, at path: String) async throws -> Bool { ancestor }
    func resolveCommit(_ commit: String, at path: String) async throws -> String {
        onResolveCommit?()
        return resolvedCommit ?? commit
    }
    func createThread(project: ReviewProject, title: String) async throws -> String {
        createCalls += 1
        if failCreate { throw ReviewLoopError("Lost response") }
        let id = "thread-\(createdThreads.count + 1)"
        createdThreads.append(id)
        thread = ReviewThreadState(cwd: "/tmp/example", turns: [])
        onCreateThread?()
        return id
    }
    func startTurn(threadID: String, prompt: String, kind: ReviewTurnKind, selection: ReviewModelSelection?) async throws -> String {
        prompts.append(prompt)
        selections.append(selection)
        let id = "turn-\(prompts.count)"
        thread = ReviewThreadState(cwd: "/tmp/example", turns: thread.turns + [ReviewTurnState(id: id, status: "inProgress", finalMessage: nil)])
        onStartTurn?()
        return id
    }
    func readThread(_ threadID: String) async throws -> ReviewThreadState {
        onReadThread?()
        return thread
    }
    func review(priorities: [ReviewFinding.Priority]) {
        let report = ReviewReport(outcome: .reviewed, findings: priorities.map {
            ReviewFinding(priority: $0, title: "Example issue", body: "Evidence and impact")
        }, summary: "Review finished")
        finishTurn(report)
    }
    func finish(findings: Int, commit: String) {
        self.commit = commit
        finishTurn(ReviewRoundResult(outcome: .fixed, findings: findings, commit: commit, summary: "Changes committed"))
    }
    private func finishTurn(_ report: some Encodable) {
        let last = thread.turns.last!
        thread = ReviewThreadState(cwd: thread.cwd, turns: thread.turns.dropLast() + [
            ReviewTurnState(id: last.id, status: "completed", finalMessage: String(decoding: try! JSONEncoder().encode(report), as: UTF8.self))
        ])
    }
}
