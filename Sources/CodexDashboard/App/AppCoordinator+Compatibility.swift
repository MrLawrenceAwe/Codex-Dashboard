import Foundation

extension AppCoordinator {
    func checkCompatibility() async {
        guard !isCheckingCompatibility else { return }
        isCheckingCompatibility = true
        defer { isCheckingCompatibility = false }

        compatibilityReport = await compatibilityMonitor.check(runtime: dashboardRuntime)
        lastCompatibilityCheck = .now
    }
}
