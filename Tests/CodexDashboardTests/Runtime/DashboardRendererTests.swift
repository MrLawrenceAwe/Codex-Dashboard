import XCTest

@testable import CodexDashboard

private actor StubRendererDevTools: DevToolsServing {
    private let rendererTargets: [DevToolsTarget]
    private var evaluationResult = false

    init(targets: [DevToolsTarget]) {
        rendererTargets = targets
    }

    func mainRendererTargets() -> [DevToolsTarget] {
        rendererTargets
    }

    func evaluateBoolean(_ expression: String, in target: DevToolsTarget) -> Bool {
        evaluationResult
    }

    func setEvaluationResult(_ result: Bool) {
        evaluationResult = result
    }
}

private actor SuspendedMountDevTools: DevToolsServing {
    private let target: DevToolsTarget
    private var mountContinuation: CheckedContinuation<Void, Never>?
    private var evaluatedExpressions: [String] = []

    init(target: DevToolsTarget) {
        self.target = target
    }

    func mainRendererTargets() -> [DevToolsTarget] {
        [target]
    }

    func evaluateBoolean(_ expression: String, in target: DevToolsTarget) async -> Bool {
        evaluatedExpressions.append(expression)
        if expression == "mount" {
            await withCheckedContinuation { continuation in
                mountContinuation = continuation
            }
        }
        return true
    }

    func mountHasStarted() -> Bool {
        mountContinuation != nil
    }

    func resumeMount() {
        mountContinuation?.resume()
        mountContinuation = nil
    }

    func expressions() -> [String] {
        evaluatedExpressions
    }
}

private actor OrderedSnapshotDevTools: DevToolsServing {
    private let target: DevToolsTarget
    private var oldSnapshotContinuation: CheckedContinuation<Void, Never>?
    private var completedSnapshots: [String] = []

    init(target: DevToolsTarget) {
        self.target = target
    }

    func mainRendererTargets() -> [DevToolsTarget] { [target] }

    func evaluateBoolean(_ expression: String, in target: DevToolsTarget) async -> Bool {
        guard expression.contains("applySnapshot") else { return true }
        if expression.contains("Old snapshot") {
            await withCheckedContinuation { continuation in
                oldSnapshotContinuation = continuation
            }
            completedSnapshots.append("old")
        } else if expression.contains("New snapshot") {
            completedSnapshots.append("new")
        }
        return true
    }

    func oldSnapshotHasStarted() -> Bool {
        oldSnapshotContinuation != nil
    }

    func resumeOldSnapshot() {
        oldSnapshotContinuation?.resume()
        oldSnapshotContinuation = nil
    }

    func completedSnapshotOrder() -> [String] {
        completedSnapshots
    }
}

@MainActor
final class DashboardRendererTests: XCTestCase {
    func testLiveRendererCompatibilityWhenEnabled() async throws {
        guard ProcessInfo.processInfo.environment["CODEX_DASHBOARD_LIVE_TEST"] == "1" else {
            throw XCTSkip("Set CODEX_DASHBOARD_LIVE_TEST=1 with Codex on port 47832.")
        }
        let renderer = try DashboardRenderer(
            devTools: DevToolsClient(),
            injectionPayload: DashboardInjectionPayload(version: "test", mountExpression: "true")
        )

        let checks = await renderer.compatibilityChecks()

        XCTAssertFalse(
            checks.contains { $0.status == .incompatible },
            checks.map { "\($0.title): \($0.detail)" }.joined(separator: "\n")
        )
    }

    func testCompatibilityCheckExplainsUnavailableRenderer() async throws {
        let renderer = try DashboardRenderer(
            devTools: StubRendererDevTools(targets: []),
            injectionPayload: DashboardInjectionPayload(version: "test", mountExpression: "true")
        )

        let checks = await renderer.compatibilityChecks()

        XCTAssertEqual(checks.map(\.id), ["renderer"])
        XCTAssertEqual(checks.first?.status, .unavailable)
    }

    func testCompatibilityCheckInspectsRendererCapabilities() async throws {
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
            injectionPayload: DashboardInjectionPayload(version: "test", mountExpression: "true")
        )

        let checks = await renderer.compatibilityChecks()

        XCTAssertEqual(
            checks.map(\.id),
            [
                "renderer", "sidebar-host", "thread-navigation", "sidebar-unread",
                "composer", "composer-controls", "commit-push-handoff",
            ]
        )
        XCTAssertTrue(checks.allSatisfy { $0.status == .compatible })
    }

    func testPreparingForRestartRestoresMaintenance() async throws {
        let renderer = try DashboardRenderer(
            devTools: StubRendererDevTools(targets: []),
            injectionPayload: DashboardInjectionPayload(version: "test", mountExpression: "true")
        )
        _ = try await renderer.disable()
        XCTAssertFalse(renderer.maintainsDashboard)

        renderer.prepareForRestart()

        XCTAssertTrue(renderer.maintainsDashboard)
    }

    func testFailedDisableKeepsDashboardMaintenanceEnabled() async throws {
        let target = DevToolsTarget(
            id: "main",
            type: "page",
            url: "app://-/index.html",
            webSocketURL: "ws://127.0.0.1/main"
        )
        let devTools = StubRendererDevTools(targets: [target])
        let renderer = try DashboardRenderer(
            devTools: devTools,
            injectionPayload: DashboardInjectionPayload(version: "test", mountExpression: "true")
        )

        do {
            _ = try await renderer.disable()
            XCTFail("Expected the renderer to reject dashboard removal")
        } catch DashboardError.disableFailed {
            XCTAssertTrue(renderer.maintainsDashboard)
        }

        await devTools.setEvaluationResult(true)
        let disabled = try await renderer.disable()
        XCTAssertTrue(disabled)
        XCTAssertFalse(renderer.maintainsDashboard)
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
            injectionPayload: DashboardInjectionPayload(version: "test", mountExpression: "mount")
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
            injectionPayload: DashboardInjectionPayload(version: "test", mountExpression: "mount")
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
}
