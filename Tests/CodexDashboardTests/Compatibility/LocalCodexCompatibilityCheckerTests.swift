import Foundation
import XCTest

@testable import CodexDashboard

final class LocalCodexCompatibilityCheckerTests: XCTestCase {
    func testLiveLocalContractsWhenEnabled() async throws {
        guard ProcessInfo.processInfo.environment["CODEX_DASHBOARD_LIVE_TEST"] == "1" else {
            throw XCTSkip("Set CODEX_DASHBOARD_LIVE_TEST=1 to inspect local Codex contracts.")
        }

        let checks = await LocalCodexCompatibilityChecker().checkLocalContracts()

        XCTAssertFalse(
            checks.contains { $0.status == .incompatible },
            checks.map { "\($0.title): \($0.detail)" }.joined(separator: "\n")
        )
    }

    func testRecognizesCurrentLocalStorageContracts() async throws {
        let databaseURL = try CodexTestFixtures.makeStateDatabase(
            now: Int64(Date().timeIntervalSince1970),
            testCase: self
        )
        let globalStateURL = try makeGlobalState(
            #"{"electron-persisted-atom-state":{"unread-thread-ids-by-host-v1":{"local":["thread-1"]}}}"#
        )
        let checker = LocalCodexCompatibilityChecker(
            applicationURL: URL(fileURLWithPath: "/missing/Codex.app"),
            stateDatabaseURL: databaseURL,
            globalStateURL: globalStateURL
        )

        let checks = await checker.checkLocalContracts()

        XCTAssertEqual(status("thread-database", in: checks), .compatible)
        XCTAssertEqual(status("unread-state", in: checks), .compatible)
        XCTAssertEqual(status("rollout-events", in: checks), .compatible)
    }

    func testReportsSchemaAndUnreadStateDriftIndependently() async throws {
        let databaseURL = try CodexTestFixtures.makeDatabase(
            schema: "CREATE TABLE threads (id TEXT PRIMARY KEY, rollout_path TEXT NOT NULL, recency_at_ms INTEGER NOT NULL);",
            testCase: self
        )
        let globalStateURL = try makeGlobalState(#"{"electron-persisted-atom-state":{}}"#)
        let checker = LocalCodexCompatibilityChecker(
            applicationURL: URL(fileURLWithPath: "/missing/Codex.app"),
            stateDatabaseURL: databaseURL,
            globalStateURL: globalStateURL
        )

        let checks = await checker.checkLocalContracts()

        XCTAssertEqual(status("thread-database", in: checks), .incompatible)
        XCTAssertEqual(status("unread-state", in: checks), .warning)
        XCTAssertEqual(status("rollout-events", in: checks), .unavailable)
    }

    func testDatabaseInspectionFailureIsNonBlocking() async throws {
        let invalidDatabaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-dashboard-invalid-database-\(UUID().uuidString).sqlite")
        try Data("not a sqlite database".utf8).write(to: invalidDatabaseURL)
        addTeardownBlock { try? FileManager.default.removeItem(at: invalidDatabaseURL) }
        let checker = LocalCodexCompatibilityChecker(
            applicationURL: URL(fileURLWithPath: "/missing/Codex.app"),
            stateDatabaseURL: invalidDatabaseURL,
            globalStateURL: URL(fileURLWithPath: "/missing/global-state.json")
        )

        let checks = await checker.checkLocalContracts()

        XCTAssertEqual(status("thread-database", in: checks), .unavailable)
    }

    func testRejectsUnreadArraysThatProductionDecoderCannotRead() async throws {
        let globalStateURL = try makeGlobalState(
            #"{"electron-persisted-atom-state":{"unread-thread-ids-by-host-v1":{"local":[42]}}}"#
        )
        let checker = LocalCodexCompatibilityChecker(
            applicationURL: URL(fileURLWithPath: "/missing/Codex.app"),
            stateDatabaseURL: URL(fileURLWithPath: "/missing/state.sqlite"),
            globalStateURL: globalStateURL
        )

        let checks = await checker.checkLocalContracts()

        XCTAssertEqual(status("unread-state", in: checks), .warning)
    }

    func testReportSeparatesBlockingAndNonBlockingResults() {
        let report = CompatibilityReport(checks: [
            CompatibilityCheck(id: "one", title: "One", status: .incompatible, detail: "Broken"),
            CompatibilityCheck(id: "two", title: "Two", status: .warning, detail: "Changed"),
            CompatibilityCheck(id: "three", title: "Three", status: .unavailable, detail: "Closed"),
        ])

        XCTAssertEqual(report.blockingCount, 1)
        XCTAssertEqual(report.warningCount, 2)
        XCTAssertEqual(report.summary, "1 incompatible \u{00b7} 2 need attention")
    }

    private func status(
        _ id: String,
        in checks: [CompatibilityCheck]
    ) -> CompatibilityStatus? {
        checks.first { $0.id == id }?.status
    }

    private func makeGlobalState(_ contents: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-dashboard-global-state-\(UUID().uuidString).json")
        try Data(contents.utf8).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}
