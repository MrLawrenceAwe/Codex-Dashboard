import Foundation

extension AppCoordinator {
    static let automaticRecoveryLimitMessage =
        "Automatic recovery stopped after 3 restart attempts. Use Restart & Enable to try again."

    /// Run outside the synchronization coalescer: restart drains that coalescer.
    func recoverDashboardIfNeeded() async {
        guard !Task.isCancelled,
              !isPerformingAction,
              !isCheckingCompatibility,
              let dashboardRuntime,
              dashboardRuntime.codexIsRunning,
              dashboardRuntime.maintainsDashboard,
              !codexForegrounder.isCodexFrontmost,
              !connectionState.dashboardIsMounted || connectionNotice != nil,
              catalogWarning == nil,
              !threads.contains(where: { $0.runState == .running }),
              compatibilityReport?.blockingCount ?? 0 == 0 else { return }
        guard automaticRestartAttempts < 3 else {
            connectionNotice = Self.automaticRecoveryLimitMessage
            return
        }
        await restartCodexAndEnableDashboard(automatically: true)
        if automaticRestartAttempts == 3 {
            connectionNotice = Self.automaticRecoveryLimitMessage
        }
    }
}
