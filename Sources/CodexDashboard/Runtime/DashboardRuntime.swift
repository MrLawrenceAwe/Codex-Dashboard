import Foundation

enum DashboardDisableOutcome {
    case codexClosed
    case rendererAvailable
}

@MainActor
protocol DashboardRuntime: AnyObject {
    var codexIsRunning: Bool { get }
    var codexLaunchDate: Date? { get }
    var maintainsDashboard: Bool { get }

    func rendererTargets() async -> [DevToolsTarget]
    func prepareForRestart()
    func restartCodex() async throws -> [DevToolsTarget]
    func synchronizeDashboard(
        with snapshot: RendererSnapshot,
        on targets: [DevToolsTarget],
        forceRemount: Bool
    ) async throws
    func disableDashboard() async throws -> DashboardDisableOutcome
    func openDashboard() async
}

@MainActor
final class DashboardRuntimeCoordinator: DashboardRuntime {
    private let codex: CodexAppController
    private let renderer: DashboardRenderer

    init(
        codex: CodexAppController = CodexAppController(),
        renderer: DashboardRenderer? = nil
    ) throws {
        self.codex = codex
        self.renderer = try renderer ?? DashboardRenderer()
    }

    var codexIsRunning: Bool { codex.isRunning }
    var codexLaunchDate: Date? { codex.launchDate }
    var maintainsDashboard: Bool { renderer.maintainsDashboard }

    func rendererTargets() async -> [DevToolsTarget] {
        await renderer.targets()
    }

    func prepareForRestart() {
        renderer.prepareForRestart()
    }

    func restartCodex() async throws -> [DevToolsTarget] {
        try await codex.restart()
        let deadline = ContinuousClock.now + .seconds(18)
        while true {
            let targets = await renderer.targets()
            if !targets.isEmpty { return targets }
            guard ContinuousClock.now < deadline else {
                throw DashboardError.rendererTimedOut
            }
            try await Task.sleep(for: .milliseconds(350))
        }
    }

    func synchronizeDashboard(
        with snapshot: RendererSnapshot,
        on targets: [DevToolsTarget],
        forceRemount: Bool = false
    ) async throws {
        try await renderer.synchronize(snapshot, on: targets, forceRemount: forceRemount)
    }

    func disableDashboard() async throws -> DashboardDisableOutcome {
        try await renderer.disable() ? .rendererAvailable : .codexClosed
    }

    func openDashboard() async {
        await renderer.open()
    }
}
