import Foundation
import XCTest

@testable import CodexDashboard

@MainActor
extension AppCoordinatorTests {
    func testNewTaskCompletionForegroundsCodexAfterInitialSnapshot() async {
        let started = ThreadLifecycleEvent(kind: .started, timestamp: Date().addingTimeInterval(-2))
        let completed = ThreadLifecycleEvent(kind: .completed, timestamp: Date().addingTimeInterval(-1))
        let provider = SequencedCatalogProvider(catalogs: [
            ThreadCatalog(
                threads: [.fixture(id: "thread-1", runState: .running, latestLifecycleEvent: started)],
                totalThreadCount: 1
            ),
            ThreadCatalog(
                threads: [.fixture(id: "thread-1", latestLifecycleEvent: completed)],
                totalThreadCount: 1
            ),
        ])
        let foregrounder = RecordingCodexForegrounder()
        let runtime = StubDashboardRuntime()
        let coordinator = makeAppCoordinator(
            catalogProvider: provider,
            workingTreeStatusProvider: StubWorkingTreeStatusProvider(),
            unreadThreadIDProvider: StubUnreadIDProvider(unreadThreadIDs: []),
            observeFileChanges: false,
            codexForegrounder: foregrounder,
            runtimeFactory: { runtime }
        )

        await coordinator.synchronizeDashboard()
        XCTAssertEqual(foregrounder.callCount, 0)
        await coordinator.synchronizeDashboard()

        XCTAssertEqual(foregrounder.callCount, 1)
        XCTAssertEqual(runtime.openedThreadIDs, ["thread-1"])
    }

    func testTaskCompletionImmediatelyRefreshesAccountUsage() async throws {
        let started = ThreadLifecycleEvent(kind: .started, timestamp: Date().addingTimeInterval(-2))
        let completed = ThreadLifecycleEvent(kind: .completed, timestamp: Date().addingTimeInterval(-1))
        let catalogProvider = SequencedCatalogProvider(catalogs: [
            ThreadCatalog(
                threads: [.fixture(runState: .running, latestLifecycleEvent: started)],
                totalThreadCount: 1
            ),
            ThreadCatalog(
                threads: [.fixture(latestLifecycleEvent: completed)],
                totalThreadCount: 1
            ),
        ])
        let usageProvider = RecordingAccountUsageProvider()
        let coordinator = makeAppCoordinator(
            catalogProvider: catalogProvider,
            workingTreeStatusProvider: StubWorkingTreeStatusProvider(),
            unreadThreadIDProvider: StubUnreadIDProvider(unreadThreadIDs: []),
            observeFileChanges: false,
            accountUsageProvider: usageProvider,
            runtimeFactory: { StubDashboardRuntime(codexIsRunning: true) }
        )

        await coordinator.synchronizeDashboard()
        await coordinator.synchronizeDashboard()
        try await waitUntil { await usageProvider.count() == 1 }

        let requestCount = await usageProvider.count()
        XCTAssertEqual(requestCount, 1)
    }

    func testTaskCompletionDoesNotStealFocusWhileTheUserIsTyping() async {
        let started = ThreadLifecycleEvent(kind: .started, timestamp: Date().addingTimeInterval(-2))
        let completed = ThreadLifecycleEvent(kind: .completed, timestamp: Date().addingTimeInterval(-1))
        let provider = SequencedCatalogProvider(catalogs: [
            ThreadCatalog(
                threads: [.fixture(id: "thread-1", runState: .running, latestLifecycleEvent: started)],
                totalThreadCount: 1
            ),
            ThreadCatalog(
                threads: [.fixture(id: "thread-1", latestLifecycleEvent: completed)],
                totalThreadCount: 1
            ),
        ])
        let foregrounder = RecordingCodexForegrounder()
        let runtime = StubDashboardRuntime()
        let coordinator = makeAppCoordinator(
            catalogProvider: provider,
            workingTreeStatusProvider: StubWorkingTreeStatusProvider(),
            unreadThreadIDProvider: StubUnreadIDProvider(unreadThreadIDs: []),
            observeFileChanges: false,
            codexForegrounder: foregrounder,
            typingActivityDetector: StubTypingActivityDetector(isUserTyping: true),
            runtimeFactory: { runtime }
        )

        await coordinator.synchronizeDashboard()
        await coordinator.synchronizeDashboard()

        XCTAssertEqual(foregrounder.callCount, 0)
        XCTAssertTrue(runtime.openedThreadIDs.isEmpty)
    }

    func testNewestSimultaneousCompletionIsOpened() async {
        let startedAt = Date().addingTimeInterval(-3)
        let olderCompletion = ThreadLifecycleEvent(kind: .completed, timestamp: startedAt.addingTimeInterval(1))
        let newerCompletion = ThreadLifecycleEvent(kind: .completed, timestamp: startedAt.addingTimeInterval(2))
        let provider = SequencedCatalogProvider(catalogs: [
            ThreadCatalog(
                threads: [
                    .fixture(
                        id: "older",
                        runState: .running,
                        latestLifecycleEvent: ThreadLifecycleEvent(kind: .started, timestamp: startedAt)
                    ),
                    .fixture(
                        id: "newer",
                        runState: .running,
                        latestLifecycleEvent: ThreadLifecycleEvent(kind: .started, timestamp: startedAt)
                    ),
                ],
                totalThreadCount: 2
            ),
            ThreadCatalog(
                threads: [
                    .fixture(id: "older", latestLifecycleEvent: olderCompletion),
                    .fixture(id: "newer", latestLifecycleEvent: newerCompletion),
                ],
                totalThreadCount: 2
            ),
        ])
        let foregrounder = RecordingCodexForegrounder()
        let runtime = StubDashboardRuntime()
        let coordinator = makeAppCoordinator(
            catalogProvider: provider,
            workingTreeStatusProvider: StubWorkingTreeStatusProvider(),
            unreadThreadIDProvider: StubUnreadIDProvider(unreadThreadIDs: []),
            observeFileChanges: false,
            codexForegrounder: foregrounder,
            runtimeFactory: { runtime }
        )

        await coordinator.synchronizeDashboard()
        await coordinator.synchronizeDashboard()

        XCTAssertEqual(foregrounder.callCount, 1)
        XCTAssertEqual(runtime.openedThreadIDs, ["newer"])
    }

    func testInitialCompletedSnapshotDoesNotForegroundCodex() async {
        let foregrounder = RecordingCodexForegrounder()
        let completed = ThreadLifecycleEvent(kind: .completed, timestamp: .now)
        let coordinator = makeAppCoordinator(
            catalogProvider: StubCatalogProvider(
                catalog: ThreadCatalog(
                    threads: [.fixture(latestLifecycleEvent: completed)],
                    totalThreadCount: 1
                )
            ),
            workingTreeStatusProvider: StubWorkingTreeStatusProvider(),
            unreadThreadIDProvider: StubUnreadIDProvider(unreadThreadIDs: []),
            observeFileChanges: false,
            codexForegrounder: foregrounder,
            runtimeFactory: { StubDashboardRuntime() }
        )

        await coordinator.synchronizeDashboard()

        XCTAssertEqual(foregrounder.callCount, 0)
    }

    func testAbortedTaskDoesNotForegroundCodex() async {
        let started = ThreadLifecycleEvent(kind: .started, timestamp: Date().addingTimeInterval(-2))
        let aborted = ThreadLifecycleEvent(kind: .aborted, timestamp: Date().addingTimeInterval(-1))
        let provider = SequencedCatalogProvider(catalogs: [
            ThreadCatalog(
                threads: [.fixture(runState: .running, latestLifecycleEvent: started)],
                totalThreadCount: 1
            ),
            ThreadCatalog(
                threads: [.fixture(latestLifecycleEvent: aborted)],
                totalThreadCount: 1
            ),
        ])
        let foregrounder = RecordingCodexForegrounder()
        let coordinator = makeAppCoordinator(
            catalogProvider: provider,
            workingTreeStatusProvider: StubWorkingTreeStatusProvider(),
            unreadThreadIDProvider: StubUnreadIDProvider(unreadThreadIDs: []),
            observeFileChanges: false,
            codexForegrounder: foregrounder,
            runtimeFactory: { StubDashboardRuntime() }
        )

        await coordinator.synchronizeDashboard()
        await coordinator.synchronizeDashboard()

        XCTAssertEqual(foregrounder.callCount, 0)
    }

    func testForegroundPreferencePersistsAndSuppressesCompletionActivation() async throws {
        let suiteName = "AppCoordinatorForegroundTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let started = ThreadLifecycleEvent(kind: .started, timestamp: Date().addingTimeInterval(-2))
        let completed = ThreadLifecycleEvent(kind: .completed, timestamp: Date().addingTimeInterval(-1))
        let provider = SequencedCatalogProvider(catalogs: [
            ThreadCatalog(
                threads: [.fixture(runState: .running, latestLifecycleEvent: started)],
                totalThreadCount: 1
            ),
            ThreadCatalog(
                threads: [.fixture(latestLifecycleEvent: completed)],
                totalThreadCount: 1
            ),
        ])
        let foregrounder = RecordingCodexForegrounder()
        let coordinator = makeAppCoordinator(
            catalogProvider: provider,
            workingTreeStatusProvider: StubWorkingTreeStatusProvider(),
            unreadThreadIDProvider: StubUnreadIDProvider(unreadThreadIDs: []),
            compatibilityChecker: StubCompatibilityChecker(checks: []),
            userDefaults: defaults,
            observeFileChanges: false,
            codexForegrounder: foregrounder,
            runtimeFactory: { StubDashboardRuntime() }
        )
        await coordinator.synchronizeDashboard()

        coordinator.foregroundOnTaskCompletion = false
        await coordinator.synchronizeDashboard()

        XCTAssertFalse(defaults.bool(forKey: AppCoordinator.foregroundOnTaskCompletionKey))
        XCTAssertEqual(foregrounder.callCount, 0)
    }

}
