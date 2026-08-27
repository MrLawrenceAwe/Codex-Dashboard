import Foundation
import XCTest

@testable import CodexDashboard

@MainActor
extension DashboardRendererTests {
    func testAccountOnlySynchronizationDoesNotRedeliverThreads() async throws {
        let target = DevToolsTarget(
            id: "main",
            type: "page",
            url: "app://-/index.html",
            webSocketURL: "ws://127.0.0.1/main"
        )
        let devTools = StubRendererDevTools(targets: [target])
        await devTools.setEvaluationResult(true)
        let renderer = try DashboardRenderer(
            devTools: devTools,
            injectionBundle: InjectionBundle(version: "test", mountExpression: "mount")
        )
        let threads = [ThreadSummary.fixture(id: "thread-1")]

        try await renderer.synchronize(
            DashboardSnapshot(threads: threads),
            on: [target],
            forceRemount: true
        )
        try await renderer.synchronize(
            DashboardSnapshot(
                threads: threads,
                accountPopover: AccountPopoverSnapshot(
                    accounts: [],
                    activeAccountID: nil,
                    statusMessage: "Updated",
                    isBusy: false
                )
            ),
            on: [target]
        )

        let expressions = await devTools.expressions()
        XCTAssertEqual(expressions.count { $0.contains("return dashboard?.applyThreads") }, 1)
        XCTAssertEqual(expressions.count { $0.contains("applyAccountPopoverSnapshot") }, 2)
    }

    func testDisableWaitsForInFlightSynchronizationBeforeDestroyingDashboard() async throws {
        let target = DevToolsTarget(
            id: "main",
            type: "page",
            url: "app://-/index.html",
            webSocketURL: "ws://127.0.0.1/main"
        )
        let devTools = SuspendedMountDevTools(target: target)
        let renderer = try DashboardRenderer(
            devTools: devTools,
            injectionBundle: InjectionBundle(version: "test", mountExpression: "mount")
        )
        let synchronization = Task { @MainActor in
            try await renderer.synchronize(
                DashboardSnapshot(threads: []),
                on: [target],
                forceRemount: true
            )
        }
        while !(await devTools.mountHasStarted()) {
            await Task.yield()
        }

        let disable = Task { @MainActor in try await renderer.disable() }
        await Task.yield()
        await devTools.resumeMount()

        try await synchronization.value
        let disabled = try await disable.value
        XCTAssertTrue(disabled)
        let expressions = await devTools.expressions()
        XCTAssertEqual(expressions.first, "mount")
        XCTAssertTrue(expressions.last?.contains("destroy") == true)
        XCTAssertFalse(renderer.maintainsDashboard)
    }

    func testConcurrentSynchronizationsDeliverSnapshotsInRequestOrder() async throws {
        let target = DevToolsTarget(
            id: "main",
            type: "page",
            url: "app://-/index.html",
            webSocketURL: "ws://127.0.0.1/main"
        )
        let devTools = OrderedSnapshotDevTools(target: target)
        let renderer = try DashboardRenderer(
            devTools: devTools,
            injectionBundle: InjectionBundle(version: "test", mountExpression: "mount")
        )
        let oldSnapshot = DashboardSnapshot(threads: [.fixture(title: "Old snapshot")])
        let newSnapshot = DashboardSnapshot(threads: [.fixture(title: "New snapshot")])

        let oldSynchronization = Task { @MainActor in
            try await renderer.synchronize(oldSnapshot, on: [target], forceRemount: true)
        }
        while !(await devTools.oldSnapshotHasStarted()) {
            await Task.yield()
        }
        let newSynchronization = Task { @MainActor in
            try await renderer.synchronize(newSnapshot, on: [target])
        }
        await Task.yield()

        let orderWhileOldSnapshotIsSuspended = await devTools.completedSnapshotOrder()
        XCTAssertEqual(orderWhileOldSnapshotIsSuspended, [])
        await devTools.resumeOldSnapshot()
        try await oldSynchronization.value
        try await newSynchronization.value
        let completedOrder = await devTools.completedSnapshotOrder()
        XCTAssertEqual(completedOrder, ["old", "new"])
    }

    func testConcurrentSynchronizationsCoalesceQueuedSnapshotsToLatestState() async throws {
        let target = DevToolsTarget(
            id: "main",
            type: "page",
            url: "app://-/index.html",
            webSocketURL: "ws://127.0.0.1/main"
        )
        let devTools = OrderedSnapshotDevTools(target: target)
        let renderer = try DashboardRenderer(
            devTools: devTools,
            injectionBundle: InjectionBundle(version: "test", mountExpression: "mount")
        )

        let oldSynchronization = Task { @MainActor in
            try await renderer.synchronize(
                DashboardSnapshot(threads: [.fixture(title: "Old snapshot")]),
                on: [target],
                forceRemount: true
            )
        }
        while !(await devTools.oldSnapshotHasStarted()) { await Task.yield() }
        let middleSynchronization = Task { @MainActor in
            try await renderer.synchronize(
                DashboardSnapshot(threads: [.fixture(title: "Middle snapshot")]),
                on: [target]
            )
        }
        await Task.yield()
        let latestSynchronization = Task { @MainActor in
            try await renderer.synchronize(
                DashboardSnapshot(threads: [.fixture(title: "Latest snapshot")]),
                on: [target]
            )
        }
        await Task.yield()

        await devTools.resumeOldSnapshot()
        try await oldSynchronization.value
        try await middleSynchronization.value
        try await latestSynchronization.value

        let completedOrder = await devTools.completedSnapshotOrder()
        XCTAssertEqual(completedOrder, ["old", "latest"])
    }

    func testUnchangedSynchronizationThrottlesTargetAndHealthChecks() async throws {
        let target = DevToolsTarget(
            id: "main",
            type: "page",
            url: "app://-/index.html",
            webSocketURL: "ws://127.0.0.1/main"
        )
        let devTools = RendererPollingDevTools(target: target)
        var currentDate = Date(timeIntervalSince1970: 1_000)
        let renderer = try DashboardRenderer(
            devTools: devTools,
            injectionBundle: InjectionBundle(version: "test", mountExpression: "mount"),
            healthCheckInterval: 30,
            now: { currentDate }
        )
        let snapshot = DashboardSnapshot(threads: [])

        let firstTargets = await renderer.targets()
        try await renderer.synchronize(snapshot, on: firstTargets, forceRemount: true)
        let cachedTargets = await renderer.targets()
        try await renderer.synchronize(snapshot, on: cachedTargets)
        let cachedCounts = await devTools.counts()
        XCTAssertEqual(cachedCounts.targets, 1)
        XCTAssertEqual(cachedCounts.evaluations, 3)

        currentDate.addTimeInterval(31)
        let refreshedTargets = await renderer.targets()
        try await renderer.synchronize(snapshot, on: refreshedTargets)
        let refreshedCounts = await devTools.counts()
        XCTAssertEqual(refreshedCounts.targets, 2)
        XCTAssertEqual(refreshedCounts.evaluations, 4)
    }

    func testFailedSynchronizationInvalidatesCachedTargets() async throws {
        let staleTarget = DevToolsTarget(
            id: "stale",
            type: "page",
            url: "app://-/index.html",
            webSocketURL: "ws://127.0.0.1/stale"
        )
        let freshTarget = DevToolsTarget(
            id: "fresh",
            type: "page",
            url: "app://-/index.html",
            webSocketURL: "ws://127.0.0.1/fresh"
        )
        let devTools = FailingRendererDevTools(staleTarget: staleTarget, freshTarget: freshTarget)
        let renderer = try DashboardRenderer(
            devTools: devTools,
            injectionBundle: InjectionBundle(version: "test", mountExpression: "mount")
        )

        let initialTargets = await renderer.targets()
        do {
            try await renderer.synchronize(
                DashboardSnapshot(threads: []),
                on: initialTargets,
                forceRemount: true
            )
            XCTFail("Expected synchronization to fail")
        } catch DashboardError.invalidDevToolsResponse { }

        let refreshedTargets = await renderer.targets()
        XCTAssertEqual(refreshedTargets.map(\.id), ["fresh"])
        let requests = await devTools.requests()
        XCTAssertEqual(requests, 2)
    }
}
