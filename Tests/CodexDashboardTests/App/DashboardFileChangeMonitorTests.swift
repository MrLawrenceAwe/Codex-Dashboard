import Foundation
import XCTest

@testable import CodexDashboard

@MainActor
final class DashboardFileChangeMonitorTests: XCTestCase {
    func testFileAndProjectChangesTriggerTargetedRefreshes() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dashboard-file-monitor-\(UUID().uuidString)", isDirectory: true)
        let catalogDirectory = root.appendingPathComponent("catalog", isDirectory: true)
        let unreadDirectory = root.appendingPathComponent("unread", isDirectory: true)
        let projectDirectory = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: catalogDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: unreadDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: projectDirectory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        let monitor = DashboardFileChangeMonitor()
        var catalogRefreshes = 0
        var unreadRefreshes = 0
        var workingTreeRefreshes = 0
        monitor.start(
            catalogURL: catalogDirectory.appendingPathComponent("state.sqlite"),
            unreadStateURL: unreadDirectory.appendingPathComponent("state.json"),
            refreshCatalog: { catalogRefreshes += 1 },
            refreshUnread: { unreadRefreshes += 1 },
            refreshWorkingTrees: { workingTreeRefreshes += 1 }
        )
        monitor.updateProjectPaths([projectDirectory.path])
        defer { monitor.stop() }

        try Data("catalog".utf8).write(to: catalogDirectory.appendingPathComponent("state.sqlite"))
        try Data("unread".utf8).write(to: unreadDirectory.appendingPathComponent("state.json"))
        try Data("change".utf8).write(to: projectDirectory.appendingPathComponent("new-file"))

        try await waitUntil {
            catalogRefreshes > 0 && unreadRefreshes > 0 && workingTreeRefreshes > 0
        }
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        condition: () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(condition())
    }
}
