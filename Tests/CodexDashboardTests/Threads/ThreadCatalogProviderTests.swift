import XCTest

@testable import CodexDashboard

final class CodexThreadCatalogProviderTests: XCTestCase {
    func testLiveCatalogWhenEnabled() async throws {
        guard ProcessInfo.processInfo.environment["CODEX_DASHBOARD_LIVE_TEST"] == "1" else {
            throw XCTSkip("Set CODEX_DASHBOARD_LIVE_TEST=1 to read the local Codex thread catalog.")
        }

        let catalog = try await CodexThreadCatalogProvider().loadCatalog(
            workingTreeStatuses: [:],
            codexLaunchDate: .distantPast
        )
        XCTAssertFalse(catalog.threads.isEmpty)
        XCTAssertGreaterThanOrEqual(catalog.totalThreadCount, catalog.threads.count)
        XCTAssertTrue(catalog.threads.contains { $0.runState == .running })
    }

    func testLoadsAndClassifiesThreads() async throws {
        let now = Int64(Date().timeIntervalSince1970)
        let stateDatabaseURL = try CodexTestFixtures.makeStateDatabase(now: now, testCase: self)
        let catalog = try await CodexThreadCatalogProvider(
            stateDatabaseURL: stateDatabaseURL
        ).loadCatalog(workingTreeStatuses: [:], codexLaunchDate: .distantPast)

        XCTAssertEqual(catalog.totalThreadCount, 3)
        XCTAssertEqual(catalog.threads.map(\.id), ["running", "updated", "idle"])
        XCTAssertEqual(catalog.threads.map(\.runState), [.running, .idle, .idle])
        XCTAssertEqual(catalog.threads.first?.title, "Running thread")
        XCTAssertEqual(catalog.threads.first?.projectName, "running")
        XCTAssertEqual(catalog.threads.first?.projectPath, "/tmp/running")
        XCTAssertEqual(catalog.threads.first?.recencyTimestamp, now - 300)
        XCTAssertEqual(catalog.threads.first?.workingTreeStatus, .notRepository)
        XCTAssertTrue(catalog.threads.first?.isPinned == true)
        XCTAssertEqual(catalog.threads[1].title, "Renamed thread")
        XCTAssertEqual(catalog.threads[1].recencyTimestamp, now - 600)
    }

    func testOrdersThreadsByFinalResponseInsteadOfDatabaseActivity() async throws {
        let now = Int64(Date().timeIntervalSince1970)
        let stateDatabaseURL = try CodexTestFixtures.makeStateDatabase(
            now: now,
            runningFinalResponseAtUnixSeconds: now - 1_200,
            testCase: self
        )
        let catalog = try await CodexThreadCatalogProvider(
            stateDatabaseURL: stateDatabaseURL
        ).loadCatalog(workingTreeStatuses: [:], codexLaunchDate: .distantPast)

        XCTAssertEqual(catalog.threads.map(\.id), ["updated", "running", "idle"])
        XCTAssertEqual(catalog.threads[1].runState, .running)
        XCTAssertEqual(catalog.threads[1].recencyTimestamp, now - 1_200)
    }

    func testReportsFullCountWhenInitialThreadRowsAreLimited() async throws {
        let now = Int64(Date().timeIntervalSince1970)
        let stateDatabaseURL = try CodexTestFixtures.makeStateDatabase(
            now: now,
            additionalThreadCount: 60,
            testCase: self
        )
        let catalog = try await CodexThreadCatalogProvider(
            stateDatabaseURL: stateDatabaseURL
        ).loadCatalog(workingTreeStatuses: [:], codexLaunchDate: .distantPast)

        XCTAssertEqual(catalog.threads.count, 60)
        XCTAssertEqual(catalog.totalThreadCount, 63)
    }

    func testInitialThreadLimitUsesStableRecencyInsteadOfTransientActivity() async throws {
        let now = Int64(Date().timeIntervalSince1970)
        let stateDatabaseURL = try CodexTestFixtures.makeStateDatabase(
            now: now,
            additionalThreadCount: 60,
            testCase: self
        )
        let update = try await Subprocess.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/sqlite3"),
            arguments: [
                stateDatabaseURL.path,
                "UPDATE threads SET updated_at = \(now + 10_000), recency_at_ms = 0 WHERE id = 'running';",
            ],
            timeout: 3
        )
        XCTAssertEqual(update.terminationStatus, 0)

        let catalog = try await CodexThreadCatalogProvider(
            stateDatabaseURL: stateDatabaseURL
        ).loadCatalog(workingTreeStatuses: [:], codexLaunchDate: .distantPast)

        XCTAssertEqual(Set(catalog.threads.map(\.id)), Set((0..<60).map { "extra-\($0)" }))
        XCTAssertFalse(catalog.threads.contains { $0.id == "running" })
    }

    func testReportsMissingStateDatabase() async throws {
        let missingDatabaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-dashboard-missing-state-\(UUID().uuidString).sqlite")
        let provider = CodexThreadCatalogProvider(stateDatabaseURL: missingDatabaseURL)
        do {
            _ = try await provider.loadCatalog(
                workingTreeStatuses: [:],
                codexLaunchDate: .distantPast
            )
            XCTFail("Expected the missing state database to be reported")
        } catch ThreadCatalogError.missingDatabase(let databaseURL) {
            XCTAssertEqual(databaseURL, missingDatabaseURL)
        }
    }

    func testReloadsStoredThreadsWhenDatabaseChanges() async throws {
        let now = Int64(Date().timeIntervalSince1970)
        let stateDatabaseURL = try CodexTestFixtures.makeStateDatabase(now: now, testCase: self)
        let provider = CodexThreadCatalogProvider(stateDatabaseURL: stateDatabaseURL)

        let initial = try await provider.loadCatalog(
            workingTreeStatuses: [:],
            codexLaunchDate: .distantPast
        )
        XCTAssertEqual(initial.threads.first { $0.id == "updated" }?.title, "Renamed thread")

        try await Task.sleep(for: .milliseconds(10))
        let update = try await Subprocess.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/sqlite3"),
            arguments: [stateDatabaseURL.path, "UPDATE threads SET name = 'Fresh title' WHERE id = 'updated';"],
            timeout: 3
        )
        XCTAssertEqual(update.terminationStatus, 0)

        let refreshed = try await provider.loadCatalog(
            workingTreeStatuses: [:],
            codexLaunchDate: .distantPast
        )
        XCTAssertEqual(refreshed.threads.first { $0.id == "updated" }?.title, "Fresh title")
    }
}
