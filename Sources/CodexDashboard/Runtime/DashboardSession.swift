import Foundation

enum DashboardDisableOutcome {
    case codexClosed
    case rendererReady
}

@MainActor
protocol DashboardSession: AnyObject {
    var codexIsRunning: Bool { get }
    var codexLaunchDate: Date? { get }
    var maintainsDashboard: Bool { get }

    func rendererTargets() async -> [DevToolsTarget]
    func prepareForRestart()
    func restartCodex() async throws -> [DevToolsTarget]
    func synchronizeDashboard(
        with snapshot: DashboardSnapshotPayload,
        on targets: [DevToolsTarget],
        forceRemount: Bool
    ) async throws
    func disableThreadDashboard() async throws -> DashboardDisableOutcome
    func openThreadDashboard() async
    func openThread(_ threadID: String) async
    func rendererCompatibilityChecks() async -> [CompatibilityCheck]
}

@MainActor
final class LiveDashboardSession: DashboardSession {
    private let codex: CodexAppController
    private let renderer: RendererDashboardSession
    private var lastObservedCodexLaunchDate: Date?

    init(
        codex: CodexAppController = CodexAppController(),
        renderer: RendererDashboardSession? = nil
    ) throws {
        self.codex = codex
        self.renderer = try renderer ?? RendererDashboardSession(promptBackupStore: .shared)
    }

    var codexIsRunning: Bool { codex.isRunning }
    var codexLaunchDate: Date? { codex.launchDate }
    var maintainsDashboard: Bool { renderer.maintainsDashboard }

    func rendererTargets() async -> [DevToolsTarget] {
        let launchDate = codex.launchDate
        let processChanged = launchDate != lastObservedCodexLaunchDate
        lastObservedCodexLaunchDate = launchDate
        return await renderer.targets(forceRefresh: processChanged || !codex.isRunning)
    }

    func prepareForRestart() {
        lastObservedCodexLaunchDate = nil
        renderer.prepareForRestart()
    }

    func restartCodex() async throws -> [DevToolsTarget] {
        try await codex.restart()
        let deadline = ContinuousClock.now + .seconds(18)
        while true {
            let targets = await renderer.targets(forceRefresh: true)
            if !targets.isEmpty { return targets }
            guard ContinuousClock.now < deadline else {
                throw DashboardError.rendererTimedOut
            }
            try await Task.sleep(for: .milliseconds(350))
        }
    }

    func synchronizeDashboard(
        with snapshot: DashboardSnapshotPayload,
        on targets: [DevToolsTarget],
        forceRemount: Bool = false
    ) async throws {
        try await renderer.synchronize(snapshot, on: targets, forceRemount: forceRemount)
    }

    func disableThreadDashboard() async throws -> DashboardDisableOutcome {
        try await renderer.disable() ? .rendererReady : .codexClosed
    }

    func openThreadDashboard() async {
        await renderer.open()
    }

    func openThread(_ threadID: String) async {
        await renderer.openThread(threadID)
    }

    func rendererCompatibilityChecks() async -> [CompatibilityCheck] {
        await renderer.compatibilityChecks()
    }
}
