import Foundation

extension DashboardCoordinator {
    func checkCompatibility() async {
        guard !isCheckingCompatibility else { return }
        isCheckingCompatibility = true
        defer { isCheckingCompatibility = false }

        async let localChecks = compatibilityChecker.checkLocalContracts()
        let rendererChecks: [CompatibilityCheck]
        if let dashboardRuntime {
            rendererChecks = await dashboardRuntime.rendererCompatibilityChecks()
        } else {
            rendererChecks = [CompatibilityCheck(
                id: "renderer",
                title: "Renderer connection",
                status: .unavailable,
                detail: "The dashboard runtime is unavailable."
            )]
        }
        compatibilityReport = CompatibilityReport(checks: await localChecks + rendererChecks)
        lastCompatibilityCheck = .now
        if rendererChecks.contains(where: { $0.id == "renderer" && $0.status == .compatible }) {
            versionTracker.markChecked(version: installedCodexVersion())
        }
    }
}
