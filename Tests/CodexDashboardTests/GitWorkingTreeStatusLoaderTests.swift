import XCTest

@testable import CodexDashboard

final class GitWorkingTreeStatusLoaderTests: XCTestCase {
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

        let statuses = await GitWorkingTreeStatusLoader().load(at: [workspaceURL.path])

        XCTAssertEqual(statuses[workspaceURL.path], .hasChanges)
    }

    func testReportsUnavailablePath() async {
        let missingPath = "/tmp/codex-dashboard-missing-\(UUID().uuidString)"
        let statuses = await GitWorkingTreeStatusLoader().load(at: [missingPath])
        XCTAssertEqual(statuses[missingPath], .unavailable)
    }

    func testReportsNonRepository() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-dashboard-non-git-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

        let statuses = await GitWorkingTreeStatusLoader().load(at: [directory.path])
        XCTAssertEqual(statuses[directory.path], .notRepository)
    }
}
