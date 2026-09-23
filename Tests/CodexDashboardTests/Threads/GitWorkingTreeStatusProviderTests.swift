import XCTest

@testable import CodexDashboard

final class GitWorkingTreeStatusProviderTests: XCTestCase {
    private actor OrderedStatusLoader {
        private var callCount = 0
        private var firstCall: CheckedContinuation<WorkingTreeStatus, Never>?
        private var firstCallStarted: CheckedContinuation<Void, Never>?

        func load() async -> WorkingTreeStatus {
            callCount += 1
            if callCount == 1 {
                firstCallStarted?.resume()
                firstCallStarted = nil
                return await withCheckedContinuation { firstCall = $0 }
            }
            return .clean
        }

        func waitForFirstCall() async {
            if callCount > 0 { return }
            await withCheckedContinuation { firstCallStarted = $0 }
        }

        func releaseFirstCall() {
            firstCall?.resume(returning: .hasChanges)
            firstCall = nil
        }

        func calls() -> Int { callCount }
    }

    func testDefaultStatusCacheAvoidsRepeatedPeriodicGitScans() {
        XCTAssertEqual(GitWorkingTreeStatusProvider.defaultStatusCacheLifetime, 60)
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

        let changed = await provider.loadStatuses(for: [projectURL.path], policy: .useCached)
        try FileManager.default.removeItem(at: changedFileURL)
        let clean = await provider.loadStatuses(for: [projectURL.path], policy: .refresh)

        XCTAssertEqual(changed[projectURL.path], .hasChanges)
        XCTAssertEqual(clean[projectURL.path], .clean)
    }

    func testOlderRefreshCannotOverwriteNewerCachedStatus() async throws {
        let projectURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-dashboard-git-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: projectURL) }
        _ = try await Subprocess.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/git"),
            arguments: ["-C", projectURL.path, "init", "--quiet"],
            timeout: 3
        )

        let loader = OrderedStatusLoader()
        let provider = GitWorkingTreeStatusProvider(statusLoader: { _, _ in
            await loader.load()
        })
        let olderRefresh = Task {
            await provider.loadStatuses(for: [projectURL.path], policy: .refresh)
        }
        await loader.waitForFirstCall()
        let newer = await provider.loadStatuses(for: [projectURL.path], policy: .refresh)
        await loader.releaseFirstCall()
        let older = await olderRefresh.value
        let cached = await provider.loadStatuses(for: [projectURL.path], policy: .useCached)

        XCTAssertEqual(newer[projectURL.path], .clean)
        XCTAssertEqual(older[projectURL.path], .clean)
        XCTAssertEqual(cached[projectURL.path], .clean)
        let callCount = await loader.calls()
        XCTAssertEqual(callCount, 2)
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

        let statuses = await GitWorkingTreeStatusProvider().loadStatuses(
            for: [projectURL.path], policy: .useCached
        )

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

        let metadataOnly = await provider.loadStatuses(for: [projectURL.path], policy: .useCached)
        try Data("meaningful".utf8).write(to: projectURL.appendingPathComponent("notes.txt"))
        let meaningfulChange = await provider.loadStatuses(for: [projectURL.path], policy: .refresh)

        XCTAssertEqual(metadataOnly[projectURL.path], .clean)
        XCTAssertEqual(meaningfulChange[projectURL.path], .hasChanges)
    }

    func testReportsUnavailablePath() async {
        let missingPath = "/tmp/codex-dashboard-missing-\(UUID().uuidString)"
        let statuses = await GitWorkingTreeStatusProvider().loadStatuses(
            for: [missingPath], policy: .useCached
        )
        XCTAssertEqual(statuses[missingPath], .unavailable)
    }

    func testReportsNonRepository() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-dashboard-non-git-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

        let statuses = await GitWorkingTreeStatusProvider().loadStatuses(
            for: [directory.path], policy: .useCached
        )
        XCTAssertEqual(statuses[directory.path], .notRepository)
    }

    func testChecksEveryPathAcrossConcurrencyBatches() async {
        let paths = Set((0..<14).map { index in
            "/tmp/codex-dashboard-missing-\(index)-\(UUID().uuidString)"
        })

        let statuses = await GitWorkingTreeStatusProvider().loadStatuses(
            for: paths, policy: .useCached
        )

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

        let initial = await provider.loadStatuses(for: paths, policy: .useCached)
        XCTAssertEqual(initial[firstProjectURL.path], .clean)
        XCTAssertEqual(initial[secondProjectURL.path], .clean)

        try Data("uncommitted\n".utf8).write(to: repositoryURL.appendingPathComponent("notes.txt"))
        let cached = await provider.loadStatuses(for: paths, policy: .useCached)
        XCTAssertEqual(cached[firstProjectURL.path], .clean)
        XCTAssertEqual(cached[secondProjectURL.path], .clean)

        try Data("feature change\n".utf8).write(to: firstProjectURL.appendingPathComponent("feature.txt"))
        let uncachedProvider = GitWorkingTreeStatusProvider(cacheLifetime: 0)
        let refreshed = await uncachedProvider.loadStatuses(for: paths, policy: .useCached)
        XCTAssertEqual(refreshed[firstProjectURL.path], .hasChanges)
        XCTAssertEqual(refreshed[secondProjectURL.path], .clean)
    }

    func testRepositoryResolutionImmediatelyObservesNewRepository() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-dashboard-resolution-cache-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let provider = GitWorkingTreeStatusProvider()

        let initial = await provider.loadStatuses(for: [directory.path], policy: .useCached)
        XCTAssertEqual(initial[directory.path], .notRepository)
        _ = try await Subprocess.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/git"),
            arguments: ["-C", directory.path, "init", "--quiet"],
            timeout: 3
        )

        let refreshed = await provider.loadStatuses(for: [directory.path], policy: .useCached)
        XCTAssertEqual(refreshed[directory.path], .clean)
    }
}
