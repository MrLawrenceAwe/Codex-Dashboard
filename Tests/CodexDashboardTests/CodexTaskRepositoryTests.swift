import XCTest

@testable import CodexDashboard

final class CodexTaskRepositoryTests: XCTestCase {
    func testLoadsAndClassifiesThreads() async throws {
        let now = Int64(Date().timeIntervalSince1970)
        let stateDatabaseURL = try TestDatabaseFactory.makeStateDatabase(now: now, testCase: self)
        let activityDatabaseURL = try TestDatabaseFactory.makeActivityDatabase(now: now, testCase: self)
        let snapshot = try await CodexTaskRepository(
            stateDatabaseURL: stateDatabaseURL,
            activityDatabaseURL: activityDatabaseURL
        ).loadSnapshot()

        XCTAssertNil(snapshot.warning)
        XCTAssertEqual(snapshot.tasks.map(\.id), ["running", "recent", "idle"])
        XCTAssertEqual(snapshot.tasks.map(\.status), [.running, .recent, .idle])
        XCTAssertEqual(snapshot.tasks.first?.title, "Running task")
        XCTAssertEqual(snapshot.tasks.first?.workspace, "running")
        XCTAssertTrue(snapshot.tasks.first?.isPinned == true)
        XCTAssertEqual(snapshot.tasks[1].title, "Renamed task")
    }

    func testStillLoadsThreadsWhenActivityDatabaseIsMissing() async throws {
        let stateDatabaseURL = try TestDatabaseFactory.makeStateDatabase(
            now: Int64(Date().timeIntervalSince1970),
            testCase: self
        )
        let missingDatabaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-dashboard-missing-activity-\(UUID().uuidString).sqlite")
        let repository = CodexTaskRepository(
            stateDatabaseURL: stateDatabaseURL,
            activityDatabaseURL: missingDatabaseURL
        )
        let snapshot = try await repository.loadSnapshot()
        XCTAssertEqual(snapshot.tasks.count, 3)
        XCTAssertFalse(snapshot.tasks.contains { $0.status == .running })
        XCTAssertNotNil(snapshot.warning)
    }

    func testReportsMissingStateDatabase() async throws {
        let missingDatabaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-dashboard-missing-state-\(UUID().uuidString).sqlite")
        let repository = CodexTaskRepository(stateDatabaseURL: missingDatabaseURL)
        do {
            _ = try await repository.loadSnapshot()
            XCTFail("Expected the missing state database to be reported")
        } catch TaskRepositoryError.missingDatabase(let databaseURL) {
            XCTAssertEqual(databaseURL, missingDatabaseURL)
        }
    }
}
