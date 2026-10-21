import XCTest
@testable import CodexDashboard

@MainActor
final class ReviewFolderLoopTests: ReviewLoopTestCase {
    private func folderLoop(limit: Int = 2) throws -> (ReviewLoopCoordinator, ReviewTestStore, ReviewTestDriver) {
        let (coordinator, store, driver) = try make(limit: limit)
        driver.workspaceKind = .folder
        driver.branch = ""
        return (coordinator, store, driver)
    }

    private func startFix(_ coordinator: ReviewLoopCoordinator, _ driver: ReviewTestDriver) async {
        await coordinator.advance(using: driver, threads: [])
        driver.review(priorities: [.p1])
        await coordinator.advance(using: driver, threads: [])
        await coordinator.advance(using: driver, threads: [])
    }

    private func finishFolderFix(_ driver: ReviewTestDriver) {
        driver.commit = "changed-files"
        driver.finishTurn("# Fixes applied\nFindings addressed: 1\nFindings withdrawn: none\n\n## Summary\nFixed the issue and checked the files.")
    }

    func testFolderFixCompletesWithoutExtraVerificationAndStartsNextRoundWithoutGit() async throws {
        let (coordinator, _, driver) = try folderLoop()
        await startFix(coordinator, driver)
        XCTAssertEqual(coordinator.loops[0].workspaceKind, .folder)
        XCTAssertTrue(driver.prompts[1].contains("Do not initialise Git"))
        finishFolderFix(driver)
        await coordinator.advance(using: driver, threads: [])
        XCTAssertEqual(driver.prompts.count, 2)
        XCTAssertNil(coordinator.loops[0].rounds[0].fixVerification)
        XCTAssertEqual(coordinator.loops[0].phase, .waiting)
        XCTAssertNil(coordinator.loops[0].rounds[0].result?.fixCommit)
        XCTAssertEqual(coordinator.loops[0].rounds[0].result?.verifiedRevision, "changed-files")
        XCTAssertTrue(driver.pushedCommits.isEmpty)
        await coordinator.advance(using: driver, threads: [])
        XCTAssertEqual(driver.createdThreads.count, 2)
        XCTAssertEqual(coordinator.loops[0].rounds[1].baseRevision, "changed-files")
    }

    func testReadOnlyFolderReviewRejectsFileChanges() async throws {
        let (coordinator, _, driver) = try folderLoop()
        await coordinator.advance(using: driver, threads: [])
        driver.commit = "external-edit"
        driver.review(priorities: [])
        await coordinator.advance(using: driver, threads: [])
        XCTAssertEqual(coordinator.loops[0].phase, .blocked)
        XCTAssertEqual(driver.prompts.count, 1)
    }

    func testFolderFixRequiresActualChangesAndRejectsCommitReports() async throws {
        let (coordinator, _, driver) = try folderLoop()
        await startFix(coordinator, driver)
        driver.finishTurn("# Fixes applied\nFindings addressed: 1\nFindings withdrawn: none\n\n## Summary\nClaimed a fix.")
        await coordinator.advance(using: driver, threads: [])
        XCTAssertEqual(coordinator.loops[0].phase, .blocked)
        XCTAssertTrue(coordinator.loops[0].message.contains("unchanged"))
        XCTAssertThrowsError(try ReviewReportContract.fix("# Fixes committed\nFindings addressed: 1\nFindings withdrawn: none\nCommit: `abc`\n\n## Summary\nDone", workspaceKind: .folder))
    }

    func testFolderFixHonoursRoundLimitWithoutExtraVerification() async throws {
        let (coordinator, _, driver) = try folderLoop(limit: 1)
        await startFix(coordinator, driver)
        finishFolderFix(driver)
        await coordinator.advance(using: driver, threads: [])
        XCTAssertEqual(coordinator.loops[0].phase, .limitReached)
        XCTAssertEqual(coordinator.loops[0].completedRoundCount, 1)
        XCTAssertNil(coordinator.loops[0].rounds[0].fixVerification)
        XCTAssertEqual(driver.prompts.count, 2)
        await coordinator.advance(using: driver, threads: [])
        XCTAssertEqual(driver.prompts.count, 2)
    }

    func testFolderFixSurvivesRestartAndHonoursRoundLimit() async throws {
        let (coordinator, store, driver) = try folderLoop(limit: 1)
        await startFix(coordinator, driver)
        finishFolderFix(driver)
        let restored = ReviewLoopCoordinator(store: store)
        XCTAssertEqual(restored.loops[0].phase, .paused)
        try restored.apply(action(.resume, for: restored), projects: [project])
        await restored.advance(using: driver, threads: [])
        XCTAssertEqual(restored.loops[0].phase, .limitReached)
        XCTAssertEqual(restored.loops[0].completedRoundCount, 1)
        XCTAssertEqual(driver.prompts.count, 2)
        XCTAssertNil(restored.loops[0].rounds[0].fixVerification)
    }

    func testPreviouslyPausedNonGitProjectCanResume() async throws {
        let (coordinator, store, driver) = try make()
        driver.failWorkspace = true
        await coordinator.advance(using: driver, threads: [])
        XCTAssertEqual(coordinator.loops[0].phase, .paused)
        driver.failWorkspace = false
        driver.workspaceKind = .folder
        driver.branch = ""
        let restored = ReviewLoopCoordinator(store: store)
        try restored.apply(action(.resume, for: restored), projects: [project])
        await restored.advance(using: driver, threads: [])
        driver.review(priorities: [])
        await restored.advance(using: driver, threads: [])
        XCTAssertEqual(restored.loops[0].phase, .completed)
        XCTAssertNil(restored.loops[0].rounds[0].result?.fixCommit)
    }

    func testNestedFolderCannotStartWhileParentLoopIsReserved() async throws {
        let (coordinator, _, driver) = try folderLoop()
        await coordinator.advance(using: driver, threads: [])
        let nested = ReviewProject(id: "nested", name: "Nested", path: project.path + "/nested")
        try coordinator.apply(startAction(id: "nested", kind: .start, projectID: nested.id,
            promptContext: .general, maxRounds: 2, loopID: nil), projects: [nested])
        await coordinator.advance(using: driver, threads: [])
        XCTAssertEqual(coordinator.loops.last?.phase, .blocked)
        XCTAssertEqual(driver.createdThreads.count, 1)
    }

    func testWithdrawnFolderFindingsRequireUnchangedFiles() async throws {
        let (coordinator, _, driver) = try folderLoop()
        await startFix(coordinator, driver)
        driver.finishTurn("# Findings withdrawn\nFindings addressed: 0\nFindings withdrawn: 1\n\n## Summary\nEvidence shows the finding is invalid.")
        await coordinator.advance(using: driver, threads: [])
        XCTAssertEqual(coordinator.loops[0].phase, .completed)
        XCTAssertEqual(coordinator.loops[0].rounds[0].result?.outcome, .withdrawn)
        XCTAssertEqual(driver.prompts.count, 2)
    }

    func testFolderPushIsBlockedBeforeChatCreation() async throws {
        let store = ReviewTestStore()
        let coordinator = ReviewLoopCoordinator(store: store)
        var start = startAction(id: "push", kind: .start, projectID: project.id, promptContext: .general, maxRounds: 1, loopID: nil)
        start.pushToRemote = true
        try coordinator.apply(start, projects: [project])
        let driver = ReviewTestDriver()
        driver.workspaceKind = .folder
        driver.branch = ""
        await coordinator.advance(using: driver, threads: [])
        XCTAssertEqual(coordinator.loops[0].phase, .blocked)
        XCTAssertTrue(coordinator.loops[0].message.contains("Remote push requires Git"))
        XCTAssertTrue(driver.createdThreads.isEmpty)
    }
}
