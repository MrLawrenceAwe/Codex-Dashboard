import AppKit
import Foundation

extension AppCoordinator {
    func copyDiagnostics() {
        let shortVersion = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "development"
        let buildVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        let dashboardVersion = buildVersion.map { "\(shortVersion) (\($0))" } ?? shortVersion
        let diagnostics = DashboardDiagnostics(
            dashboardVersion: dashboardVersion,
            codexVersion: CodexConfiguration.installedVersion ?? "not found",
            status: statusPresentation.title,
            rendererTargetCount: rendererTargetCount,
            loadedThreadCount: threads.count,
            totalThreadCount: totalThreadCount,
            lastRefresh: lastSuccessfulRefresh,
            lastCompatibilityCheck: lastCompatibilityCheck,
            compatibilitySummary: compatibilityReport?.summary ?? "not checked",
            compatibilityDetails: compatibilityReport?.diagnosticLines ?? [],
            connectionError: connectionError,
            connectionNotice: connectionNotice,
            threadWarning: threadDataWarning
        )
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(diagnostics.text, forType: .string)
    }
}
