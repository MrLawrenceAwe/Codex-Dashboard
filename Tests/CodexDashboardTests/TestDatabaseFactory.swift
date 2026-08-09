import Foundation
import XCTest

@testable import CodexDashboard

enum TestDatabaseFactory {
    private static func makeRollout(
        lifecycleEvents: [String],
        testCase: XCTestCase
    ) throws -> URL {
        let rolloutURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-dashboard-rollout-\(UUID().uuidString).jsonl")
        let lines = try lifecycleEvents.map { event -> String in
            let data = try JSONSerialization.data(withJSONObject: [
                "type": "event_msg",
                "payload": ["type": event],
            ])
            return String(decoding: data, as: UTF8.self)
        }
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: rolloutURL)
        testCase.addTeardownBlock { try? FileManager.default.removeItem(at: rolloutURL) }
        return rolloutURL
    }

    static func makeDatabase(
        schema: String,
        rows: String = "",
        testCase: XCTestCase
    ) throws -> URL {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-dashboard-tests-\(UUID().uuidString).sqlite")
        let process = Process()
        let errors = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [databaseURL.path, schema + rows]
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(
                data: errors.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? "Unknown sqlite3 error"
            XCTFail("Could not create test database: \(message)")
            throw ThreadRepositoryError.queryFailed(databaseURL, message)
        }
        testCase.addTeardownBlock { try? FileManager.default.removeItem(at: databaseURL) }
        return databaseURL
    }

    static func makeStateDatabase(
        now: Int64,
        additionalThreadCount: Int = 0,
        runningWorkspacePath: String = "/tmp/running",
        testCase: XCTestCase
    ) throws -> URL {
        let runningRollout = try makeRollout(
            lifecycleEvents: ["task_complete", "task_started"],
            testCase: testCase
        )
        let completedRollout = try makeRollout(
            lifecycleEvents: ["task_started", "task_complete"],
            testCase: testCase
        )
        let escapedRunningRollout = runningRollout.path.replacingOccurrences(of: "'", with: "''")
        let escapedCompletedRollout = completedRollout.path.replacingOccurrences(of: "'", with: "''")
        let escapedRunningWorkspacePath = runningWorkspacePath.replacingOccurrences(of: "'", with: "''")
        let additionalRows = (0..<additionalThreadCount).map { index in
            "INSERT INTO threads VALUES ('extra-\(index)', '\(escapedCompletedRollout)', NULL, 'Extra thread \(index)', "
                + "'Extra preview', '/tmp/extra-\(index)', \(now - Int64(index + 1)), "
                + "\(now - Int64(index + 1)), 0, NULL, 0, \((now - Int64(index + 1)) * 1000));"
        }.joined(separator: "\n")

        return try makeDatabase(
            schema: """
            CREATE TABLE threads (
              id TEXT PRIMARY KEY,
              rollout_path TEXT NOT NULL,
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
              ('running', '\(escapedRunningRollout)', NULL, 'Running thread', 'Running preview', '\(escapedRunningWorkspacePath)', \(now - 30), \(now - 300), 1, 'test-model', 0, \((now - 30) * 1000)),
              ('updated', '\(escapedCompletedRollout)', 'Renamed thread', 'Old title', 'Updated preview', '/tmp/updated', \(now - 600), \(now - 900), 0, NULL, 0, \((now - 600) * 1000)),
              ('idle', '\(escapedCompletedRollout)', NULL, 'Idle thread', 'Idle preview', '/tmp/idle', \(now - 7200), \(now - 9000), 0, NULL, 0, \((now - 7200) * 1000)),
              ('empty', '\(escapedCompletedRollout)', NULL, 'Empty thread', '', '/tmp/empty', \(now), \(now), 0, NULL, 0, \(now * 1000)),
              ('archived', '\(escapedCompletedRollout)', NULL, 'Archived thread', 'Archived preview', '/tmp/archived', \(now), \(now), 0, NULL, 1, \(now * 1000));
            \(additionalRows)
            """,
            testCase: testCase
        )
    }

}
