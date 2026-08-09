import XCTest

@testable import CodexDashboard

final class SystemGitStatusProviderTests: XCTestCase {
    func testReportsUncommittedChanges() async throws {
        let projectURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-dashboard-git-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: projectURL) }

        let git = Process()
        git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        git.arguments = ["-C", projectURL.path, "init", "--quiet"]
        try git.run()
        git.waitUntilExit()
        XCTAssertEqual(git.terminationStatus, 0)
        try Data("uncommitted\n".utf8).write(to: projectURL.appendingPathComponent("notes.txt"))

        let statuses = await SystemGitStatusProvider().load(projectPaths: [projectURL.path])

        XCTAssertEqual(statuses[projectURL.path], .hasChanges)
    }

    func testReportsUnavailablePath() async {
        let missingPath = "/tmp/codex-dashboard-missing-\(UUID().uuidString)"
        let statuses = await SystemGitStatusProvider().load(projectPaths: [missingPath])
        XCTAssertEqual(statuses[missingPath], .unavailable)
    }

    func testReportsNonRepository() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-dashboard-non-git-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

        let statuses = await SystemGitStatusProvider().load(projectPaths: [directory.path])
        XCTAssertEqual(statuses[directory.path], .notRepository)
    }

    func testChecksEveryPathAcrossConcurrencyBatches() async {
        let paths = Set((0..<14).map { index in
            "/tmp/codex-dashboard-missing-\(index)-\(UUID().uuidString)"
        })

        let statuses = await SystemGitStatusProvider().load(projectPaths: paths)

        XCTAssertEqual(statuses.count, paths.count)
        XCTAssertTrue(statuses.values.allSatisfy { $0 == .unavailable })
    }
}
