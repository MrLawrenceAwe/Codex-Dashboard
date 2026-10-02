import XCTest
@testable import CodexDashboard

@MainActor
final class ReviewLoopDriverTests: XCTestCase {
    func testSavedModelSelectionMigratesToCurrentNames() throws {
        let loop = ReviewLoop(id: UUID(), startActionID: "saved", project: ReviewProject(id: "p", name: "Project", path: "/tmp/project"), promptContext: .general, maxRounds: 2)
        var saved = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(loop)) as? [String: Any])
        saved["reviewSelection"] = ["model": "chosen", "effort": "high"]
        let selection = try XCTUnwrap(ReviewLoopDocumentMigration.decode(JSONSerialization.data(withJSONObject: saved)).first?.reviewSelection)
        XCTAssertEqual(selection.modelID, "chosen")
        XCTAssertEqual(selection.reasoningEffort, "high")
        let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(selection)) as? [String: String])
        XCTAssertEqual(encoded, ["modelID": "chosen", "reasoningEffort": "high"])
    }

    func testSavedLoopCarriesPreviousSelectionIntoBothTurns() throws {
        let loop = ReviewLoop(id: UUID(), startActionID: "saved", project: ReviewProject(id: "p", name: "Project", path: "/tmp/project"), promptContext: .general, maxRounds: 2)
        var saved = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(loop)) as? [String: Any])
        saved["selection"] = ["modelID": "previous-model", "reasoningEffort": "high"]
        let restored = try XCTUnwrap(ReviewLoopDocumentMigration.decode(JSONSerialization.data(withJSONObject: saved)).first)
        XCTAssertEqual(restored.reviewSelection?.modelID, "previous-model")
        XCTAssertEqual(restored.fixSelection?.reasoningEffort, "high")
        let rewritten = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(restored)) as? [String: Any])
        XCTAssertNil(rewritten["selection"])
        XCTAssertNotNil(rewritten["reviewSelection"])
        XCTAssertNotNil(rewritten["fixSelection"])
    }

    func testProjectAndModelListsReadEveryPage() async throws {
        let connection = ReviewListDevTools()
        let driver = ReviewLoopDriver(devTools: connection, target: DevToolsTarget(id: "test", type: "page", url: nil, webSocketURL: nil))
        let projects = try await driver.projects()
        let models = try await driver.models()
        XCTAssertEqual(projects.map(\.name), ["Alpha", "Zeta"])
        XCTAssertEqual(models.map(\.modelID), ["model-a", "model-b"])
        let projectCursors = await connection.cursors(for: "project/list")
        let modelCursors = await connection.cursors(for: "model/list")
        XCTAssertEqual(projectCursors, [nil, "next"])
        XCTAssertEqual(modelCursors, [nil, "next"])
    }

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
        let repository = ReviewRepositoryState(root: "/tmp/project", branch: "main", commit: "base", clean: true)
        let driver = ReviewLoopDriver(devTools: connection,
                                      target: DevToolsTarget(id: "test", type: "page", url: nil, webSocketURL: nil),
                                      repositoryCheckpoint: ReviewFixedRepositoryCheckpoint(state: repository))
        let cases: [(ReviewTurnKind, ReviewSpeed)] = [(.review(.p1), .standard), (.fix, .fast)]
        for (kind, speed) in cases {
            let id = try await driver.startTurn(threadID: "thread", projectPath: "/tmp/project",
                                                expectedRepository: repository, prompt: "Do the work", kind: kind,
                                                selection: ReviewModelSelection(modelID: "chosen", reasoningEffort: "high"), speed: speed)
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
            XCTAssertTrue(text.contains(ReviewReportContract.instructions(for: kind)))
        }
    }

    func testStopReadsLatestMetadataAndInterruptsOnlyRunningTurns() async throws {
        for status in ["inProgress", "completed", "interrupted", "empty"] {
            let connection = ReviewStopDevTools(status: status)
            let driver = ReviewLoopDriver(devTools: connection, target: DevToolsTarget(id: "test", type: "page", url: nil, webSocketURL: nil))
            try await driver.stopThread("thread")
            let expressions = await connection.expressions
            let prefix = "window.__codexDashboard.reviewRequest("
            let requests = try expressions.map {
                try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.dropFirst(prefix.count).dropLast().utf8)) as? [String: Any])
            }
            XCTAssertEqual(requests.map { $0["method"] as? String }, status == "inProgress" ? ["thread/turns/list", "turn/interrupt"] : ["thread/turns/list"])
            let read = try XCTUnwrap(requests.first?["params"] as? [String: Any])
            XCTAssertEqual(read["threadId"] as? String, "thread")
            XCTAssertEqual(read["limit"] as? Int, 1)
            XCTAssertEqual(read["sortDirection"] as? String, "desc")
            XCTAssertEqual(read["itemsView"] as? String, "notLoaded")
            if status == "inProgress" {
                let interrupt = try XCTUnwrap(requests.last?["params"] as? [String: String])
                XCTAssertEqual(interrupt, ["threadId": "thread", "turnId": "latest-turn"])
            }
        }
    }

    func testReadsFollowupTurnsWithOptionalMessagePhaseAndBoundsHistory() throws {
        let turn: [String: Any] = ["id": "review", "status": "completed", "items": [
            ["type": "agentMessage", "phase": "commentary", "text": "Working"],
            ["type": "agentMessage", "text": "{\"findings\":[]}"],
        ]]
        let state = try ReviewLoopDriver.threadState(["thread": ["cwd": "/tmp/project", "turns": [turn, turn]]])
        XCTAssertEqual(state.turns.count, 2)
        XCTAssertEqual(state.turns.first?.finalMessage, "{\"findings\":[]}")
        XCTAssertEqual(try ReviewLoopDriver.threadState(["thread": ["cwd": "/tmp/project", "turns": [turn, turn, turn]]]).turns.count, 3)
        XCTAssertThrowsError(try ReviewLoopDriver.threadState(["thread": ["cwd": "/tmp/project", "turns": Array(repeating: turn, count: 101)]]))
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
        let checkpoint = ReviewRepositoryCheckpoint()
        let initial = try await checkpoint.repository(at: directory.path)
        XCTAssertTrue(initial.clean)
        XCTAssertEqual(initial.branch, "main")
        try Data("change".utf8).write(to: directory.appendingPathComponent("fix.txt"))
        let dirty = try await checkpoint.repository(at: directory.path)
        XCTAssertFalse(dirty.clean)
        try await git(["add", "fix.txt"])
        try await git(["-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "-m", "Fix"])
        let fixed = try await checkpoint.repository(at: directory.path)
        XCTAssertTrue(fixed.clean)
        XCTAssertNotEqual(fixed.commit, initial.commit)
        let isAncestor = try await checkpoint.isAncestor(initial.commit, of: fixed.commit, at: directory.path)
        XCTAssertTrue(isAncestor)
        for reported in [fixed.commit, String(fixed.commit.prefix(7)), String(fixed.commit.prefix(7)).uppercased()] {
            let resolved = try await checkpoint.resolveCommit(reported, at: directory.path)
            XCTAssertEqual(resolved, fixed.commit)
        }
        for invalid in ["", "HEAD", "main", "--help", "abc", "deadbeef", fixed.commit + "~1"] {
            do {
                _ = try await checkpoint.resolveCommit(invalid, at: directory.path)
                XCTFail("Accepted invalid commit ID: \(invalid)")
            } catch { }
        }
    }

    func testFixPromptDoesNotAskForTesting() throws {
        let loop = ReviewLoop(id: UUID(), startActionID: "test", project: ReviewProject(id: "p", name: "Project", path: "/tmp/project"), promptContext: .general, maxRounds: 5)
        let prompt = ReviewPrompts.fixPrompt(for: loop, round: ReviewRound(number: 1, baseCommit: "abc"))
        XCTAssertFalse(prompt.lowercased().contains("test"))
        XCTAssertFalse(prompt.lowercased().contains("checks"))
        XCTAssertEqual(prompt, "Fix all findings and commit. Verify each finding first. Mark invalid findings as withdrawn; if all are invalid, make no commit.")
        XCTAssertFalse(ReviewReportContract.instructions(for: .fix).lowercased().contains("test"))
    }

    func testOrganisationFixPromptNamesFindingsAndCommitForEachCount() {
        for focus in [ReviewFocus.organisation, .naming] {
            var loop = ReviewLoop(id: UUID(), startActionID: "test", project: ReviewProject(id: "p", name: "Project", path: "/tmp/project"), promptContext: .general, maxRounds: 5)
            loop.focus = focus
            for (count, expected) in [(1, "Address the finding and commit"), (2, "Address both findings and commit"), (3, "Address all findings and commit")] {
                var round = ReviewRound(number: 1, baseCommit: "abc")
                round.review = ReviewReport(outcome: .reviewed, findings: (0..<count).map { index in
                    ReviewFinding(priority: nil, title: "Finding \(index)", body: "Evidence")
                }, summary: "Findings")
                XCTAssertEqual(ReviewPrompts.fixPrompt(for: loop, round: round), expected + ". Verify each finding first. Mark invalid findings as withdrawn; if all are invalid, make no commit.")
            }
        }
    }
}

private struct ReviewFixedRepositoryCheckpoint: ReviewRepositoryChecking {
    let state: ReviewRepositoryState

    func repository(at path: String) async throws -> ReviewRepositoryState { state }
    func pushCommit(at path: String, expectedRepository: ReviewRepositoryState) async throws {}
    func resolveCommit(_ commit: String, at path: String) async throws -> String { commit }
    func isAncestor(_ commit: String, of head: String, at path: String) async throws -> Bool { true }
}

private actor ReviewListDevTools: DevToolsServing {
    private var requests: [(method: String, cursor: String?)] = []

    func cursors(for method: String) -> [String?] {
        requests.filter { $0.method == method }.map(\.cursor)
    }

    func mainRendererTargets() async -> [DevToolsTarget] { [] }
    func evaluateBoolean(_ expression: String, in target: DevToolsTarget) async throws -> Bool { false }
    func evaluateString(_ expression: String, in target: DevToolsTarget, timeout: Duration) async throws -> String? {
        let prefix = "window.__codexDashboard.reviewRequest("
        let request = try JSONSerialization.jsonObject(with: Data(expression.dropFirst(prefix.count).dropLast().utf8)) as? [String: Any]
        let method = request?["method"] as? String ?? ""
        let cursor = (request?["params"] as? [String: Any])?["cursor"] as? String
        requests.append((method, cursor))
        let row: String
        switch (method, cursor) {
        case ("project/list", nil):
            row = #"{"id":"z","name":"Zeta","roots":[{"path":"/tmp/z"}]}"#
        case ("project/list", "next"):
            row = #"{"id":"a","name":"Alpha","roots":[{"path":"/tmp/a"}]}"#
        case ("model/list", nil):
            row = #"{"model":"model-a","displayName":"A","supportedReasoningEfforts":[{"reasoningEffort":"high"}]}"#
        case ("model/list", "next"):
            row = #"{"model":"model-b","displayName":"B","supportedReasoningEfforts":[]}"#
        default: throw ReviewLoopError("Unexpected list request")
        }
        let next = cursor == nil ? #""next""# : "null"
        return #"{"result":{"data":[\#(row)],"nextCursor":\#(next)}}"#
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

private actor ReviewStopDevTools: DevToolsServing {
    let status: String
    var expressions: [String] = []
    init(status: String) { self.status = status }
    func mainRendererTargets() async -> [DevToolsTarget] { [] }
    func evaluateBoolean(_ expression: String, in target: DevToolsTarget) async throws -> Bool { false }
    func evaluateString(_ expression: String, in target: DevToolsTarget, timeout: Duration) async throws -> String? {
        let prefix = "window.__codexDashboard.reviewRequest("
        let request = try JSONSerialization.jsonObject(with: Data(expression.dropFirst(prefix.count).dropLast().utf8)) as! [String: Any]
        expressions.append(expression)
        if request["method"] as? String == "thread/turns/list" {
            let turns: [[String: String]] = status == "empty" ? [] : [["id": "latest-turn", "status": status]]
            return String(data: try JSONSerialization.data(withJSONObject: ["result": ["data": turns]]), encoding: .utf8)
        }
        return "{\"result\":{}}"
    }
}
