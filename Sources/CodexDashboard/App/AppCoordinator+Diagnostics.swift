import AppKit
import Foundation

extension AppCoordinator {
    func copyDiagnostics() {
        let diagnostics = DashboardDiagnostics(
            dashboardVersion: DashboardDiagnostics.versionDescription(),
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
