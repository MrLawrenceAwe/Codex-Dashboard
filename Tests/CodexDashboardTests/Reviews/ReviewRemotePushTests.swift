import Foundation
import XCTest
@testable import CodexDashboard

final class ReviewRemotePushTests: XCTestCase {
    private func git(_ arguments: [String], at path: String) async throws -> String {
        let result = try await Subprocess.run(executableURL: URL(fileURLWithPath: "/usr/bin/git"),
            arguments: ["-C", path] + arguments, timeout: 5)
        guard result.terminationStatus == 0 else {
            throw ReviewLoopError(String(decoding: result.standardError, as: UTF8.self))
        }
        return String(decoding: result.standardOutput, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func fixture() async throws -> (checkout: String, remote: String) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("review-remote-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let checkout = root.appendingPathComponent("checkout").path
        let remote = root.appendingPathComponent("remote.git").path
        _ = try await git(["init", "--bare", remote], at: root.path)
        _ = try await git(["init", "-b", "main", checkout], at: root.path)
        _ = try await git(["config", "user.name", "Test"], at: checkout)
        _ = try await git(["config", "user.email", "test@example.test"], at: checkout)
        _ = try await git(["commit", "--allow-empty", "-m", "Initial"], at: checkout)
        _ = try await git(["remote", "add", "origin", remote], at: checkout)
        return (checkout, remote)
    }

    func testPushCreatesUpstreamAndOverviewTracksPendingAndDirtyStates() async throws {
        let (checkout, remote) = try await fixture()
        let provider = ProjectGitStatusProvider()
        var statuses = await provider.loadStatuses(for: [checkout], policy: .refresh)
        XCTAssertEqual(statuses[checkout], .unpushedCommits, "A branch without an upstream still has unpublished commits")
        let checkpoint = ReviewRepositoryCheckpoint()
        let initial = try await checkpoint.repository(at: checkout)
        try await checkpoint.pushCommit(at: checkout, expectedRepository: initial)
        let remoteHead = try await git(["rev-parse", "refs/heads/main"], at: remote)
        XCTAssertEqual(remoteHead, initial.commit)
        let upstream = try await git(["rev-parse", "--abbrev-ref", "@{upstream}"], at: checkout)
        XCTAssertEqual(upstream, "origin/main")
        statuses = await provider.loadStatuses(for: [checkout], policy: .refresh)
        XCTAssertEqual(statuses[checkout], .clean)
        _ = try await git(["commit", "--allow-empty", "-m", "Fix"], at: checkout)
        statuses = await provider.loadStatuses(for: [checkout], policy: .refresh)
        XCTAssertEqual(statuses[checkout], .unpushedCommits)
        let note = URL(fileURLWithPath: checkout).appendingPathComponent("notes.txt")
        try Data("Unrelated work".utf8).write(to: note)
        statuses = await provider.loadStatuses(for: [checkout], policy: .refresh)
        XCTAssertEqual(statuses[checkout], .uncommittedChangesAndUnpushedCommits)
        try FileManager.default.removeItem(at: note)
        let fixed = try await checkpoint.repository(at: checkout)
        try await checkpoint.pushCommit(at: checkout, expectedRepository: fixed)
        statuses = await provider.loadStatuses(for: [checkout], policy: .refresh)
        XCTAssertEqual(statuses[checkout], .clean)
    }

    func testPushUsesConfiguredUpstreamBranchAndRejectsDivergence() async throws {
        let (checkout, remote) = try await fixture()
        _ = try await git(["push", "-u", "origin", "main:published"], at: checkout)
        let base = try await git(["rev-parse", "HEAD"], at: checkout)
        _ = try await git(["commit", "--allow-empty", "-m", "Review fix"], at: checkout)
        let checkpoint = ReviewRepositoryCheckpoint()
        let fixed = try await checkpoint.repository(at: checkout)
        try await checkpoint.pushCommit(at: checkout, expectedRepository: fixed)
        let pushed = try await git(["rev-parse", "refs/heads/published"], at: remote)
        XCTAssertEqual(pushed, fixed.commit)
        // A remote change on a different lineage must never be overwritten.
        _ = try await git(["reset", "--hard", base], at: checkout)
        _ = try await git(["commit", "--allow-empty", "-m", "Divergent fix"], at: checkout)
        let divergent = try await checkpoint.repository(at: checkout)
        do {
            try await checkpoint.pushCommit(at: checkout, expectedRepository: divergent)
            XCTFail("A non-fast-forward push must fail")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Remote push failed"))
        }
        let unchanged = try await git(["rev-parse", "refs/heads/published"], at: remote)
        XCTAssertEqual(unchanged, fixed.commit)
    }

    func testPushRejectsChangedCheckoutAndMissingRemote() async throws {
        let (checkout, _) = try await fixture()
        let checkpoint = ReviewRepositoryCheckpoint()
        let initial = try await checkpoint.repository(at: checkout)
        _ = try await git(["commit", "--allow-empty", "-m", "Unexpected"], at: checkout)
        do {
            try await checkpoint.pushCommit(at: checkout, expectedRepository: initial)
            XCTFail("Changed HEAD must prevent pushing")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("checkout changed"))
        }
        _ = try await git(["remote", "remove", "origin"], at: checkout)
        let current = try await checkpoint.repository(at: checkout)
        do {
            try await checkpoint.pushCommit(at: checkout, expectedRepository: current)
            XCTFail("A missing remote must prevent pushing")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Push needs a remote"))
        }
        let statuses = await ProjectGitStatusProvider().loadStatuses(for: [checkout], policy: .refresh)
        XCTAssertEqual(statuses[checkout], .clean, "A local-only repository has no unpushed status")
    }
}
