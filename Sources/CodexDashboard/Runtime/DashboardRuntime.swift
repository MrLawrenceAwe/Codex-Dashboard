import Foundation

enum TaskDashboardDisableOutcome {
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
        with snapshot: DashboardSnapshot,
        on targets: [DevToolsTarget],
        forceRemount: Bool
    ) async throws
    func disableTaskDashboard() async throws -> TaskDashboardDisableOutcome
    func openTaskDashboard() async
    func openThread(_ threadID: String) async
    func waitForAccountPopoverAction() async -> AccountPopoverActionWaitResult
    func synchronizeAccountPopover(_ snapshot: AccountPopoverSnapshot) async
    func preferNativePromptLibraryOnNextSynchronization()
    func rendererCompatibilityChecks() async -> [CompatibilityCheck]
}

extension DashboardRuntime {
    func preferNativePromptLibraryOnNextSynchronization() {}
    func waitForAccountPopoverAction() async -> AccountPopoverActionWaitResult { .unavailable }
    func synchronizeAccountPopover(_ snapshot: AccountPopoverSnapshot) async {}
}

@MainActor
final class LocalCodexDashboardRuntime: DashboardRuntime {
    private let codex: CodexProcessController
    private let renderer: DashboardRenderer
    private var lastObservedCodexLaunchDate: Date?

    init(
        codex: CodexProcessController = CodexProcessController(),
        renderer: DashboardRenderer? = nil,
        promptLibraryStore: PromptLibraryFileStore
    ) throws {
        self.codex = codex
        self.renderer = try renderer ?? DashboardRenderer(promptLibraryStore: promptLibraryStore)
    }

    var codexIsRunning: Bool { codex.isRunning }
    var codexLaunchDate: Date? { codex.launchDate }
    var maintainsDashboard: Bool { renderer.maintainsDashboard }

    func rendererTargets() async -> [DevToolsTarget] {
        let launchDate = codex.launchDate
        let processChanged = launchDate != lastObservedCodexLaunchDate
        lastObservedCodexLaunchDate = launchDate
        return await renderer.targets(forceRefresh: processChanged)
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
        with snapshot: DashboardSnapshot,
        on targets: [DevToolsTarget],
        forceRemount: Bool = false
    ) async throws {
        try await renderer.synchronize(snapshot, on: targets, forceRemount: forceRemount)
    }

    func disableTaskDashboard() async throws -> TaskDashboardDisableOutcome {
        try await renderer.disable() ? .rendererAvailable : .codexClosed
    }

    func openTaskDashboard() async {
        await renderer.open()
    }

    func openThread(_ threadID: String) async {
        await renderer.openThread(threadID)
    }

    func waitForAccountPopoverAction() async -> AccountPopoverActionWaitResult {
        await renderer.waitForAccountPopoverAction()
    }

    func synchronizeAccountPopover(_ snapshot: AccountPopoverSnapshot) async {
        await renderer.synchronizeAccountPopover(snapshot)
    }

    func preferNativePromptLibraryOnNextSynchronization() {
        renderer.preferNativePromptLibraryOnNextSynchronization()
    }

    func rendererCompatibilityChecks() async -> [CompatibilityCheck] {
        await renderer.compatibilityChecks()
    }
}
