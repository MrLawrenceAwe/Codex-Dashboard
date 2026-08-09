import XCTest

@testable import CodexDashboard

final class CodexThreadRepositoryTests: XCTestCase {
    func testLiveSnapshotWhenEnabled() async throws {
        guard ProcessInfo.processInfo.environment["CODEX_DASHBOARD_LIVE_TEST"] == "1" else {
            throw XCTSkip("Set CODEX_DASHBOARD_LIVE_TEST=1 to read the local Codex snapshot.")
        }

        let snapshot = try await CodexThreadRepository().loadSnapshot(
            gitStatuses: [:],
            activeApplicationLaunchDate: .distantPast
        )
        XCTAssertFalse(snapshot.threads.isEmpty)
        XCTAssertGreaterThanOrEqual(snapshot.totalThreadCount, snapshot.threads.count)
        XCTAssertTrue(snapshot.threads.contains { $0.activity == .running })
    }

    func testLoadsAndClassifiesThreads() async throws {
        let now = Int64(Date().timeIntervalSince1970)
        let stateDatabaseURL = try TestDatabaseFactory.makeStateDatabase(now: now, testCase: self)
        let snapshot = try await CodexThreadRepository(
            stateDatabaseURL: stateDatabaseURL
        ).loadSnapshot(gitStatuses: [:], activeApplicationLaunchDate: .distantPast)

        XCTAssertEqual(snapshot.totalThreadCount, 3)
        XCTAssertEqual(snapshot.threads.map(\.id), ["running", "updated", "idle"])
        XCTAssertEqual(snapshot.threads.map(\.activity), [.running, .idle, .idle])
        XCTAssertEqual(snapshot.threads.first?.title, "Running thread")
        XCTAssertEqual(snapshot.threads.first?.workspace, "running")
        XCTAssertEqual(snapshot.threads.first?.workspacePath, "/tmp/running")
        XCTAssertEqual(snapshot.threads.first?.updatedAtUnixSeconds, now - 300)
        XCTAssertEqual(snapshot.threads.first?.gitStatus, .notRepository)
        XCTAssertTrue(snapshot.threads.first?.isPinned == true)
        XCTAssertEqual(snapshot.threads[1].title, "Renamed thread")
        XCTAssertEqual(snapshot.threads[1].updatedAtUnixSeconds, now - 600)
    }

    func testRunningLifecycleAfterApplicationLaunchDoesNotDependOnRecentLogs() async throws {
        let stateDatabaseURL = try TestDatabaseFactory.makeStateDatabase(
            now: Int64(Date().timeIntervalSince1970),
            testCase: self
        )
        let repository = CodexThreadRepository(stateDatabaseURL: stateDatabaseURL)
        let snapshot = try await repository.loadSnapshot(
            gitStatuses: [:],
            activeApplicationLaunchDate: .distantPast
        )
        XCTAssertEqual(snapshot.threads.count, 3)
        XCTAssertEqual(snapshot.totalThreadCount, 3)
        XCTAssertEqual(snapshot.threads.first?.activity, .running)
    }

    func testStartedBeforeCurrentApplicationLaunchIsIdle() async throws {
        let stateDatabaseURL = try TestDatabaseFactory.makeStateDatabase(
            now: Int64(Date().timeIntervalSince1970),
            testCase: self
        )
        let snapshot = try await CodexThreadRepository(
            stateDatabaseURL: stateDatabaseURL
        ).loadSnapshot(gitStatuses: [:], activeApplicationLaunchDate: .distantFuture)

        XCTAssertEqual(snapshot.threads.first { $0.id == "running" }?.activity, .idle)
    }

    func testOrdersThreadsByFinalResponseInsteadOfDatabaseActivity() async throws {
        let now = Int64(Date().timeIntervalSince1970)
        let stateDatabaseURL = try TestDatabaseFactory.makeStateDatabase(
            now: now,
            runningFinalResponseAtUnixSeconds: now - 1_200,
            testCase: self
        )
        let snapshot = try await CodexThreadRepository(
            stateDatabaseURL: stateDatabaseURL
        ).loadSnapshot(gitStatuses: [:], activeApplicationLaunchDate: .distantPast)

        XCTAssertEqual(snapshot.threads.map(\.id), ["updated", "running", "idle"])
        XCTAssertEqual(snapshot.threads[1].activity, .running)
        XCTAssertEqual(snapshot.threads[1].updatedAtUnixSeconds, now - 1_200)
    }

    func testReadsFinalResponseTimestampAcrossChunkBoundaries() async throws {
        let now = Int64(Date().timeIntervalSince1970)
        let stateDatabaseURL = try TestDatabaseFactory.makeStateDatabase(
            now: now,
            runningFinalResponseAtUnixSeconds: now - 90,
            runningFinalResponseMessageSize: 128 * 1_024,
            testCase: self
        )
        let snapshot = try await CodexThreadRepository(
            stateDatabaseURL: stateDatabaseURL
        ).loadSnapshot(gitStatuses: [:], activeApplicationLaunchDate: .distantPast)

        XCTAssertEqual(
            snapshot.threads.first { $0.id == "running" }?.updatedAtUnixSeconds,
            now - 90
        )
    }

    func testAbortedTurnIsIdle() async throws {
        let now = Int64(Date().timeIntervalSince1970)
        let stateDatabaseURL = try TestDatabaseFactory.makeStateDatabase(
            now: now,
            runningLifecycleEvents: ["task_complete", "task_started", "turn_aborted"],
            testCase: self
        )
        let snapshot = try await CodexThreadRepository(
            stateDatabaseURL: stateDatabaseURL
        ).loadSnapshot(gitStatuses: [:], activeApplicationLaunchDate: .distantPast)

        XCTAssertEqual(snapshot.threads.first?.activity, .idle)
    }

    func testReportsFullCountWhenThreadRowsAreLimited() async throws {
        let now = Int64(Date().timeIntervalSince1970)
        let stateDatabaseURL = try TestDatabaseFactory.makeStateDatabase(
            now: now,
            additionalThreadCount: 60,
            testCase: self
        )
        let snapshot = try await CodexThreadRepository(
            stateDatabaseURL: stateDatabaseURL
        ).loadSnapshot(gitStatuses: [:], activeApplicationLaunchDate: .distantPast)

        XCTAssertEqual(snapshot.threads.count, 60)
        XCTAssertEqual(snapshot.totalThreadCount, 63)
    }

    func testReportsMissingStateDatabase() async throws {
        let missingDatabaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-dashboard-missing-state-\(UUID().uuidString).sqlite")
        let repository = CodexThreadRepository(stateDatabaseURL: missingDatabaseURL)
        do {
            _ = try await repository.loadSnapshot(
                gitStatuses: [:],
                activeApplicationLaunchDate: .distantPast
            )
            XCTFail("Expected the missing state database to be reported")
        } catch ThreadRepositoryError.missingDatabase(let databaseURL) {
            XCTAssertEqual(databaseURL, missingDatabaseURL)
        }
    }
}
