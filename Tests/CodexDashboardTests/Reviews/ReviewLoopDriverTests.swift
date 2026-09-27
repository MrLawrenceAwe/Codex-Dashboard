import XCTest
@testable import CodexDashboard

@MainActor
final class ReviewLoopDriverTests: XCTestCase {
    func testNewReviewThreadUsesStandardSpeed() async throws {
        let connection = ReviewReportDevTools()
        let driver = ReviewLoopDriver(devTools: connection, target: DevToolsTarget(id: "test", type: "page", url: nil, webSocketURL: nil))
        let id = try await driver.createThread(project: ReviewProject(id: "project", name: "Project", path: "/tmp/project"), title: "Review", speed: .standard)
        XCTAssertEqual(id, "thread")
        let expression = await connection.expressions.first!
        let prefix = "window.__codexDashboard.reviewRequest("
        let request = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(expression.dropFirst(prefix.count).dropLast().utf8)) as? [String: Any])
        let params = try XCTUnwrap(request["params"] as? [String: Any])
        XCTAssertEqual(request["method"] as? String, "thread/start")
        XCTAssertEqual(params["serviceTier"] as? String, "default")
        _ = try await driver.createThread(project: ReviewProject(id: "project", name: "Project", path: "/tmp/project"), title: "Fast review", speed: .fast)
        let fastExpression = await connection.expressions.dropLast().last!
        let fastRequest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(fastExpression.dropFirst(prefix.count).dropLast().utf8)) as? [String: Any])
        XCTAssertEqual((fastRequest["params"] as? [String: Any])?["serviceTier"] as? String, "priority")
    }

    func testTurnsRequestMarkdownWithoutForcingJSON() async throws {
        let connection = ReviewReportDevTools()
        let driver = ReviewLoopDriver(devTools: connection, target: DevToolsTarget(id: "test", type: "page", url: nil, webSocketURL: nil))
        let cases: [(ReviewTurnKind, ReviewSpeed)] = [(.review(.p1), .standard), (.fix, .fast)]
        for (kind, speed) in cases {
            let id = try await driver.startTurn(threadID: "thread", prompt: "Do the work", kind: kind,
                                                selection: ReviewModelSelection(model: "chosen", effort: "high"), speed: speed)
            XCTAssertEqual(id, "turn")
            let expression = await connection.expression
            let prefix = "window.__codexDashboard.reviewRequest("
            let data = Data(expression.dropFirst(prefix.count).dropLast().utf8)
            let request = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let params = try XCTUnwrap(request["params"] as? [String: Any])
            XCTAssertNil(params["outputSchema"])
            XCTAssertEqual(params["model"] as? String, "chosen")
            XCTAssertEqual(params["effort"] as? String, "high")
            XCTAssertEqual(params["serviceTierForTurn"] as? String, speed.serviceTier)
            let input = try XCTUnwrap(params["input"] as? [[String: Any]])
            let text = try XCTUnwrap(input.first?["text"] as? String)
            XCTAssertTrue(text.hasPrefix("Do the work\n\n"))
            XCTAssertTrue(text.contains(ReviewLoopReport.instructions(for: kind)))
        }
    }

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
        for reported in [fixed.commit, String(fixed.commit.prefix(7)), String(fixed.commit.prefix(7)).uppercased()] {
            let resolved = try await driver.resolveCommit(reported, at: directory.path)
            XCTAssertEqual(resolved, fixed.commit)
        }
        for invalid in ["", "HEAD", "main", "--help", "abc", "deadbeef", fixed.commit + "~1"] {
            do {
                _ = try await driver.resolveCommit(invalid, at: directory.path)
                XCTFail("Accepted invalid commit ID: \(invalid)")
            } catch { }
        }
    }

    func testFixPromptDoesNotAskForTesting() throws {
        let loop = ReviewLoop(id: UUID(), startActionID: "test", project: ReviewProject(id: "p", name: "Project", path: "/tmp/project"), instructions: "", maxRounds: 5)
        let prompt = ReviewLoopCoordinator.fixPrompt(for: loop, round: ReviewRound(number: 1, baseCommit: "abc"))
        XCTAssertFalse(prompt.lowercased().contains("test"))
        XCTAssertFalse(prompt.lowercased().contains("checks"))
        XCTAssertEqual(prompt, "Address all and commit")
        XCTAssertFalse(ReviewLoopReport.instructions(for: .fix).lowercased().contains("test"))
    }
}

private actor ReviewReportDevTools: DevToolsServing {
    var expressions: [String] = []
    var expression: String { expressions.last ?? "" }
    func mainRendererTargets() async -> [DevToolsTarget] { [] }
    func evaluateBoolean(_ expression: String, in target: DevToolsTarget) async throws -> Bool { false }
    func evaluateString(_ expression: String, in target: DevToolsTarget, timeout: Duration) async throws -> String? {
        expressions.append(expression)
        let prefix = "window.__codexDashboard.reviewRequest("
        let request = try JSONSerialization.jsonObject(with: Data(expression.dropFirst(prefix.count).dropLast().utf8)) as? [String: Any]
        if request?["method"] as? String == "thread/start" {
            return "{\"result\":{\"thread\":{\"id\":\"thread\"}}}"
        }
        return "{\"result\":{\"turn\":{\"id\":\"turn\"}}}"
    }
}
