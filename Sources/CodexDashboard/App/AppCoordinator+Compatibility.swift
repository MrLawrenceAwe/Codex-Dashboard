import Foundation

extension AppCoordinator {
    func checkCompatibility() async {
        guard !isCheckingCompatibility else { return }
        isCheckingCompatibility = true
        defer { isCheckingCompatibility = false }

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
