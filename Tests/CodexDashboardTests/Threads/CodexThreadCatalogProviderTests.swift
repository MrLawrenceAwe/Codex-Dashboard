import XCTest

@testable import CodexDashboard

final class CodexThreadCatalogProviderTests: XCTestCase {
    func testEmptyCatalogReturnsEmptySnapshotAfterArchivingAllThreads() async throws {
        let url = try CodexTestFixtures.makeStateDatabase(now: 2_000_000_000, testCase: self)
        let provider = CodexThreadCatalogProvider(stateDatabaseURL: url)
        let initial = try await provider.loadCatalog(codexLaunchDate: .distantPast, requiredThreadIDs: [])
        XCTAssertFalse(initial.threads.isEmpty)

        for sql in ["UPDATE threads SET archived = 1;", "DELETE FROM threads;"] {
            let result = try await Subprocess.run(
                executableURL: URL(fileURLWithPath: "/usr/bin/sqlite3"),
                arguments: [url.path, sql], timeout: 3
            )
            XCTAssertEqual(result.terminationStatus, 0)
            let catalog = try await provider.loadCatalog(codexLaunchDate: .distantPast, requiredThreadIDs: [])
            XCTAssertEqual(catalog.threads.count, 0)
            XCTAssertEqual(catalog.totalThreadCount, 0)
        }
    }

    func testRunningThreadSurvivesInspectionAndCatalogLimits() async throws {
        let now: Int64 = 2_000_000_000
        let url = try CodexTestFixtures.makeStateDatabase(now: now, additionalThreadCount: 81, testCase: self)
        let result = try await Subprocess.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/sqlite3"),
            arguments: [url.path, "UPDATE threads SET recency_at_ms = 2000000000000 WHERE id LIKE 'extra-%';"],
            timeout: 3
        )
        XCTAssertEqual(result.terminationStatus, 0)
        let provider = CodexThreadCatalogProvider(stateDatabaseURL: url, loadedThreadLimit: 25)
        let bounded = try await provider.loadCatalog(codexLaunchDate: nil, requiredThreadIDs: [])
        XCTAssertEqual(bounded.threads.count, 25)

        // A launch-date change must invalidate the cached query, even without a database write.
        let catalog = try await provider.loadCatalog(codexLaunchDate: .distantPast, requiredThreadIDs: [])
        XCTAssertEqual(catalog.threads.first { $0.id == "running" }?.runState, .running)
        let afterRestart = try await provider.loadCatalog(
            codexLaunchDate: Date(timeIntervalSince1970: TimeInterval(now + 1)), requiredThreadIDs: []
        )
        XCTAssertEqual(afterRestart.threads.count, 25)
    }

    func testLiveCatalogWhenEnabled() async throws {
        guard ProcessInfo.processInfo.environment["CODEX_DASHBOARD_LIVE_TEST"] == "1" else {
            throw XCTSkip("Set CODEX_DASHBOARD_LIVE_TEST=1 to read the local Codex thread catalog.")
        }

        let catalog = try await CodexThreadCatalogProvider().loadCatalog(
            codexLaunchDate: Date().addingTimeInterval(-24 * 60 * 60),
            requiredThreadIDs: []
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
        ).loadCatalog(codexLaunchDate: .distantPast, requiredThreadIDs: [])

        XCTAssertEqual(catalog.totalThreadCount, 3)
        XCTAssertEqual(catalog.threads.map(\.id), ["running", "updated", "idle"])
        XCTAssertEqual(catalog.threads.map(\.runState), [.running, .idle, .idle])
        XCTAssertEqual(catalog.threads.map { $0.latestLifecycleEvent?.kind }, [.started, .completed, .completed])
        XCTAssertEqual(catalog.threads.first?.title, "Running thread")
        XCTAssertEqual(catalog.threads.first?.projectName, "running")
        XCTAssertEqual(catalog.threads.first?.projectPath, "/tmp/running")
        XCTAssertEqual(catalog.threads.first?.recencyEpochMillis, (now - 30) * 1_000)
        XCTAssertEqual(catalog.threads.first?.workingTreeStatus, .notRepository)
        XCTAssertTrue(catalog.threads.first?.isPinned == true)
        XCTAssertEqual(catalog.threads[1].title, "Renamed thread")
        XCTAssertEqual(catalog.threads[1].recencyEpochMillis, (now - 600) * 1_000)
    }

    func testForcedHaltMarkerSurvivesApplicationRestart() async throws {
        let now = Int64(Date().timeIntervalSince1970)
        let stateDatabaseURL = try CodexTestFixtures.makeStateDatabase(
            now: now,
            runningLifecycleEvents: ["task_started", "task_complete"],
            runningTaskCompletionErrorCode: "usage_limit_exceeded",
            testCase: self
        )
        let catalog = try await CodexThreadCatalogProvider(
            stateDatabaseURL: stateDatabaseURL
        ).loadCatalog(
            codexLaunchDate: Date(timeIntervalSince1970: TimeInterval(now + 60)),
            requiredThreadIDs: []
        )

        let haltedThread = try XCTUnwrap(catalog.threads.first { $0.id == "running" })
        XCTAssertEqual(haltedThread.runState, .idle)
        XCTAssertEqual(haltedThread.latestLifecycleEvent?.kind, .forcedHalt)
    }

    func testOrdersThreadsByIndexedDatabaseRecencyWithoutScanningHistoricalResponses() async throws {
        let now = Int64(Date().timeIntervalSince1970)
        let stateDatabaseURL = try CodexTestFixtures.makeStateDatabase(
            now: now,
            runningFinalResponseAtUnixSeconds: now - 1_200,
            testCase: self
        )
        let catalog = try await CodexThreadCatalogProvider(
            stateDatabaseURL: stateDatabaseURL
        ).loadCatalog(codexLaunchDate: .distantPast, requiredThreadIDs: [])

        XCTAssertEqual(catalog.threads.map(\.id), ["running", "updated", "idle"])
        XCTAssertEqual(catalog.threads[0].runState, .running)
        XCTAssertEqual(catalog.threads[0].recencyEpochMillis, (now - 30) * 1_000)
    }

    func testPreservesMillisecondRecencyWhenThreadsShareASecond() async throws {
        let now = Int64(Date().timeIntervalSince1970)
        let stateDatabaseURL = try CodexTestFixtures.makeStateDatabase(now: now, testCase: self)
        let update = try await Subprocess.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/sqlite3"),
            arguments: [
                stateDatabaseURL.path,
                "UPDATE threads SET recency_at_ms = CASE id WHEN 'running' THEN \(now * 1_000 + 100) WHEN 'updated' THEN \(now * 1_000 + 900) ELSE recency_at_ms END;",
            ],
            timeout: 3
        )
        XCTAssertEqual(update.terminationStatus, 0)

        let catalog = try await CodexThreadCatalogProvider(
            stateDatabaseURL: stateDatabaseURL
        ).loadCatalog(codexLaunchDate: .distantPast, requiredThreadIDs: [])

        XCTAssertEqual(Array(catalog.threads.prefix(2).map(\.id)), ["updated", "running"])
        XCTAssertEqual(catalog.threads.first?.recencyEpochMillis, now * 1_000 + 900)
    }

    func testLoadsCompleteCatalogForClientSidePagingAndSearch() async throws {
        let now = Int64(Date().timeIntervalSince1970)
        let stateDatabaseURL = try CodexTestFixtures.makeStateDatabase(
            now: now,
            additionalThreadCount: 60,
            testCase: self
        )
        let catalog = try await CodexThreadCatalogProvider(
            stateDatabaseURL: stateDatabaseURL
        ).loadCatalog(codexLaunchDate: .distantPast, requiredThreadIDs: [])

        XCTAssertEqual(catalog.threads.count, 63)
        XCTAssertEqual(catalog.totalThreadCount, 63)
    }

    func testBoundsLoadedCatalogWhilePreservingTotalCount() async throws {
        let now = Int64(Date().timeIntervalSince1970)
        let stateDatabaseURL = try CodexTestFixtures.makeStateDatabase(
            now: now,
            additionalThreadCount: 60,
            testCase: self
        )
        let catalog = try await CodexThreadCatalogProvider(
            stateDatabaseURL: stateDatabaseURL,
            loadedThreadLimit: 25
        ).loadCatalog(codexLaunchDate: nil, requiredThreadIDs: [])

        XCTAssertEqual(catalog.threads.count, 25)
        XCTAssertEqual(catalog.totalThreadCount, 63)
    }

    func testIncludesRequiredThreadOutsideLoadedCatalogLimit() async throws {
        let now = Int64(Date().timeIntervalSince1970)
        let stateDatabaseURL = try CodexTestFixtures.makeStateDatabase(
            now: now,
            additionalThreadCount: 60,
            testCase: self
        )
        let provider = CodexThreadCatalogProvider(
            stateDatabaseURL: stateDatabaseURL,
            loadedThreadLimit: 25
        )

        let bounded = try await provider.loadCatalog(
            codexLaunchDate: nil,
            requiredThreadIDs: []
        )
        XCTAssertFalse(bounded.threads.contains { $0.id == "idle" })

        let includingRequired = try await provider.loadCatalog(
            codexLaunchDate: nil,
            requiredThreadIDs: ["idle"]
        )
        XCTAssertEqual(includingRequired.threads.count, 26)
        XCTAssertTrue(includingRequired.threads.contains { $0.id == "idle" })
        XCTAssertEqual(includingRequired.totalThreadCount, 63)
    }

    func testReportsMissingStateDatabase() async throws {
        let missingDatabaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-dashboard-missing-state-\(UUID().uuidString).sqlite")
        let provider = CodexThreadCatalogProvider(stateDatabaseURL: missingDatabaseURL)
        do {
            _ = try await provider.loadCatalog(
                codexLaunchDate: .distantPast,
                requiredThreadIDs: []
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
            codexLaunchDate: .distantPast,
            requiredThreadIDs: []
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
            codexLaunchDate: .distantPast,
            requiredThreadIDs: []
        )
        XCTAssertEqual(refreshed.threads.first { $0.id == "updated" }?.title, "Fresh title")
    }
}
