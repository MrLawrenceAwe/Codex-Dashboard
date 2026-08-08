import XCTest
@testable import CodexCanvas

final class CanvasAdapterTests: XCTestCase {
    private func makeDatabase(schema: String, rows: String = "") throws -> String {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-dashboard-tests-\(UUID().uuidString).sqlite")
            .path
        let process = Process()
        let errors = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [path, schema + rows]
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(
                data: errors.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? "Unknown sqlite3 error"
            XCTFail("Could not create test database: \(message)")
            throw TaskStoreError.queryFailed(path, message)
        }
        addTeardownBlock { try? FileManager.default.removeItem(atPath: path) }
        return path
    }

    private func makeStateDatabase(now: Int64) throws -> String {
        try makeDatabase(
            schema: """
            CREATE TABLE threads (
              id TEXT PRIMARY KEY,
              name TEXT,
              title TEXT NOT NULL,
              preview TEXT NOT NULL DEFAULT '',
              cwd TEXT NOT NULL,
              updated_at INTEGER NOT NULL,
              created_at INTEGER NOT NULL,
              is_pinned INTEGER NOT NULL DEFAULT 0,
              model TEXT,
              archived INTEGER NOT NULL DEFAULT 0,
              recency_at_ms INTEGER NOT NULL DEFAULT 0
            );
            """,
            rows: """
            INSERT INTO threads VALUES
              ('running', NULL, 'Running task', 'Running preview', '/tmp/running', \(now - 30), \(now - 300), 1, 'test-model', 0, \((now - 30) * 1000)),
              ('recent', 'Renamed task', 'Old title', 'Recent preview', '/tmp/recent', \(now - 600), \(now - 900), 0, NULL, 0, \((now - 600) * 1000)),
              ('idle', NULL, 'Idle task', 'Idle preview', '/tmp/idle', \(now - 7200), \(now - 9000), 0, NULL, 0, \((now - 7200) * 1000)),
              ('empty', NULL, 'Empty task', '', '/tmp/empty', \(now), \(now), 0, NULL, 0, \(now * 1000)),
              ('archived', NULL, 'Archived task', 'Archived preview', '/tmp/archived', \(now), \(now), 0, NULL, 1, \(now * 1000));
            """
        )
    }

    private func makeLogsDatabase(now: Int64) throws -> String {
        try makeDatabase(
            schema: """
            CREATE TABLE logs (
              id INTEGER PRIMARY KEY,
              ts INTEGER NOT NULL,
              thread_id TEXT
            );
            """,
            rows: """
            INSERT INTO logs (ts, thread_id) VALUES
              (\(now - 2), 'running'),
              (\(now - 90), 'recent'),
              (\(now - 300), 'idle');
            """
        )
    }

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

    func testTaskStoreLoadsAndClassifiesThreads() async throws {
        let now = Int64(Date().timeIntervalSince1970)
        let stateDatabase = try makeStateDatabase(now: now)
        let logsDatabase = try makeLogsDatabase(now: now)
        let snapshot = try await TaskStore(
            stateDatabase: stateDatabase,
            logsDatabase: logsDatabase
        ).load()

        XCTAssertNil(snapshot.warning)
        XCTAssertEqual(snapshot.tasks.map(\.id), ["running", "recent", "idle"])
        XCTAssertEqual(snapshot.tasks.map(\.status), ["running", "recent", "idle"])
        XCTAssertEqual(snapshot.tasks.first?.title, "Running task")
        XCTAssertEqual(snapshot.tasks.first?.workspace, "running")
        XCTAssertTrue(snapshot.tasks.first?.isPinned == true)
        XCTAssertEqual(snapshot.tasks[1].title, "Renamed task")
    }

    func testTaskStoreStillLoadsThreadsWhenActivityDatabaseIsMissing() async throws {
        let stateDatabase = try makeStateDatabase(now: Int64(Date().timeIntervalSince1970))
        let missingDatabase = "/tmp/codex-dashboard-missing-activity-\(UUID().uuidString).sqlite"
        let store = TaskStore(stateDatabase: stateDatabase, logsDatabase: missingDatabase)
        let snapshot = try await store.load()
        XCTAssertEqual(snapshot.tasks.count, 3)
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
