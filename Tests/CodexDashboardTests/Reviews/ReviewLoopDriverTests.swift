import XCTest
@testable import CodexDashboard

@MainActor
final class ReviewLoopDriverTests: XCTestCase {
    func testReadsTwoTurnsWithOptionalMessagePhaseAndRejectsExtraTurns() throws {
        let turn: [String: Any] = ["id": "review", "status": "completed", "items": [
            ["type": "agentMessage", "phase": "commentary", "text": "Working"],
            ["type": "agentMessage", "text": "{\"findings\":[]}"],
        ]]
        let state = try ReviewLoopDriver.threadState(["thread": ["cwd": "/tmp/project", "turns": [turn, turn]]])
        XCTAssertEqual(state.turns.count, 2)
        XCTAssertEqual(state.turns.first?.finalMessage, "{\"findings\":[]}")
        XCTAssertThrowsError(try ReviewLoopDriver.threadState(["thread": ["cwd": "/tmp/project", "turns": [turn, turn, turn]]]))
    }

    func testApprovalAndStaleInProgressTurnNeedAttention() throws {
        let turn: [String: Any] = ["id": "review", "status": "inProgress", "items": []]
        for status: [String: Any] in [
            ["type": "notLoaded"], ["type": "idle"],
            ["type": "active", "activeFlags": ["waitingOnApproval"]],
            ["type": "active", "activeFlags": ["waitingOnUserInput"]],
        ] {
            XCTAssertThrowsError(try ReviewLoopDriver.threadState(["thread": ["cwd": "/tmp/project", "status": status, "turns": [turn]]]))
        }
        let running = try ReviewLoopDriver.threadState(["thread": ["cwd": "/tmp/project", "status": ["type": "active", "activeFlags": []], "turns": [turn]]])
        XCTAssertEqual(running.turns.first?.status, "inProgress")
    }

    func testRealGitCheckpointIncludesUntrackedFilesAndCommitAncestry() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("review-git-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        func git(_ arguments: [String]) async throws {
            let result = try await Subprocess.run(executableURL: URL(fileURLWithPath: "/usr/bin/git"), arguments: ["-C", directory.path] + arguments, timeout: 5)
            XCTAssertEqual(result.terminationStatus, 0)
        }
        try await git(["init", "-b", "main"])
        try await git(["-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "--allow-empty", "-m", "Initial"])
        let driver = ReviewLoopDriver(devTools: DevToolsClient(), target: DevToolsTarget(id: "unused", type: "page", url: nil, webSocketURL: nil))
        let initial = try await driver.repository(at: directory.path)
        XCTAssertTrue(initial.clean)
        XCTAssertEqual(initial.branch, "main")
        try Data("change".utf8).write(to: directory.appendingPathComponent("fix.txt"))
        let dirty = try await driver.repository(at: directory.path)
        XCTAssertFalse(dirty.clean)
        try await git(["add", "fix.txt"])
        try await git(["-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "-m", "Fix"])
        let fixed = try await driver.repository(at: directory.path)
        XCTAssertTrue(fixed.clean)
        XCTAssertNotEqual(fixed.commit, initial.commit)
        let isAncestor = try await driver.isAncestor(initial.commit, of: fixed.commit, at: directory.path)
        XCTAssertTrue(isAncestor)
    }

    func testFixPromptDoesNotAskForTestingAndSchemaHasNoTestGate() throws {
        let loop = ReviewLoop(id: UUID(), startActionID: "test", project: ReviewProject(id: "p", name: "Project", path: "/tmp/project"), instructions: "", maxRounds: 5)
        let prompt = ReviewLoopCoordinator.fixPrompt(for: loop, round: ReviewRound(number: 1, baseCommit: "abc"))
        XCTAssertFalse(prompt.lowercased().contains("test"))
        XCTAssertFalse(prompt.lowercased().contains("checks"))
        XCTAssertEqual(prompt, "Address all and commit")
        let properties = try XCTUnwrap(ReviewLoopDriver.fixSchema["properties"] as? [String: Any])
        XCTAssertNil(properties["checksPassed"])
    }
}
