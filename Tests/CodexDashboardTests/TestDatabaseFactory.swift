import Foundation
import XCTest

@testable import CodexDashboard

enum TestDatabaseFactory {
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
            throw TaskRepositoryError.queryFailed(databaseURL, message)
        }
        testCase.addTeardownBlock { try? FileManager.default.removeItem(at: databaseURL) }
        return databaseURL
    }

    static func makeStateDatabase(
        now: Int64,
        additionalThreadCount: Int = 0,
        testCase: XCTestCase
    ) throws -> URL {
        let additionalRows = (0..<additionalThreadCount).map { index in
            "INSERT INTO threads VALUES ('extra-\(index)', NULL, 'Extra task \(index)', "
                + "'Extra preview', '/tmp/extra-\(index)', \(now - Int64(index + 1)), "
                + "\(now - Int64(index + 1)), 0, NULL, 0, \((now - Int64(index + 1)) * 1000));"
        }.joined(separator: "\n")

        return try makeDatabase(
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
            \(additionalRows)
            """,
            testCase: testCase
        )
    }

    static func makeActivityDatabase(now: Int64, testCase: XCTestCase) throws -> URL {
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
            """,
            testCase: testCase
        )
    }
}
