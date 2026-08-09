import XCTest

@testable import CodexDashboard

final class WorkspaceGitStatusLoaderTests: XCTestCase {
    func testReportsUncommittedChanges() async throws {
        let workspaceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-dashboard-git-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: workspaceURL) }

        let git = Process()
        git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        git.arguments = ["-C", workspaceURL.path, "init", "--quiet"]
        try git.run()
        git.waitUntilExit()
        XCTAssertEqual(git.terminationStatus, 0)
        try Data("uncommitted\n".utf8).write(to: workspaceURL.appendingPathComponent("notes.txt"))

        let statuses = await WorkspaceGitStatusLoader().load(at: [workspaceURL.path])

        XCTAssertEqual(statuses[workspaceURL.path], .modified)
    }

    func testReportsNonRepository() async {
        let missingPath = "/tmp/codex-dashboard-missing-\(UUID().uuidString)"
        let statuses = await WorkspaceGitStatusLoader().load(at: [missingPath])
        XCTAssertEqual(statuses[missingPath], .notRepository)
    }
}
