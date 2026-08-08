import XCTest
@testable import CodexCanvas

final class CanvasAdapterTests: XCTestCase {
    func testDevToolsTargetDecoding() throws {
        let data = Data(#"[{"id":"page-1","type":"page","title":"Codex","url":"app://codex","webSocketDebuggerUrl":"ws://127.0.0.1/devtools/page/1"}]"#.utf8)
        let targets = try JSONDecoder().decode([DevToolsTarget].self, from: data)
        XCTAssertEqual(targets.first?.id, "page-1")
        XCTAssertEqual(targets.first?.type, "page")
        XCTAssertNotNil(targets.first?.webSocketDebuggerUrl)
    }

    func testOnlyMainRendererIsEligibleForInjection() throws {
        let data = Data(#"""
        [
          {"id":"main","type":"page","title":"Codex","url":"app://-/index.html","webSocketDebuggerUrl":"ws://127.0.0.1/main"},
          {"id":"hotkey","type":"page","title":"Codex","url":"app://-/index.html?initialRoute=%2Fhotkey-window","webSocketDebuggerUrl":"ws://127.0.0.1/hotkey"},
          {"id":"avatar","type":"page","title":"Codex","url":"app://-/index.html?initialRoute=%2Favatar-overlay","webSocketDebuggerUrl":"ws://127.0.0.1/avatar"}
        ]
        """#.utf8)
        let targets = try JSONDecoder().decode([DevToolsTarget].self, from: data)
            .filter(DevToolsClient.isMainRenderer)
        XCTAssertEqual(targets.map(\.id), ["main"])
    }

    func testLiveDevToolsRoundTripWhenEnabled() async throws {
        guard ProcessInfo.processInfo.environment["CODEX_CANVAS_LIVE_TEST"] == "1" else {
            throw XCTSkip("Set CODEX_CANVAS_LIVE_TEST=1 with a page target on port 47832.")
        }
        let client = DevToolsClient()
        let deadline = ContinuousClock.now + .seconds(8)
        var targets: [DevToolsTarget] = []
        while targets.isEmpty, ContinuousClock.now < deadline {
            targets = await client.targets()
            if targets.isEmpty { try await Task.sleep(for: .milliseconds(200)) }
        }
        let target = try XCTUnwrap(targets.first)
        let result = try await client.evaluate("(() => true)()", in: target)
        XCTAssertTrue(result)
    }

    func testDevToolsTimeoutCancelsSlowOperation() async throws {
        do {
            _ = try await withDevToolsTimeout(.milliseconds(10)) {
                try await Task.sleep(for: .seconds(5))
                return true
            }
            XCTFail("Expected the operation to time out")
        } catch CanvasError.devToolsTimedOut {
            // Expected.
        }
    }

    func testTaskStoreLoadsLocalCodexThreads() async throws {
        let snapshot = try await TaskStore().load()
        let tasks = snapshot.tasks
        XCTAssertFalse(tasks.isEmpty)
        XCTAssertTrue(tasks.allSatisfy { !$0.id.isEmpty && !$0.title.isEmpty })
        XCTAssertTrue(tasks.contains { $0.cwd.contains("/Users/lawrenceawe/") })
    }

    func testTaskStoreStillLoadsThreadsWhenActivityDatabaseIsMissing() async throws {
        let missingDatabase = "/tmp/codex-dashboard-missing-activity-\(UUID().uuidString).sqlite"
        let store = TaskStore(logsDatabase: missingDatabase)
        let snapshot = try await store.load()
        XCTAssertFalse(snapshot.tasks.isEmpty)
        XCTAssertFalse(snapshot.tasks.contains { $0.status == "running" })
        XCTAssertNotNil(snapshot.warning)
    }

    func testTaskStoreReportsMissingStateDatabase() async throws {
        let missingDatabase = "/tmp/codex-dashboard-missing-state-\(UUID().uuidString).sqlite"
        let store = TaskStore(stateDatabase: missingDatabase)
        do {
            _ = try await store.load()
            XCTFail("Expected the missing state database to be reported")
        } catch TaskStoreError.missingDatabase(let database) {
            XCTAssertEqual(database, missingDatabase)
        }
    }
}
