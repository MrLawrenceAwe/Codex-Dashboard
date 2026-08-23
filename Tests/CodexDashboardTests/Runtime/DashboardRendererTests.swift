import XCTest

@testable import CodexDashboard

private actor StubRendererDevTools: DevToolsServing {
    private let rendererTargets: [DevToolsTarget]
    private var evaluationResult = false
    private var evaluatedExpressions: [String] = []

    init(targets: [DevToolsTarget]) {
        rendererTargets = targets
    }

    func mainRendererTargets() -> [DevToolsTarget] {
        rendererTargets
    }

    func evaluateBoolean(_ expression: String, in target: DevToolsTarget) -> Bool {
        evaluatedExpressions.append(expression)
        return evaluationResult
    }

    func setEvaluationResult(_ result: Bool) {
        evaluationResult = result
    }

    func expressions() -> [String] {
        evaluatedExpressions
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
        } else if expression.contains("Middle snapshot") {
            completedSnapshots.append("middle")
        } else if expression.contains("Latest snapshot") {
            completedSnapshots.append("latest")
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

private actor RendererPollingDevTools: DevToolsServing {
    private let target: DevToolsTarget
    private var targetRequestCount = 0
    private var booleanEvaluationCount = 0

    init(target: DevToolsTarget) {
        self.target = target
    }

    func mainRendererTargets() -> [DevToolsTarget] {
        targetRequestCount += 1
        return [target]
    }

    func evaluateBoolean(_ expression: String, in target: DevToolsTarget) -> Bool {
        booleanEvaluationCount += 1
        return true
    }

    func counts() -> (targets: Int, evaluations: Int) {
        (targetRequestCount, booleanEvaluationCount)
    }
}

private actor FailingRendererDevTools: DevToolsServing {
    private let staleTarget: DevToolsTarget
    private let freshTarget: DevToolsTarget
    private var targetRequestCount = 0

    init(staleTarget: DevToolsTarget, freshTarget: DevToolsTarget) {
        self.staleTarget = staleTarget
        self.freshTarget = freshTarget
    }

    func mainRendererTargets() -> [DevToolsTarget] {
        targetRequestCount += 1
        return targetRequestCount == 1 ? [staleTarget] : [freshTarget]
    }

    func evaluateBoolean(_ expression: String, in target: DevToolsTarget) throws -> Bool {
        throw DashboardError.invalidDevToolsResponse
    }

    func requests() -> Int { targetRequestCount }
}

private actor PromptLibraryRendererDevTools: DevToolsServing {
    private let target: DevToolsTarget
    private var exportedLibrary: String
    private var booleanExpressions: [String] = []

    init(target: DevToolsTarget, exportedLibrary: String) {
        self.target = target
        self.exportedLibrary = exportedLibrary
    }

    func mainRendererTargets() -> [DevToolsTarget] { [target] }

    func evaluateBoolean(_ expression: String, in target: DevToolsTarget) -> Bool {
        booleanExpressions.append(expression)
        return true
    }

    func evaluateString(_ expression: String, in target: DevToolsTarget) -> String? {
        exportedLibrary
    }

    func expressions() -> [String] { booleanExpressions }
}

@MainActor
final class DashboardRendererTests: XCTestCase {
    func testPromptLibraryMigratesToNativeStoreAndExternalImportWins() async throws {
        let target = DevToolsTarget(
            id: "main",
            type: "page",
            url: "app://-/index.html",
            webSocketURL: "ws://127.0.0.1/main"
        )
        let rendererLibrary = #"{"version":3,"prompts":[{"id":"old","name":"Old","content":"Old content","scope":{"type":"global"},"preset":{"model":"gpt-future"}}],"sections":[]}"#
        let devTools = PromptLibraryRendererDevTools(target: target, exportedLibrary: rendererLibrary)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("renderer-prompts-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = PromptLibraryFileStore(documentURL: directory.appendingPathComponent("prompts.json"))
        let renderer = try DashboardRenderer(
            devTools: devTools,
            injectionPayload: DashboardInjectionResources(version: "test", mountExpression: "mount"),
            promptLibraryStore: store
        )
        let snapshot = DashboardSnapshotPayload(threads: [])

        try await renderer.synchronize(snapshot, on: [target], forceRemount: true)
        XCTAssertEqual(try store.load()?.prompts.first?.preset?.model, "gpt-future")

        let imported = PromptLibraryDocument(
            version: 3,
            prompts: [SavedPrompt(
                id: "imported",
                name: "Imported",
                content: "Imported content",
                section: "General",
                scope: SavedPromptScope(type: "global", projectPath: nil),
                preset: nil,
                usePreset: nil
            )],
            sections: ["General"]
        )
        try store.save(imported)
        try await renderer.synchronize(snapshot, on: [target])

        XCTAssertEqual(try store.load(), imported)
        let expressions = await devTools.expressions()
        XCTAssertTrue(expressions.contains { $0.contains("Imported content") })
    }

    func testOpeningThreadDispatchesItsRoute() async throws {
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
            injectionPayload: DashboardInjectionResources(version: "test", mountExpression: "true")
        )

        await renderer.openThread("thread/with spaces")

        let expressions = await devTools.expressions()
        let expression = try XCTUnwrap(expressions.last)
        XCTAssertTrue(expression.contains("navigate-to-route"))
        XCTAssertTrue(expression.contains("encodeURIComponent"))
        XCTAssertTrue(expression.contains("thread"))
    }

    func testDashboardSnapshotPayloadContainsOnlyDashboardFields() throws {
        let snapshot = DashboardSnapshotPayload(threads: [.fixture()])

        let data = try JSONEncoder().encode(snapshot)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let threads = try XCTUnwrap(object["threads"] as? [[String: Any]])

        XCTAssertEqual(threads.first?["title"] as? String, "Thread")
    }

    func testLiveRendererCompatibilityWhenEnabled() async throws {
        guard ProcessInfo.processInfo.environment["CODEX_DASHBOARD_LIVE_TEST"] == "1" else {
            throw XCTSkip("Set CODEX_DASHBOARD_LIVE_TEST=1 with Codex on port 47832.")
        }
        let renderer = try DashboardRenderer(
            devTools: DevToolsClient(),
            injectionPayload: DashboardInjectionResources(version: "test", mountExpression: "true")
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
            injectionPayload: DashboardInjectionResources(version: "test", mountExpression: "true")
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
            injectionPayload: DashboardInjectionResources(version: "test", mountExpression: "true")
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
        let expressions = await devTools.expressions()
        let composerControlsExpression = try XCTUnwrap(
            expressions.first { $0.contains("Boolean(codexUIContracts.composerAddButton())") }
        )
        XCTAssertFalse(composerControlsExpression.contains("data-codex-prompt-launcher"))
        XCTAssertTrue(
            expressions.contains { $0.contains("codexUIContracts.probeCommitOrPushControls()") }
        )
    }

    func testPreparingForRestartRestoresMaintenance() async throws {
        let renderer = try DashboardRenderer(
            devTools: StubRendererDevTools(targets: []),
            injectionPayload: DashboardInjectionResources(version: "test", mountExpression: "true")
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
            injectionPayload: DashboardInjectionResources(version: "test", mountExpression: "true")
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
            injectionPayload: DashboardInjectionResources(version: "test", mountExpression: "mount")
        )
        let synchronization = Task { @MainActor in
            try await renderer.synchronize(
                DashboardSnapshotPayload(threads: []),
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
            injectionPayload: DashboardInjectionResources(version: "test", mountExpression: "mount")
        )
        let oldSnapshot = DashboardSnapshotPayload(threads: [.fixture(title: "Old snapshot")])
        let newSnapshot = DashboardSnapshotPayload(threads: [.fixture(title: "New snapshot")])

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
            injectionPayload: DashboardInjectionResources(version: "test", mountExpression: "mount")
        )

        let oldSynchronization = Task { @MainActor in
            try await renderer.synchronize(
                DashboardSnapshotPayload(threads: [.fixture(title: "Old snapshot")]),
                on: [target],
                forceRemount: true
            )
        }
        while !(await devTools.oldSnapshotHasStarted()) { await Task.yield() }
        let middleSynchronization = Task { @MainActor in
            try await renderer.synchronize(
                DashboardSnapshotPayload(threads: [.fixture(title: "Middle snapshot")]),
                on: [target]
            )
        }
        await Task.yield()
        let latestSynchronization = Task { @MainActor in
            try await renderer.synchronize(
                DashboardSnapshotPayload(threads: [.fixture(title: "Latest snapshot")]),
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
            injectionPayload: DashboardInjectionResources(version: "test", mountExpression: "mount"),
            healthCheckInterval: 30,
            now: { currentDate }
        )
        let snapshot = DashboardSnapshotPayload(threads: [])

        let firstTargets = await renderer.targets()
        try await renderer.synchronize(snapshot, on: firstTargets, forceRemount: true)
        let cachedTargets = await renderer.targets()
        try await renderer.synchronize(snapshot, on: cachedTargets)
        let cachedCounts = await devTools.counts()
        XCTAssertEqual(cachedCounts.targets, 1)
        XCTAssertEqual(cachedCounts.evaluations, 2)

        currentDate.addTimeInterval(31)
        let refreshedTargets = await renderer.targets()
        try await renderer.synchronize(snapshot, on: refreshedTargets)
        let refreshedCounts = await devTools.counts()
        XCTAssertEqual(refreshedCounts.targets, 2)
        XCTAssertEqual(refreshedCounts.evaluations, 3)
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
            injectionPayload: DashboardInjectionResources(version: "test", mountExpression: "mount")
        )

        let initialTargets = await renderer.targets()
        do {
            try await renderer.synchronize(
                DashboardSnapshotPayload(threads: []),
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
