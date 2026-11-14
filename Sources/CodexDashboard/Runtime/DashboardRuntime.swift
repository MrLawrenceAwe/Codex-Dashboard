import Foundation

enum DashboardDisableOutcome: Equatable {
    case disabled
    case rendererUnavailable
}

@MainActor
protocol DashboardRuntime: AnyObject {
    var codexIsRunning: Bool { get }
    var codexLaunchDate: Date? { get }
    var maintainsDashboard: Bool { get }
    var reviewLoopThreadIDs: Set<String> { get }
    var gitControlsCompatibilityChecks: [CompatibilityCheck] { get }

    func rendererTargets() async -> [DevToolsTarget]
    func waitForReviewOperations() async
    func prepareForRestart()
    func restartCodex(activate: Bool) async throws -> [DevToolsTarget]
    func synchronizeDashboard(
        with snapshot: DashboardSnapshot,
        on targets: [DevToolsTarget],
        forceRemount: Bool
    ) async throws
    func disableIntegration() async throws -> DashboardDisableOutcome
    func openChatOverview() async
    func openThread(_ threadID: String) async
    func hasActiveSpeechInput() async -> Bool
    func pollAccountPopoverAction() async -> AccountPopoverActionPollResult
    func synchronizeAccountPopover(_ snapshot: AccountPopoverSnapshot) async
    func completeAccountPopoverAction(_ action: AccountPopoverAction, snapshot: AccountPopoverSnapshot) async
    func useStoredPromptLibraryOnNextSync()
    func flushPromptLibrary() async throws
    func rendererCompatibilityChecks() async -> [CompatibilityCheck]
}

@MainActor
final class CodexDashboardRuntime: DashboardRuntime {
    private let codex: CodexProcessController
    private let renderer: DashboardRenderer
    private var lastObservedCodexLaunchDate: Date?

    init(
        codex: CodexProcessController = CodexProcessController(),
        renderer: DashboardRenderer? = nil,
        promptLibraryStore: PromptLibraryFileStore
    ) throws {
        self.codex = codex
        self.renderer = try renderer ?? DashboardRenderer(
            promptLibraryStore: promptLibraryStore,
            reviewLoopStore: ReviewLoopFileStore(url: CodexConfiguration.reviewLoopURL)
        )
    }

    var codexIsRunning: Bool { codex.isRunning }
    var codexLaunchDate: Date? { codex.launchDate }
    var maintainsDashboard: Bool { renderer.maintainsDashboard }
    var reviewLoopThreadIDs: Set<String> { renderer.reviewLoopThreadIDs }
    var gitControlsCompatibilityChecks: [CompatibilityCheck] { renderer.gitControlsCompatibilityChecks }

    func rendererTargets() async -> [DevToolsTarget] {
        let launchDate = codex.launchDate
        let processChanged = launchDate != lastObservedCodexLaunchDate
        lastObservedCodexLaunchDate = launchDate
        return await renderer.targets(forceRefresh: processChanged)
    }

    func waitForReviewOperations() async {
        await renderer.waitForReviewOperations()
    }

    func prepareForRestart() {
        lastObservedCodexLaunchDate = nil
        renderer.prepareForRestart()
    }

    func restartCodex(activate: Bool) async throws -> [DevToolsTarget] {
        try await codex.restart(activate: activate)
        let deadline = ContinuousClock.now + .seconds(18)
        while true {
            let targets = await renderer.targets(forceRefresh: true)
            if !targets.isEmpty { return targets }
            guard ContinuousClock.now < deadline else { throw DashboardError.rendererTimedOut }
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

    func disableIntegration() async throws -> DashboardDisableOutcome {
        try await renderer.disable()
    }

    func openChatOverview() async {
        await renderer.openChatOverview()
    }

    func hasActiveSpeechInput() async -> Bool {
        await renderer.hasActiveSpeechInput()
    }

    func openThread(_ threadID: String) async {
        await renderer.openThread(threadID)
    }

    func pollAccountPopoverAction() async -> AccountPopoverActionPollResult {
        await renderer.pollAccountPopoverAction()
    }

    func synchronizeAccountPopover(_ snapshot: AccountPopoverSnapshot) async {
        await renderer.synchronizeAccountPopover(snapshot)
    }

    func completeAccountPopoverAction(_ action: AccountPopoverAction, snapshot: AccountPopoverSnapshot) async {
        await renderer.completeAccountPopoverAction(action, snapshot: snapshot)
    }

    func useStoredPromptLibraryOnNextSync() {
        renderer.useStoredPromptLibraryOnNextSync()
    }

    func flushPromptLibrary() async throws {
        guard codexIsRunning, maintainsDashboard else { return }
        try await renderer.flushPromptLibrary()
    }

    func rendererCompatibilityChecks() async -> [CompatibilityCheck] {
        await renderer.compatibilityChecks()
    }
}
