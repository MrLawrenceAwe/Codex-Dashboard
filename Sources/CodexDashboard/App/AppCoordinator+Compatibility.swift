import Foundation

extension AppCoordinator {
    func checkCompatibility() async {
        if let compatibilityCheckTask {
            await compatibilityCheckTask.value
            return
        }
        isCheckingCompatibility = true
        let task = Task { await performCompatibilityCheck() }
        compatibilityCheckTask = task
        defer {
            compatibilityCheckTask = nil
            isCheckingCompatibility = false
        }
        await task.value
    }

    private func performCompatibilityCheck() async {
        let report = await compatibilityMonitor.check(runtime: dashboardRuntime)
        compatibilityReport = report
        lastCompatibilityCheck = .now

        guard compatibilityWasTriggeredByUpdate,
              !didNotifyAboutDetectedUpdate,
              report.blockingCount > 0 || report.warningCount > 0
        else { return }
        didNotifyAboutDetectedUpdate = true
        await compatibilityIssueNotifier.notify(report: report)
    }
}
