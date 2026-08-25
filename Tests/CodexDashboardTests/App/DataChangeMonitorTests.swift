import Foundation
import XCTest

@testable import CodexDashboard

@MainActor
final class DataChangeMonitorTests: XCTestCase {
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

        let monitor = DataChangeMonitor()
        var catalogRefreshes = 0
        var unreadRefreshes = 0
        var workingTreeRefreshes = 0
        var refreshedProjectPaths: Set<String> = []
        monitor.start(
            catalogURL: catalogDirectory.appendingPathComponent("state.sqlite"),
            unreadStateURL: unreadDirectory.appendingPathComponent("state.json"),
            refreshCatalog: { catalogRefreshes += 1 },
            refreshUnread: { unreadRefreshes += 1 },
            refreshWorkingTrees: { paths in
                workingTreeRefreshes += 1
                refreshedProjectPaths.formUnion(paths ?? [])
            }
        )
        monitor.updateProjectPaths([projectDirectory.path])
        defer { monitor.stop() }

        try Data("catalog".utf8).write(to: catalogDirectory.appendingPathComponent("state.sqlite"))
        try Data("unread".utf8).write(to: unreadDirectory.appendingPathComponent("state.json"))
        try Data("change".utf8).write(to: projectDirectory.appendingPathComponent("new-file"))

        try await waitUntil {
            catalogRefreshes > 0 && unreadRefreshes > 0 && workingTreeRefreshes > 0
        }
        XCTAssertEqual(refreshedProjectPaths, [projectDirectory.path])
    }

    func testSharedDataDirectoryRoutesOnlyChangedFile() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dashboard-data-monitor-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let catalogURL = root.appendingPathComponent("state.sqlite")
        let unreadURL = root.appendingPathComponent("global.json")
        try Data("initial-catalog".utf8).write(to: catalogURL)
        try Data("initial-unread".utf8).write(to: unreadURL)

        let monitor = DataChangeMonitor()
        var catalogRefreshes = 0
        var unreadRefreshes = 0
        monitor.start(
            catalogURL: catalogURL,
            unreadStateURL: unreadURL,
            refreshCatalog: { catalogRefreshes += 1 },
            refreshUnread: { unreadRefreshes += 1 },
            refreshWorkingTrees: { _ in }
        )
        defer { monitor.stop() }

        try Data("updated-catalog".utf8).write(to: catalogURL)
        try await waitUntil { catalogRefreshes == 1 }
        XCTAssertEqual(unreadRefreshes, 0)

        try Data("updated-unread-state".utf8).write(to: unreadURL)
        try await waitUntil { unreadRefreshes == 1 }
        XCTAssertEqual(catalogRefreshes, 1)
    }

    func testLinkedWorktreeResolvesActualGitMetadataDirectory() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dashboard-worktree-monitor-\(UUID().uuidString)", isDirectory: true)
        let repositoryURL = root.appendingPathComponent("repository", isDirectory: true)
        let worktreeURL = root.appendingPathComponent("worktree", isDirectory: true)
        try FileManager.default.createDirectory(at: repositoryURL, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        _ = try await Subprocess.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/git"),
            arguments: ["-C", repositoryURL.path, "init", "--quiet"],
            timeout: 3
        )
        try Data("initial\n".utf8).write(to: repositoryURL.appendingPathComponent("tracked.txt"))
        _ = try await Subprocess.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/git"),
            arguments: [
                "-C", repositoryURL.path,
                "-c", "user.name=Codex Dashboard Tests",
                "-c", "user.email=tests@example.invalid",
                "add", "tracked.txt",
            ],
            timeout: 3
        )
        _ = try await Subprocess.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/git"),
            arguments: [
                "-C", repositoryURL.path,
                "-c", "user.name=Codex Dashboard Tests",
                "-c", "user.email=tests@example.invalid",
                "commit", "--quiet", "-m", "Initial",
            ],
            timeout: 3
        )
        _ = try await Subprocess.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/git"),
            arguments: ["-C", repositoryURL.path, "worktree", "add", "--quiet", worktreeURL.path],
            timeout: 3
        )

        let metadataURL = try XCTUnwrap(GitMetadataLocator.metadataURL(for: worktreeURL))
        let pointerURL = worktreeURL.appendingPathComponent(".git")

        XCTAssertNotEqual(metadataURL, pointerURL)
        XCTAssertTrue(metadataURL.path.contains("/.git/worktrees/"))
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: metadataURL.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
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
