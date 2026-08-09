import XCTest

@testable import CodexDashboard

final class DashboardDiagnosticsTests: XCTestCase {
    func testReportUsesExplicitFallbackValues() {
        let report = DashboardDiagnostics(
            dashboardVersion: "1.2.3",
            codexVersion: "4.5.6",
            status: "Live",
            rendererTargetCount: 1,
            loadedThreadCount: 12,
            totalThreadCount: 20,
            lastRefresh: nil,
            lastCompatibilityCheck: nil,
            compatibilitySummary: "not checked",
            connectionError: nil,
            threadWarning: nil,
            promptBackupPath: "/tmp/prompts.json"
        )

        XCTAssertTrue(report.text.contains("Codex Dashboard 1.2.3"))
        XCTAssertTrue(report.text.contains("Threads: 12 loaded / 20 total"))
        XCTAssertTrue(report.text.contains("Last refresh: never"))
        XCTAssertTrue(report.text.contains("Connection error: none"))
        XCTAssertTrue(report.text.contains("Prompt backup: /tmp/prompts.json"))
    }
}
