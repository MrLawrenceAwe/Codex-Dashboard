import Foundation

extension AppCoordinator {
    func checkCompatibility() async {
        guard !isCheckingCompatibility else { return }
        setCompatibilityChecking(true)
        defer { setCompatibilityChecking(false) }

        setCompatibilityReport(await compatibilityMonitor.check(runtime: dashboardRuntime))
    }
}
