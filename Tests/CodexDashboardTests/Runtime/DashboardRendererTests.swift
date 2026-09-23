import XCTest

@testable import CodexDashboard

actor StubRendererDevTools: DevToolsServing {
    func evaluateString(_ expression: String, in target: DevToolsTarget, timeout: Duration) -> String? { nil }

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

actor SuspendedMountDevTools: DevToolsServing {
    func evaluateString(_ expression: String, in target: DevToolsTarget, timeout: Duration) -> String? { nil }

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

actor OrderedSnapshotDevTools: DevToolsServing {
    func evaluateString(_ expression: String, in target: DevToolsTarget, timeout: Duration) -> String? { nil }

    private let target: DevToolsTarget
    private var oldSnapshotContinuation: CheckedContinuation<Void, Never>?
    private var completedSnapshots: [String] = []

    init(target: DevToolsTarget) {
        self.target = target
    }

    func mainRendererTargets() -> [DevToolsTarget] { [target] }

    func evaluateBoolean(_ expression: String, in target: DevToolsTarget) async -> Bool {
        guard expression.contains("applyThreads") else { return true }
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

actor RendererPollingDevTools: DevToolsServing {
    func evaluateString(_ expression: String, in target: DevToolsTarget, timeout: Duration) -> String? { nil }

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

actor EmptyRendererPollingDevTools: DevToolsServing {
    func evaluateString(_ expression: String, in target: DevToolsTarget, timeout: Duration) -> String? { nil }

    private var targetRequestCount = 0

    func mainRendererTargets() -> [DevToolsTarget] {
        targetRequestCount += 1
        return []
    }

    func evaluateBoolean(_ expression: String, in target: DevToolsTarget) -> Bool { true }

    func requests() -> Int { targetRequestCount }
}

actor FailingRendererDevTools: DevToolsServing {
    func evaluateString(_ expression: String, in target: DevToolsTarget, timeout: Duration) -> String? { nil }

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

actor PromptLibraryRendererDevTools: DevToolsServing {
    private let target: DevToolsTarget
    private var exportedLibrary: String
    private var pendingLibrary: String?
    private var booleanExpressions: [String] = []
    private var stringExpressions: [String] = []

    init(target: DevToolsTarget, exportedLibrary: String, pendingLibrary: String? = nil) {
        self.target = target
        self.exportedLibrary = exportedLibrary
        self.pendingLibrary = pendingLibrary
    }

    func mainRendererTargets() -> [DevToolsTarget] { [target] }

    func evaluateBoolean(_ expression: String, in target: DevToolsTarget) -> Bool {
        booleanExpressions.append(expression)
        return true
    }

    func evaluateString(_ expression: String, in target: DevToolsTarget, timeout: Duration) -> String? {
        stringExpressions.append(expression)
        if expression.contains("exportPendingPromptLibrary") { return pendingLibrary }
        return exportedLibrary
    }

    func expressions() -> [String] { booleanExpressions }

    func stringExpressionCount() -> Int { stringExpressions.count }

    func setPendingLibrary(_ library: String?) {
        pendingLibrary = library
    }
}

actor MultiTargetPromptLibraryRendererDevTools: DevToolsServing {
    private let targets: [DevToolsTarget]
    private let exportedLibrary: String
    private var pendingLibraryByTargetID: [String: String?]
    private var acknowledgements: [String] = []

    init(
        targets: [DevToolsTarget],
        exportedLibrary: String,
        pendingLibraryByTargetID: [String: String?]
    ) {
        self.targets = targets
        self.exportedLibrary = exportedLibrary
        self.pendingLibraryByTargetID = pendingLibraryByTargetID
    }

    func mainRendererTargets() -> [DevToolsTarget] { targets }

    func evaluateBoolean(_ expression: String, in target: DevToolsTarget) -> Bool {
        if expression.contains("acknowledgePendingPromptLibrary") {
            acknowledgements.append(target.id)
            pendingLibraryByTargetID[target.id] = nil
        }
        return true
    }

    func evaluateString(_ expression: String, in target: DevToolsTarget, timeout: Duration) -> String? {
        if expression.contains("exportPendingPromptLibrary") {
            return pendingLibraryByTargetID[target.id] ?? nil
        }
        return exportedLibrary
    }

    func acknowledgementTargetIDs() -> [String] { acknowledgements }

    func pendingLibrary(for targetID: String) -> String? { pendingLibraryByTargetID[targetID] ?? nil }
}

actor AccountPopoverRendererDevTools: DevToolsServing {
    private let target: DevToolsTarget
    private let action: String?

    init(target: DevToolsTarget, action: String?) {
        self.target = target
        self.action = action
    }

    func mainRendererTargets() -> [DevToolsTarget] { [target] }

    func evaluateBoolean(_ expression: String, in target: DevToolsTarget) -> Bool { true }

    func evaluateString(_ expression: String, in target: DevToolsTarget, timeout: Duration) -> String? {
        action
    }
}

@MainActor
final class DashboardRendererTests: XCTestCase {
    func testEmptyRendererTargetsAreCachedUntilRefreshDeadline() async throws {
        let devTools = EmptyRendererPollingDevTools()
        var currentDate = Date(timeIntervalSince1970: 1_000)
        let renderer = try DashboardRenderer(
            devTools: devTools,
            injectionBundle: InjectionBundle(version: "test", mountExpression: "true"),
            healthCheckInterval: 30,
            now: { currentDate }
        )

        let initialTargets = await renderer.targets()
        let cachedTargets = await renderer.targets()
        let cachedRequestCount = await devTools.requests()
        XCTAssertTrue(initialTargets.isEmpty)
        XCTAssertTrue(cachedTargets.isEmpty)
        XCTAssertEqual(cachedRequestCount, 1)

        currentDate.addTimeInterval(31)
        let refreshedTargets = await renderer.targets()
        let refreshedRequestCount = await devTools.requests()
        XCTAssertTrue(refreshedTargets.isEmpty)
        XCTAssertEqual(refreshedRequestCount, 2)
    }

    func testSnapshotDeliveryEmbedsThreadPayloadOnce() throws {
        let marker = "unique-snapshot-payload-marker"
        let snapshot = DashboardSnapshot(threads: [.fixture(title: marker)])

        let expression = try RendererScript.deliverThreads(snapshot.threads)

        XCTAssertEqual(expression.components(separatedBy: marker).count - 1, 1)
        XCTAssertTrue(expression.contains("applyThreads"))
    }

    func testConsumesAccountPopoverActionFromRenderer() async throws {
        let accountID = UUID()
        let target = DevToolsTarget(
            id: "main",
            type: "page",
            url: "app://-/index.html",
            webSocketURL: "ws://127.0.0.1/main"
        )
        let devTools = AccountPopoverRendererDevTools(
            target: target,
            action: "{\"kind\":\"updateUsage\",\"accountID\":\"\(accountID.uuidString)\"}"
        )
        let renderer = try DashboardRenderer(
            devTools: devTools,
            injectionBundle: InjectionBundle(version: "test", mountExpression: "true")
        )

        let result = await renderer.waitForAccountPopoverAction()

        XCTAssertEqual(
            result,
            .action(AccountPopoverAction(kind: .updateUsage, accountID: accountID))
        )
    }

    func testAccountPopoverWaitDistinguishesTimeoutFromUnavailableRenderer() async throws {
        let target = DevToolsTarget(
            id: "main",
            type: "page",
            url: "app://-/index.html",
            webSocketURL: "ws://127.0.0.1/main"
        )
        let timedOutRenderer = try DashboardRenderer(
            devTools: AccountPopoverRendererDevTools(target: target, action: "null"),
            injectionBundle: InjectionBundle(version: "test", mountExpression: "true")
        )
        let unavailableRenderer = try DashboardRenderer(
            devTools: AccountPopoverRendererDevTools(
                target: target,
                action: RendererScript.accountPopoverUnavailable
            ),
            injectionBundle: InjectionBundle(version: "test", mountExpression: "true")
        )

        let timedOutResult = await timedOutRenderer.waitForAccountPopoverAction()
        let unavailableResult = await unavailableRenderer.waitForAccountPopoverAction()

        XCTAssertEqual(timedOutResult, .timedOut)
        XCTAssertEqual(unavailableResult, .unavailable)
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
            injectionBundle: InjectionBundle(version: "test", mountExpression: "true")
        )

        await renderer.openThread("thread/with spaces")

        let expressions = await devTools.expressions()
        let expression = try XCTUnwrap(expressions.last)
        XCTAssertTrue(expression.contains("navigate-to-route"))
        XCTAssertTrue(expression.contains("encodeURIComponent"))
        XCTAssertTrue(expression.contains("isOpen"))
        XCTAssertTrue(expression.contains("thread"))
    }

    func testDashboardSnapshotContainsOnlyDashboardFields() throws {
        let snapshot = DashboardSnapshot(threads: [
            .fixture(latestLifecycleEvent: ThreadLifecycleEvent(kind: .completed, timestamp: .now))
        ])

        let data = try JSONEncoder().encode(snapshot)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let threads = try XCTUnwrap(object["threads"] as? [[String: Any]])

        XCTAssertEqual(threads.first?["title"] as? String, "Thread")
        XCTAssertEqual(threads.first?["latestLifecycleEventKind"] as? String, "completed")
    }

    func testPreparingForRestartRestoresMaintenance() async throws {
        let renderer = try DashboardRenderer(
            devTools: StubRendererDevTools(targets: []),
            injectionBundle: InjectionBundle(version: "test", mountExpression: "true")
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
            injectionBundle: InjectionBundle(version: "test", mountExpression: "true")
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

}
