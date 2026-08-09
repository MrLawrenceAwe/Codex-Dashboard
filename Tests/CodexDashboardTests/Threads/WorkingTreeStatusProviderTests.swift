import XCTest

@testable import CodexDashboard

final class SystemWorkingTreeStatusProviderTests: XCTestCase {
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

        let statuses = await SystemWorkingTreeStatusProvider().load(projectPaths: [projectURL.path])

        XCTAssertEqual(statuses[projectURL.path], .hasChanges)
    }

    func testReportsUnavailablePath() async {
        let missingPath = "/tmp/codex-dashboard-missing-\(UUID().uuidString)"
        let statuses = await SystemWorkingTreeStatusProvider().load(projectPaths: [missingPath])
        XCTAssertEqual(statuses[missingPath], .unavailable)
    }

    func testReportsNonRepository() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-dashboard-non-git-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

        let statuses = await SystemWorkingTreeStatusProvider().load(projectPaths: [directory.path])
        XCTAssertEqual(statuses[directory.path], .notRepository)
    }

    func testChecksEveryPathAcrossConcurrencyBatches() async {
        let paths = Set((0..<14).map { index in
            "/tmp/codex-dashboard-missing-\(index)-\(UUID().uuidString)"
        })

        let statuses = await SystemWorkingTreeStatusProvider().load(projectPaths: paths)

        XCTAssertEqual(statuses.count, paths.count)
        XCTAssertTrue(statuses.values.allSatisfy { $0 == .unavailable })
    }

    func testNestedProjectPathsShareRepositoryStatusAndUseFreshCache() async throws {
        let repositoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-dashboard-git-\(UUID().uuidString)", isDirectory: true)
        let firstProjectURL = repositoryURL.appendingPathComponent("Sources/FeatureA", isDirectory: true)
        let secondProjectURL = repositoryURL.appendingPathComponent("Sources/FeatureB", isDirectory: true)
        try FileManager.default.createDirectory(at: firstProjectURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondProjectURL, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: repositoryURL) }
        _ = try await Subprocess.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/git"),
            arguments: ["-C", repositoryURL.path, "init", "--quiet"],
            timeout: 3
        )
        let provider = SystemWorkingTreeStatusProvider(cacheLifetime: 60)
        let paths: Set<String> = [firstProjectURL.path, secondProjectURL.path]

        let initial = await provider.load(projectPaths: paths)
        XCTAssertEqual(initial[firstProjectURL.path], .clean)
        XCTAssertEqual(initial[secondProjectURL.path], .clean)

        try Data("uncommitted\n".utf8).write(to: repositoryURL.appendingPathComponent("notes.txt"))
        let cached = await provider.load(projectPaths: paths)
        XCTAssertEqual(cached[firstProjectURL.path], .clean)
        XCTAssertEqual(cached[secondProjectURL.path], .clean)

        let uncachedProvider = SystemWorkingTreeStatusProvider(cacheLifetime: 0)
        let refreshed = await uncachedProvider.load(projectPaths: paths)
        XCTAssertEqual(refreshed[firstProjectURL.path], .hasChanges)
        XCTAssertEqual(refreshed[secondProjectURL.path], .hasChanges)
    }

    func testTerminalRepositoryResolutionIsCachedUntilExpiry() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-dashboard-resolution-cache-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let provider = SystemWorkingTreeStatusProvider(resolutionCacheLifetime: 60)

        let initial = await provider.load(projectPaths: [directory.path])
        XCTAssertEqual(initial[directory.path], .notRepository)
        _ = try await Subprocess.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/git"),
            arguments: ["-C", directory.path, "init", "--quiet"],
            timeout: 3
        )

        let cached = await provider.load(projectPaths: [directory.path])
        XCTAssertEqual(cached[directory.path], .notRepository)

        let uncachedProvider = SystemWorkingTreeStatusProvider(resolutionCacheLifetime: 0)
        let refreshed = await uncachedProvider.load(projectPaths: [directory.path])
        XCTAssertEqual(refreshed[directory.path], .clean)
    }
}
