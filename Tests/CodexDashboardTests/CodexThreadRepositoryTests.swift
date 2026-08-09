import XCTest

@testable import CodexDashboard

final class CodexThreadRepositoryTests: XCTestCase {
    func testLiveSnapshotWhenEnabled() async throws {
        guard ProcessInfo.processInfo.environment["CODEX_DASHBOARD_LIVE_TEST"] == "1" else {
            throw XCTSkip("Set CODEX_DASHBOARD_LIVE_TEST=1 to read the local Codex snapshot.")
        }

        let snapshot = try await CodexThreadRepository().loadSnapshot(gitStatuses: [:])
        XCTAssertFalse(snapshot.threads.isEmpty)
        XCTAssertGreaterThanOrEqual(snapshot.totalThreadCount, snapshot.threads.count)
        XCTAssertTrue(snapshot.threads.contains { $0.status == .running })
    }

    func testLoadsAndClassifiesThreads() async throws {
        let now = Int64(Date().timeIntervalSince1970)
        let stateDatabaseURL = try TestDatabaseFactory.makeStateDatabase(now: now, testCase: self)
        let snapshot = try await CodexThreadRepository(
            stateDatabaseURL: stateDatabaseURL
        ).loadSnapshot(gitStatuses: [:])

        XCTAssertEqual(snapshot.totalThreadCount, 3)
        XCTAssertEqual(snapshot.threads.map(\.id), ["running", "updated", "idle"])
        XCTAssertEqual(snapshot.threads.map(\.status), [.running, .idle, .idle])
        XCTAssertEqual(snapshot.threads.first?.title, "Running thread")
        XCTAssertEqual(snapshot.threads.first?.workspace, "running")
        XCTAssertEqual(snapshot.threads.first?.workspacePath, "/tmp/running")
        XCTAssertEqual(snapshot.threads.first?.gitStatus, .notRepository)
        XCTAssertTrue(snapshot.threads.first?.isPinned == true)
        XCTAssertEqual(snapshot.threads[1].title, "Renamed thread")
    }

    func testReportsUncommittedChangesForGitWorkspace() async throws {
        let workspaceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-dashboard-git-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: workspaceURL) }

        let git = Process()
        git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        git.arguments = ["-C", workspaceURL.path, "init", "--quiet"]
        try git.run()
        git.waitUntilExit()
        XCTAssertEqual(git.terminationStatus, 0)
        try Data("uncommitted\n".utf8).write(to: workspaceURL.appendingPathComponent("notes.txt"))

        let now = Int64(Date().timeIntervalSince1970)
        let stateDatabaseURL = try TestDatabaseFactory.makeStateDatabase(
            now: now,
            runningWorkspacePath: workspaceURL.path,
            testCase: self
        )
        let repository = CodexThreadRepository(stateDatabaseURL: stateDatabaseURL)
        let gitStatuses = await repository.loadGitStatuses(at: [workspaceURL.path])
        let snapshot = try await repository.loadSnapshot(gitStatuses: gitStatuses)

        XCTAssertEqual(snapshot.threads.first?.gitStatus, .modified)
    }

    func testRunningLifecycleDoesNotDependOnRecentLogs() async throws {
        let stateDatabaseURL = try TestDatabaseFactory.makeStateDatabase(
            now: Int64(Date().timeIntervalSince1970),
            testCase: self
        )
        let repository = CodexThreadRepository(stateDatabaseURL: stateDatabaseURL)
        let snapshot = try await repository.loadSnapshot(gitStatuses: [:])
        XCTAssertEqual(snapshot.threads.count, 3)
        XCTAssertEqual(snapshot.totalThreadCount, 3)
        XCTAssertEqual(snapshot.threads.first?.status, .running)
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
        ).loadSnapshot(gitStatuses: [:])

        XCTAssertEqual(snapshot.threads.first?.status, .idle)
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
        ).loadSnapshot(gitStatuses: [:])

        XCTAssertEqual(snapshot.threads.count, 60)
        XCTAssertEqual(snapshot.totalThreadCount, 63)
    }

    func testReportsMissingStateDatabase() async throws {
        let missingDatabaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-dashboard-missing-state-\(UUID().uuidString).sqlite")
        let repository = CodexThreadRepository(stateDatabaseURL: missingDatabaseURL)
        do {
            _ = try await repository.loadSnapshot(gitStatuses: [:])
            XCTFail("Expected the missing state database to be reported")
        } catch ThreadRepositoryError.missingDatabase(let databaseURL) {
            XCTAssertEqual(databaseURL, missingDatabaseURL)
        }
    }
}
