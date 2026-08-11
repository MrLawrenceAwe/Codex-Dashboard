import XCTest

@testable import CodexDashboard

final class GitWorkingTreeStatusProviderTests: XCTestCase {
    func testDefaultStatusCacheDoesNotDelayWorkingTreeUpdates() {
        XCTAssertEqual(GitWorkingTreeStatusProvider.defaultStatusCacheLifetime, 0)
        XCTAssertLessThanOrEqual(GitWorkingTreeStatusProvider.defaultResolutionCacheLifetime, 10)
    }

    func testDefaultProviderImmediatelyObservesCleanWorkingTree() async throws {
        let projectURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-dashboard-git-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: projectURL) }
        _ = try await Subprocess.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/git"),
            arguments: ["-C", projectURL.path, "init", "--quiet"],
            timeout: 3
        )
        let changedFileURL = projectURL.appendingPathComponent("notes.txt")
        try Data("uncommitted\n".utf8).write(to: changedFileURL)
        let provider = GitWorkingTreeStatusProvider()

        let changed = await provider.loadStatuses(for: [projectURL.path])
        try FileManager.default.removeItem(at: changedFileURL)
        let clean = await provider.loadStatuses(for: [projectURL.path])

        XCTAssertEqual(changed[projectURL.path], .hasChanges)
        XCTAssertEqual(clean[projectURL.path], .clean)
    }

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

        let statuses = await GitWorkingTreeStatusProvider().loadStatuses(for: [projectURL.path])

        XCTAssertEqual(statuses[projectURL.path], .hasChanges)
    }

    func testIgnoresTrackedAndUntrackedMacOSMetadata() async throws {
        let projectURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-dashboard-git-\(UUID().uuidString)", isDirectory: true)
        let nestedURL = projectURL.appendingPathComponent("Assets", isDirectory: true)
        try FileManager.default.createDirectory(at: nestedURL, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: projectURL) }
        _ = try await Subprocess.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/git"),
            arguments: ["-C", projectURL.path, "init", "--quiet"],
            timeout: 3
        )
        try Data("metadata".utf8).write(to: projectURL.appendingPathComponent(".DS_Store"))
        try Data("nested metadata".utf8).write(to: nestedURL.appendingPathComponent(".DS_Store"))
        _ = try await Subprocess.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/git"),
            arguments: ["-C", projectURL.path, "add", ".DS_Store"],
            timeout: 3
        )
        let provider = GitWorkingTreeStatusProvider()

        let metadataOnly = await provider.loadStatuses(for: [projectURL.path])
        try Data("meaningful".utf8).write(to: projectURL.appendingPathComponent("notes.txt"))
        let meaningfulChange = await provider.loadStatuses(for: [projectURL.path])

        XCTAssertEqual(metadataOnly[projectURL.path], .clean)
        XCTAssertEqual(meaningfulChange[projectURL.path], .hasChanges)
    }

    func testReportsUnavailablePath() async {
        let missingPath = "/tmp/codex-dashboard-missing-\(UUID().uuidString)"
        let statuses = await GitWorkingTreeStatusProvider().loadStatuses(for: [missingPath])
        XCTAssertEqual(statuses[missingPath], .unavailable)
    }

    func testReportsNonRepository() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-dashboard-non-git-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

        let statuses = await GitWorkingTreeStatusProvider().loadStatuses(for: [directory.path])
        XCTAssertEqual(statuses[directory.path], .notRepository)
    }

    func testChecksEveryPathAcrossConcurrencyBatches() async {
        let paths = Set((0..<14).map { index in
            "/tmp/codex-dashboard-missing-\(index)-\(UUID().uuidString)"
        })

        let statuses = await GitWorkingTreeStatusProvider().loadStatuses(for: paths)

        XCTAssertEqual(statuses.count, paths.count)
        XCTAssertTrue(statuses.values.allSatisfy { $0 == .unavailable })
    }

    func testNestedProjectPathsOnlyReportChangesInsideTheirOwnDirectory() async throws {
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
        let provider = GitWorkingTreeStatusProvider(cacheLifetime: 60)
        let paths: Set<String> = [firstProjectURL.path, secondProjectURL.path]

        let initial = await provider.loadStatuses(for: paths)
        XCTAssertEqual(initial[firstProjectURL.path], .clean)
        XCTAssertEqual(initial[secondProjectURL.path], .clean)

        try Data("uncommitted\n".utf8).write(to: repositoryURL.appendingPathComponent("notes.txt"))
        let cached = await provider.loadStatuses(for: paths)
        XCTAssertEqual(cached[firstProjectURL.path], .clean)
        XCTAssertEqual(cached[secondProjectURL.path], .clean)

        try Data("feature change\n".utf8).write(to: firstProjectURL.appendingPathComponent("feature.txt"))
        let uncachedProvider = GitWorkingTreeStatusProvider(cacheLifetime: 0)
        let refreshed = await uncachedProvider.loadStatuses(for: paths)
        XCTAssertEqual(refreshed[firstProjectURL.path], .hasChanges)
        XCTAssertEqual(refreshed[secondProjectURL.path], .clean)
    }

    func testTerminalRepositoryResolutionIsCachedUntilExpiry() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-dashboard-resolution-cache-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let provider = GitWorkingTreeStatusProvider(resolutionCacheLifetime: 60)

        let initial = await provider.loadStatuses(for: [directory.path])
        XCTAssertEqual(initial[directory.path], .notRepository)
        _ = try await Subprocess.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/git"),
            arguments: ["-C", directory.path, "init", "--quiet"],
            timeout: 3
        )

        let cached = await provider.loadStatuses(for: [directory.path])
        XCTAssertEqual(cached[directory.path], .notRepository)

        let uncachedProvider = GitWorkingTreeStatusProvider(resolutionCacheLifetime: 0)
        let refreshed = await uncachedProvider.loadStatuses(for: [directory.path])
        XCTAssertEqual(refreshed[directory.path], .clean)
    }
}
