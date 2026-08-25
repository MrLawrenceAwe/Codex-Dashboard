import Foundation

@MainActor
final class CompatibilityMonitor {
    private let localChecker: any LocalCompatibilityChecking
    private let versionTracker: CodexVersionCompatibilityTracker
    private let installedVersion: () -> String?

    init(
        localChecker: any LocalCompatibilityChecking,
        userDefaults: UserDefaults,
        installedVersion: @escaping () -> String?
    ) {
        self.localChecker = localChecker
        versionTracker = CodexVersionCompatibilityTracker(userDefaults: userDefaults)
        self.installedVersion = installedVersion
    }

    var updateWasDetected: Bool {
        versionTracker.updateWasDetected(currentVersion: installedVersion())
    }

    func check(runtime: (any DashboardRuntime)?) async -> CompatibilityReport {
        async let localChecks = localChecker.checkLocalContracts()
        let rendererChecks: [CompatibilityCheck]
        if let runtime {
            rendererChecks = await runtime.rendererCompatibilityChecks()
        } else {
            rendererChecks = [CompatibilityCheck(
                id: "renderer",
                title: "Renderer connection",
                status: .unavailable,
                detail: "The dashboard runtime is unavailable."
            )]
        }
        let report = CompatibilityReport(checks: await localChecks + rendererChecks)
        if rendererChecks.contains(where: { $0.id == "renderer" && $0.status == .compatible }) {
            versionTracker.markChecked(version: installedVersion())
        }
        return report
    }
}
