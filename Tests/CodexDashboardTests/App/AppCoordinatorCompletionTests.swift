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
            runtimeFactory: { _ in runtime }
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
            runtimeFactory: { _ in StubDashboardRuntime(codexIsRunning: true) }
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
            runtimeFactory: { _ in runtime }
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
            runtimeFactory: { _ in runtime }
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
            runtimeFactory: { _ in StubDashboardRuntime() }
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
            runtimeFactory: { _ in StubDashboardRuntime() }
        )

        await coordinator.synchronizeDashboard()
        await coordinator.synchronizeDashboard()

        XCTAssertEqual(foregrounder.callCount, 0)
    }

    func testSilentPreferencePersistsAndSuppressesCompletionActivation() async throws {
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
            runtimeFactory: { _ in StubDashboardRuntime() }
        )
        await coordinator.synchronizeDashboard()

        await coordinator.selectCompletionBehavior(.silent)
        await coordinator.synchronizeDashboard()

        XCTAssertEqual(defaults.string(forKey: AppCoordinator.completionBehaviorKey), "silent")
        XCTAssertEqual(foregrounder.callCount, 0)
    }

}

@MainActor
private final class RecordingCompletionNotifier: TaskCompletionNotifying {
    var batches: [[TaskCompletion]] = []
    var notice: String?
    var prepareCount = 0
    func prepare() async -> String? { prepareCount += 1; return notice }
    func notify(completions: [TaskCompletion]) async -> String? {
        batches.append(completions)
        return notice
    }
}

@MainActor
extension AppCoordinatorTests {
    func testInboxPersistsAllCompletionsAndDismissalsWithoutReplayingSnapshots() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        let runtime = StubDashboardRuntime(maintainsDashboard: true)
        let coordinator = makeAppCoordinator(userDefaults: defaults, runtimeFactory: { _ in runtime })
        let now = Date()
        let started = ThreadLifecycleEvent(kind: .started, timestamp: now)
        _ = coordinator.recordCompletions(in: [
            .fixture(id: "one", latestLifecycleEvent: started),
            .fixture(id: "two", latestLifecycleEvent: started),
        ])
        let completed: [ThreadSummary] = [
            .fixture(id: "one", latestLifecycleEvent: .init(kind: .completed, timestamp: now.addingTimeInterval(1))),
            .fixture(id: "two", latestLifecycleEvent: .init(kind: .completed, timestamp: now.addingTimeInterval(2))),
        ]
        XCTAssertEqual(coordinator.recordCompletions(in: completed).count, 2)
        XCTAssertEqual(coordinator.completionInbox.map(\.id), ["two", "one"])

        await coordinator.openCompletedTask("one")
        XCTAssertEqual(runtime.openedThreadIDs, ["one"])
        XCTAssertEqual(runtime.keptDashboardOpen, [false])
        XCTAssertEqual(coordinator.completionInbox.count, 2, "Opening does not dismiss a completion")

        coordinator.dismissCompletion("one")
        XCTAssertTrue(coordinator.recordCompletions(in: completed).isEmpty)
        let restored = makeAppCoordinator(userDefaults: defaults)
        XCTAssertEqual(restored.completionInbox.map(\.id), ["two"])
        XCTAssertTrue(restored.recordCompletions(in: completed).isEmpty)
        restored.dismissAllCompletions()
        XCTAssertTrue(makeAppCoordinator(userDefaults: defaults).completionInbox.isEmpty)
    }

    func testLaterCompletionUpdatesExistingInboxRowAndReturnsAfterDismissal() {
        let coordinator = makeAppCoordinator()
        let now = Date()
        _ = coordinator.recordCompletions(in: [.fixture(latestLifecycleEvent: .init(kind: .started, timestamp: now))])
        for seconds in [1.0, 2.0] {
            _ = coordinator.recordCompletions(in: [.fixture(latestLifecycleEvent: .init(kind: .completed, timestamp: now.addingTimeInterval(seconds)))])
        }
        XCTAssertEqual(coordinator.completionInbox.count, 1)
        XCTAssertEqual(coordinator.completionInbox.first?.completedAt, now.addingTimeInterval(2))
        coordinator.dismissAllCompletions()
        _ = coordinator.recordCompletions(in: [.fixture(latestLifecycleEvent: .init(kind: .completed, timestamp: now.addingTimeInterval(3)))])
        XCTAssertEqual(coordinator.completionInbox.count, 1)
    }

    func testNotificationModeBatchesCompletionsWithoutStealingFocus() async {
        let now = Date()
        let provider = SequencedCatalogProvider(catalogs: [
            ThreadCatalog(threads: [
                .fixture(id: "one", latestLifecycleEvent: .init(kind: .started, timestamp: now)),
                .fixture(id: "two", latestLifecycleEvent: .init(kind: .started, timestamp: now)),
            ], totalThreadCount: 2),
            ThreadCatalog(threads: [
                .fixture(id: "one", latestLifecycleEvent: .init(kind: .completed, timestamp: now.addingTimeInterval(1))),
                .fixture(id: "two", latestLifecycleEvent: .init(kind: .completed, timestamp: now.addingTimeInterval(2))),
            ], totalThreadCount: 2),
        ])
        let notifier = RecordingCompletionNotifier()
        let foregrounder = RecordingCodexForegrounder()
        let runtime = StubDashboardRuntime()
        let coordinator = makeAppCoordinator(
            catalogProvider: provider, codexForegrounder: foregrounder,
            completionNotifier: notifier, runtimeFactory: { _ in runtime }
        )
        await coordinator.selectCompletionBehavior(.notification)
        XCTAssertEqual(notifier.prepareCount, 1)
        await coordinator.synchronizeDashboard()
        await coordinator.synchronizeDashboard()
        await coordinator.synchronizeDashboard()
        XCTAssertEqual(notifier.batches.count, 1)
        XCTAssertEqual(notifier.batches.first?.map(\.id), ["two", "one"])
        XCTAssertEqual(coordinator.completionInbox.count, 2)
        XCTAssertEqual(foregrounder.callCount, 0)
        XCTAssertTrue(runtime.openedThreadIDs.isEmpty)
    }

    func testNotificationDenialIsVisibleAndSilentModeClearsTheNotice() async {
        let notifier = RecordingCompletionNotifier()
        notifier.notice = "Notifications are off"
        let coordinator = makeAppCoordinator(completionNotifier: notifier)
        await coordinator.selectCompletionBehavior(.notification)
        XCTAssertEqual(coordinator.completionNotificationNotice, "Notifications are off")
        await coordinator.selectCompletionBehavior(.silent)
        XCTAssertNil(coordinator.completionNotificationNotice)
        XCTAssertEqual(coordinator.completionBehavior, .silent)
    }
}

@MainActor
extension AppCoordinatorTests {
    func testOpeningCompletionWhileDisconnectedShowsNotice() async {
        let foregrounder = RecordingCodexForegrounder()
        let coordinator = makeAppCoordinator(codexForegrounder: foregrounder)
        await coordinator.openCompletedTask("one")
        XCTAssertNotNil(coordinator.completionInboxNotice)
        XCTAssertEqual(foregrounder.callCount, 0)
    }
}
