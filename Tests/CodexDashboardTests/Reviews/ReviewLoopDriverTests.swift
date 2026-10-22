import XCTest
@testable import CodexDashboard

@MainActor
final class ReviewLoopDriverTests: XCTestCase {
    func testFolderFixUsesFolderReportAndChecksFingerprintBeforeSubmission() async throws {
        let connection = ReviewReportDevTools()
        let workspace = ReviewWorkspaceState(root: "/tmp/folder", revision: "fingerprint", git: nil)
        let driver = ReviewLoopDriver(devTools: connection,
            target: DevToolsTarget(id: "test", type: "page", url: nil, webSocketURL: nil),
            workspaceCheckpoint: ReviewFixedWorkspaceCheckpoint(state: workspace))
        _ = try await driver.startTurn(threadID: "thread", projectPath: "/tmp/folder", expectedWorkspace: workspace,
            prompt: "Address findings", kind: .fix, selection: nil, speed: .standard)
        let expression = await connection.expression
        XCTAssertTrue(expression.contains("# Fixes applied"))
        XCTAssertFalse(expression.contains("# Fixes committed"))
        var changed = workspace
        changed = ReviewWorkspaceState(root: workspace.root, revision: workspace.revision,
                                       git: .init(branch: "main", isClean: true))
        do {
            _ = try await driver.startTurn(threadID: "thread", projectPath: "/tmp/folder", expectedWorkspace: changed,
                prompt: "Address findings", kind: .fix, selection: nil, speed: .standard)
            XCTFail("Workspace identity must be checked before submission")
        } catch {}
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
        let workspace = ReviewWorkspaceState(root: "/tmp/project", revision: "base", git: .init(branch: "main", isClean: true))
        let driver = ReviewLoopDriver(devTools: connection,
                                      target: DevToolsTarget(id: "test", type: "page", url: nil, webSocketURL: nil),
                                      workspaceCheckpoint: ReviewFixedWorkspaceCheckpoint(state: workspace))
        let cases: [(ReviewTurnKind, ReviewSpeed)] = [(.review(.p1), .standard), (.fix, .fast)]
        for (kind, speed) in cases {
            let id = try await driver.startTurn(threadID: "thread", projectPath: "/tmp/project",
                                                expectedWorkspace: workspace, prompt: "Do the work", kind: kind,
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

    func testOnlyFixContinuationCanStartWithUnfinishedChanges() async throws {
        let connection = ReviewReportDevTools()
        let workspace = ReviewWorkspaceState(root: "/tmp/project", revision: "base", git: .init(branch: "main", isClean: false))
        let driver = ReviewLoopDriver(devTools: connection,
                                      target: DevToolsTarget(id: "test", type: "page", url: nil, webSocketURL: nil),
                                      workspaceCheckpoint: ReviewFixedWorkspaceCheckpoint(state: workspace))
        for kind in [ReviewTurnKind.review(.p2), .fix] {
            do {
                _ = try await driver.startTurn(threadID: "thread", projectPath: "/tmp/project", expectedWorkspace: workspace,
                                               prompt: "Continue", kind: kind, selection: nil, speed: .standard)
                XCTFail("Ordinary turns must require a clean checkout")
            } catch {}
        }
        let id = try await driver.startTurn(threadID: "thread", projectPath: "/tmp/project", expectedWorkspace: workspace,
                                             prompt: "Continue", kind: .fixContinuation, selection: nil, speed: .standard)
        XCTAssertEqual(id, "turn")
        let changed = ReviewWorkspaceState(root: workspace.root, revision: workspace.revision, git: .init(branch: "other", isClean: false))
        do {
            _ = try await driver.startTurn(threadID: "thread", projectPath: "/tmp/project", expectedWorkspace: changed,
                                           prompt: "Continue", kind: .fixContinuation, selection: nil, speed: .standard)
            XCTFail("Continuation must still verify the expected workspace")
        } catch {}
    }

    func testStopReadsLatestMetadataAndInterruptsOnlyRunningTurns() async throws {
        for status in ["inProgress", "completed", "interrupted", "failed", "empty"] {
            let connection = ReviewStopDevTools(status: status)
            let driver = ReviewLoopDriver(devTools: connection, target: DevToolsTarget(id: "test", type: "page", url: nil, webSocketURL: nil))
            try await driver.interruptLatestTurn("thread")
            let expressions = await connection.expressions
            let prefix = "window.__codexDashboard.reviewRequest("
            let requests = try expressions.map {
                try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.dropFirst(prefix.count).dropLast().utf8)) as? [String: Any])
            }
            XCTAssertEqual(requests.map { $0["method"] as? String }, status == "inProgress" ? ["thread/turns/list", "turn/interrupt", "thread/turns/list"] : ["thread/turns/list"])
            let read = try XCTUnwrap(requests.first?["params"] as? [String: Any])
            XCTAssertEqual(read["threadId"] as? String, "thread")
            XCTAssertEqual(read["limit"] as? Int, 1)
            XCTAssertEqual(read["sortDirection"] as? String, "desc")
            XCTAssertEqual(read["itemsView"] as? String, "notLoaded")
            if status == "inProgress" {
                let interrupt = try XCTUnwrap(requests[1]["params"] as? [String: String])
                XCTAssertEqual(interrupt, ["threadId": "thread", "turnId": "latest-turn"])
            }
        }
    }

    func testInterruptAcknowledgementDoesNotReleaseStillRunningTurn() async throws {
        let connection = ReviewStopDevTools(status: "inProgress", confirmsInterruption: false)
        let driver = ReviewLoopDriver(devTools: connection, target: DevToolsTarget(id: "test", type: "page", url: nil, webSocketURL: nil))
        do {
            try await driver.interruptLatestTurn("thread")
            XCTFail("An acknowledgement alone must not confirm interruption")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("still stopping"))
        }
        let count = await connection.expressions.count
        XCTAssertEqual(count, 3)
    }

    func testUnloadedChatNeedsVerifiedCatalogAbsenceBeforeReleasingCheckout() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("review-catalog-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = directory.appendingPathComponent("state.sqlite")
        for exists in [false, true] {
            let setup = try await Subprocess.run(executableURL: URL(fileURLWithPath: "/usr/bin/sqlite3"),
                arguments: [database.path, "CREATE TABLE IF NOT EXISTS threads (id TEXT); DELETE FROM threads;" + (exists ? "INSERT INTO threads VALUES ('thread');" : "")], timeout: 5)
            XCTAssertEqual(setup.terminationStatus, 0)
            let connection = ReviewStopDevTools(status: "notLoaded")
            let driver = ReviewLoopDriver(devTools: connection, target: DevToolsTarget(id: "test", type: "page", url: nil, webSocketURL: nil), stateDatabaseURL: database)
            do {
                try await driver.interruptLatestTurn("thread")
                XCTFail("An unloaded chat must either confirm absence or retain the checkout")
            } catch is ReviewChatMissingError {
                XCTAssertFalse(exists)
            } catch {
                XCTAssertTrue(exists)
            }
        }
        try FileManager.default.removeItem(at: database)
        let connection = ReviewStopDevTools(status: "notLoaded")
        let driver = ReviewLoopDriver(devTools: connection, target: DevToolsTarget(id: "test", type: "page", url: nil, webSocketURL: nil), stateDatabaseURL: database)
        do {
            try await driver.interruptLatestTurn("thread")
            XCTFail("A missing database cannot confirm deletion")
        } catch is ReviewChatMissingError {
            XCTFail("Database failures must retain the checkout")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Could not verify"))
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

    func testTurnStatusesDecodeConsistentlyAndUnknownStatusesAreRejected() async throws {
        for status in ReviewTurnStatus.allCases {
            let turn: [String: Any] = ["id": "review", "status": status.rawValue]
            let thread: [String: Any] = ["cwd": "/tmp/project", "status": ["type": "active"], "turns": [turn]]
            let state = try ReviewLoopDriver.threadState(["thread": thread])
            XCTAssertEqual(state.turns.first?.status, status)
        }
        for status in ["queued", "", "COMPLETED"] {
            let turn: [String: Any] = ["id": "review", "status": status]
            XCTAssertThrowsError(try ReviewLoopDriver.threadState(["thread": ["cwd": "/tmp/project", "turns": [turn]]]))
            let connection = ReviewStopDevTools(status: status)
            let driver = ReviewLoopDriver(devTools: connection,
                target: DevToolsTarget(id: "test", type: "page", url: nil, webSocketURL: nil))
            do {
                try await driver.interruptLatestTurn("thread")
                XCTFail("Unknown statuses must not release the checkout")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("invalid review turn"))
            }
        }
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
        XCTAssertEqual(running.turns.first?.status, .inProgress)
    }

}

private struct ReviewFixedWorkspaceCheckpoint: ReviewWorkspaceChecking {
    let state: ReviewWorkspaceState

    func workspace(at path: String) async throws -> ReviewWorkspaceState { state }
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
    var status: String
    let confirmsInterruption: Bool
    var expressions: [String] = []
    init(status: String, confirmsInterruption: Bool = true) {
        self.status = status
        self.confirmsInterruption = confirmsInterruption
    }
    func mainRendererTargets() async -> [DevToolsTarget] { [] }
    func evaluateBoolean(_ expression: String, in target: DevToolsTarget) async throws -> Bool { false }
    func evaluateString(_ expression: String, in target: DevToolsTarget, timeout: Duration) async throws -> String? {
        let prefix = "window.__codexDashboard.reviewRequest("
        let request = try JSONSerialization.jsonObject(with: Data(expression.dropFirst(prefix.count).dropLast().utf8)) as! [String: Any]
        expressions.append(expression)
        if request["method"] as? String == "thread/turns/list" {
            if status == "notLoaded" { return #"{"error":{"message":"thread not loaded: thread"}}"# }
            let turns: [[String: String]] = status == "empty" ? [] : [["id": "latest-turn", "status": status]]
            return String(data: try JSONSerialization.data(withJSONObject: ["result": ["data": turns]]), encoding: .utf8)
        }
        if request["method"] as? String == "turn/interrupt", confirmsInterruption { status = "interrupted" }
        return "{\"result\":{}}"
    }
}
