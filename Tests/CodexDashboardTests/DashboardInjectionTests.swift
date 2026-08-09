import XCTest

@testable import CodexDashboard

final class DashboardInjectionTests: XCTestCase {
    func testPackagedResourcesCreateMountExpression() throws {
        let injection = try DashboardInjection.load()

        XCTAssertTrue(injection.mountExpression.contains("window.__codexDashboard"))
        XCTAssertTrue(injection.mountExpression.contains("#codex-dashboard-page"))
        XCTAssertTrue(injection.mountExpression.contains("type: 'navigate-to-route'"))
        XCTAssertTrue(injection.mountExpression.contains("data-read-filter=\"unread\""))
        XCTAssertTrue(injection.mountExpression.contains("props.conversationId"))
        XCTAssertTrue(injection.healthCheckExpression.contains(injection.version))
    }

    func testPreviewUsesCurrentPayloadContract() throws {
        let previewURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("DashboardPreview/preview.js")
        let preview = try String(contentsOf: previewURL, encoding: .utf8)

        XCTAssertTrue(preview.contains("update({ threads })"))
        XCTAssertFalse(preview.contains("totalThreadCount"))
        XCTAssertTrue(preview.contains("updatedAtUnixSeconds"))
        XCTAssertTrue(preview.contains("activity: 'running'"))
    }
}
