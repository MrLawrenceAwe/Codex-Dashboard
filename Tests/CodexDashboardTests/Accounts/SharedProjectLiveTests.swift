import XCTest
@testable import CodexDashboard

@MainActor
final class SharedProjectLiveTests: XCTestCase {
    func testRunningDashboardSynchronizesProjectChangesAcrossBothWindowsWhenEnabled() async throws {
        guard ProcessInfo.processInfo.environment["CODEX_DASHBOARD_LIVE_PROJECT_SYNC"] == "1",
              let rawPort = ProcessInfo.processInfo.environment["CODEX_DASHBOARD_ACCOUNT_PORT"],
              let port = Int(rawPort),
              let rawID = ProcessInfo.processInfo.environment["CODEX_DASHBOARD_PROJECT_PROFILE"],
              let profileID = UUID(uuidString: rawID) else {
            throw XCTSkip("Opt in with CODEX_DASHBOARD_LIVE_PROJECT_SYNC=1 and CODEX_DASHBOARD_ACCOUNT_PORT.")
        }
        let main = ProjectSyncConnection(id: "main-test", home: CodexConfiguration.codexDirectory, port: { CodexConfiguration.devToolsPort })
        let other = ProjectSyncConnection(id: "other-test", home: AccountWindowProfile(accountID: profileID).codexHome, port: { port })
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("Dashboard-project-sync-test-\(UUID())")
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: path) }
        var createdID: String?
        var step = "create the temporary project"
        do {
            let data = try await main.request("project/create", ["idempotencyKey": UUID().uuidString,
                "name": "Dashboard sync verification", "roots": [["path": path.path]]])
            let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            let result = try XCTUnwrap(root["result"] as? [String: Any])
            let project = try XCTUnwrap(result["project"] as? [String: Any])
            let id = try XCTUnwrap(project["id"] as? String)
            createdID = id
            step = "show the new project in both windows"
            let replica = try await waitForProject(connection: other, path: path.path)
            try await waitForSidebar(connection: other, label: "Dashboard sync verification", present: true)
            try await waitForSidebar(connection: main, label: "Dashboard sync verification", present: true)
            step = "pin and reorder the project"
            let initialMain = try await main.snapshot()
            let initialPins = try main.pinned(in: initialMain)
            try await main.setPresentation(order: [id] + initialMain.map(\.id).filter { $0 != id },
                pinned: initialPins + [id], snapshot: initialMain)
            let pinDeadline = ContinuousClock.now + .seconds(25)
            var presentationSynced = false
            while ContinuousClock.now < pinDeadline {
                let snapshot = try await other.snapshot()
                if snapshot.first?.id == replica.id, try other.pinned(in: snapshot).contains(replica.id) {
                    presentationSynced = true; break
                }
                try await Task.sleep(for: .milliseconds(300))
            }
            guard presentationSynced else {
                throw DashboardError.synchronizationFailed("Pins and sidebar order did not reach the account window.")
            }
            step = "rename the project from the account window"
            _ = try await other.request("project/update", ["projectId": replica.id, "name": "Renamed in account window"])
            let renamed = try await waitForProject(connection: main, path: path.path, name: "Renamed in account window")
            XCTAssertEqual(renamed.id, id)
            try await waitForSidebar(connection: main, label: "Renamed in account window", present: true)
            try await waitForSidebar(connection: other, label: "Renamed in account window", present: true)
            step = "remove the project from the account window"
            _ = try await other.request("project/delete", ["projectId": replica.id])
            let deadline = ContinuousClock.now + .seconds(25)
            var removed = false
            while ContinuousClock.now < deadline {
                if try await main.snapshot().allSatisfy({ !$0.roots.contains(where: { $0.path == path.path }) }) { removed = true; break }
                try await Task.sleep(for: .milliseconds(300))
            }
            guard removed else {
                throw DashboardError.synchronizationFailed("Removal from the account window did not reach the main window.")
            }
            try await waitForSidebar(connection: main, label: "Renamed in account window", present: false)
            try await waitForSidebar(connection: other, label: "Renamed in account window", present: false)
            await main.disconnect(); await other.disconnect()
        } catch {
            if let createdID { try? await main.delete(localID: createdID) }
            if let remaining = try? await other.snapshot().first(where: { $0.roots.contains(where: { $0.path == path.path }) }) {
                try? await other.delete(localID: remaining.id)
            }
            await main.disconnect(); await other.disconnect()
            throw DashboardError.synchronizationFailed("Could not \(step): \(error.localizedDescription)")
        }
    }

    private func waitForSidebar(connection: ProjectSyncConnection, label: String, present: Bool) async throws {
        let quoted = String(decoding: try JSONEncoder().encode(label), as: UTF8.self)
        let script = """
        [...document.querySelectorAll('[data-app-action-sidebar-project-label]')]
          .some(row => row.getAttribute('data-app-action-sidebar-project-label') === \(quoted)
            && row.checkVisibility())
        """
        let deadline = ContinuousClock.now + .seconds(15)
        while ContinuousClock.now < deadline {
            if let target = await connection.client.mainRendererTargets().first,
               try await connection.client.evaluateBoolean(script, in: target) == present { return }
            try await Task.sleep(for: .milliseconds(300))
        }
        throw DashboardError.synchronizationFailed("The visible project sidebar did not reflect the change.")
    }

    private func waitForProject(connection: ProjectSyncConnection, path: String, name: String? = nil) async throws -> CodexProject {
        let deadline = ContinuousClock.now + .seconds(25)
        while ContinuousClock.now < deadline {
            if let project = try await connection.snapshot().first(where: {
                $0.roots.contains(where: { $0.path == path }) && (name == nil || $0.name == name)
            }) { return project }
            try await Task.sleep(for: .milliseconds(300))
        }
        throw DashboardError.synchronizationFailed("The project change did not reach the other window.")
    }
}
