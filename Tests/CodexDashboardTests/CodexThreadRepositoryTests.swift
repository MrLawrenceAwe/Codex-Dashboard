import XCTest

@testable import CodexDashboard

final class CodexThreadRepositoryTests: XCTestCase {
    func testLoadsAndClassifiesThreads() async throws {
        let now = Int64(Date().timeIntervalSince1970)
        let stateDatabaseURL = try TestDatabaseFactory.makeStateDatabase(now: now, testCase: self)
        let activityDatabaseURL = try TestDatabaseFactory.makeActivityDatabase(now: now, testCase: self)
        let snapshot = try await CodexThreadRepository(
            stateDatabaseURL: stateDatabaseURL,
            activityDatabaseURL: activityDatabaseURL
        ).loadSnapshot()

        XCTAssertNil(snapshot.warning)
        XCTAssertEqual(snapshot.totalThreadCount, 3)
        XCTAssertEqual(snapshot.threads.map(\.id), ["running", "updated", "idle"])
        XCTAssertEqual(snapshot.threads.map(\.status), [.running, .idle, .idle])
        XCTAssertEqual(snapshot.threads.first?.title, "Running thread")
        XCTAssertEqual(snapshot.threads.first?.workspace, "running")
        XCTAssertTrue(snapshot.threads.first?.isPinned == true)
        XCTAssertEqual(snapshot.threads[1].title, "Renamed thread")
    }

    func testStillLoadsThreadsWhenActivityDatabaseIsMissing() async throws {
        let stateDatabaseURL = try TestDatabaseFactory.makeStateDatabase(
            now: Int64(Date().timeIntervalSince1970),
            testCase: self
        )
        let missingDatabaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-dashboard-missing-activity-\(UUID().uuidString).sqlite")
        let repository = CodexThreadRepository(
            stateDatabaseURL: stateDatabaseURL,
            activityDatabaseURL: missingDatabaseURL
        )
        let snapshot = try await repository.loadSnapshot()
        XCTAssertEqual(snapshot.threads.count, 3)
        XCTAssertEqual(snapshot.totalThreadCount, 3)
        XCTAssertFalse(snapshot.threads.contains { $0.status == .running })
        XCTAssertNotNil(snapshot.warning)
    }

    func testReportsFullCountWhenThreadRowsAreLimited() async throws {
        let now = Int64(Date().timeIntervalSince1970)
        let stateDatabaseURL = try TestDatabaseFactory.makeStateDatabase(
            now: now,
            additionalThreadCount: 60,
            testCase: self
        )
        let activityDatabaseURL = try TestDatabaseFactory.makeActivityDatabase(
            now: now,
            testCase: self
        )
        let snapshot = try await CodexThreadRepository(
            stateDatabaseURL: stateDatabaseURL,
            activityDatabaseURL: activityDatabaseURL
        ).loadSnapshot()

        XCTAssertEqual(snapshot.threads.count, 60)
        XCTAssertEqual(snapshot.totalThreadCount, 63)
    }

    func testReportsMissingStateDatabase() async throws {
        let missingDatabaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-dashboard-missing-state-\(UUID().uuidString).sqlite")
        let repository = CodexThreadRepository(stateDatabaseURL: missingDatabaseURL)
        do {
            _ = try await repository.loadSnapshot()
            XCTFail("Expected the missing state database to be reported")
        } catch ThreadRepositoryError.missingDatabase(let databaseURL) {
            XCTAssertEqual(databaseURL, missingDatabaseURL)
        }
    }
}
