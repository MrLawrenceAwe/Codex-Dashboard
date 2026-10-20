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
        _ = try await checkpoint.reconcileAndPublishFix(initial.revision, at: checkout, expectedRepository: initial)
        let remoteHead = try await git(["rev-parse", "refs/heads/main"], at: remote)
        XCTAssertEqual(remoteHead, initial.revision)
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
        _ = try await checkpoint.reconcileAndPublishFix(fixed.revision, at: checkout, expectedRepository: fixed)
        statuses = await provider.loadStatuses(for: [checkout], policy: .refresh)
        XCTAssertEqual(statuses[checkout], .clean)
    }

    func testPushPublishesReportedFixWithoutLaterCommits() async throws {
        let (checkout, remote) = try await fixture()
        let checkpoint = ReviewRepositoryCheckpoint()
        _ = try await git(["commit", "--allow-empty", "-m", "Fix"], at: checkout)
        let fix = try await checkpoint.repository(at: checkout)
        _ = try await git(["commit", "--allow-empty", "-m", "Later work"], at: checkout)
        let current = try await checkpoint.repository(at: checkout)
        _ = try await checkpoint.reconcileAndPublishFix(fix.revision, at: checkout, expectedRepository: current)
        let pushed = try await git(["rev-parse", "refs/heads/main"], at: remote)
        XCTAssertEqual(pushed, fix.revision)
        let local = try await checkpoint.repository(at: checkout)
        XCTAssertEqual(local, current)
    }

    func testPushRecognizesFixAlreadyPublishedInLaterRemoteHistory() async throws {
        let (checkout, remote) = try await fixture()
        let checkpoint = ReviewRepositoryCheckpoint()
        let fix = try await checkpoint.repository(at: checkout)
        _ = try await git(["commit", "--allow-empty", "-m", "Later published work"], at: checkout)
        let current = try await checkpoint.repository(at: checkout)
        _ = try await checkpoint.reconcileAndPublishFix(current.revision, at: checkout, expectedRepository: current)
        _ = try await checkpoint.reconcileAndPublishFix(fix.revision, at: checkout, expectedRepository: current)
        let pushed = try await git(["rev-parse", "refs/heads/main"], at: remote)
        XCTAssertEqual(pushed, current.revision)
    }

    func testPushUsesConfiguredUpstreamBranchAndReverifiesDivergence() async throws {
        let (checkout, remote) = try await fixture()
        _ = try await git(["push", "-u", "origin", "main:published"], at: checkout)
        let base = try await git(["rev-parse", "HEAD"], at: checkout)
        _ = try await git(["commit", "--allow-empty", "-m", "Review fix"], at: checkout)
        let checkpoint = ReviewRepositoryCheckpoint()
        let fixed = try await checkpoint.repository(at: checkout)
        _ = try await checkpoint.reconcileAndPublishFix(fixed.revision, at: checkout, expectedRepository: fixed)
        let pushed = try await git(["rev-parse", "refs/heads/published"], at: remote)
        XCTAssertEqual(pushed, fixed.revision)
        // Preserve both histories and require verification before publishing the merge.
        _ = try await git(["reset", "--hard", base], at: checkout)
        _ = try await git(["commit", "--allow-empty", "-m", "Divergent fix"], at: checkout)
        let divergent = try await checkpoint.repository(at: checkout)
        let publication = try await checkpoint.reconcileAndPublishFix(divergent.revision, at: checkout, expectedRepository: divergent)
        if case .verificationRequired(let repository) = publication {
            XCTAssertTrue(repository.clean)
            let containsFix = try await checkpoint.isAncestor(divergent.revision, of: repository.revision, at: checkout)
            let containsRemote = try await checkpoint.isAncestor(fixed.revision, of: repository.revision, at: checkout)
            XCTAssertTrue(containsFix)
            XCTAssertTrue(containsRemote)
        } else {
            XCTFail("A merged checkout must be reverified before publishing")
        }
        let unchanged = try await git(["rev-parse", "refs/heads/published"], at: remote)
        XCTAssertEqual(unchanged, fixed.revision)
    }

    private func otherCheckout(_ remote: String) async throws -> String {
        let other = URL(fileURLWithPath: remote).deletingLastPathComponent().appendingPathComponent("other").path
        _ = try await git(["clone", remote, other], at: URL(fileURLWithPath: remote).deletingLastPathComponent().path)
        _ = try await git(["checkout", "main"], at: other)
        _ = try await git(["config", "user.name", "Other"], at: other)
        _ = try await git(["config", "user.email", "other@example.test"], at: other)
        return other
    }

    func testFetchRecognizesFixInUnknownRemoteDescendantWithoutChangingCheckout() async throws {
        let (checkout, remote) = try await fixture()
        _ = try await git(["push", "-u", "origin", "main"], at: checkout)
        let checkpoint = ReviewRepositoryCheckpoint()
        let fix = try await checkpoint.repository(at: checkout)
        let other = try await otherCheckout(remote)
        _ = try await git(["commit", "--allow-empty", "-m", "Remote work"], at: other)
        _ = try await git(["push", "origin", "main"], at: other)
        let remoteHead = try await git(["rev-parse", "HEAD"], at: other)
        _ = try await checkpoint.reconcileAndPublishFix(fix.revision, at: checkout, expectedRepository: fix)
        let unchanged = try await checkpoint.repository(at: checkout)
        XCTAssertEqual(unchanged, fix)
        let published = try await git(["rev-parse", "refs/heads/main"], at: remote)
        XCTAssertEqual(published, remoteHead)
    }

    func testFetchMergeThenVerifiedRetryPreservesRemoteAndOriginalFix() async throws {
        let (checkout, remote) = try await fixture()
        _ = try await git(["push", "-u", "origin", "main"], at: checkout)
        let other = try await otherCheckout(remote)
        _ = try await git(["commit", "--allow-empty", "-m", "Remote work"], at: other)
        _ = try await git(["push", "origin", "main"], at: other)
        let remoteHead = try await git(["rev-parse", "HEAD"], at: other)
        _ = try await git(["commit", "--allow-empty", "-m", "Local fix"], at: checkout)
        let checkpoint = ReviewRepositoryCheckpoint()
        let fix = try await checkpoint.repository(at: checkout)
        let publication = try await checkpoint.reconcileAndPublishFix(fix.revision, at: checkout, expectedRepository: fix)
        guard case .verificationRequired = publication else {
            return XCTFail("Requires verification")
        }
        let merged = try await checkpoint.repository(at: checkout)
        let beforeVerification = try await git(["rev-parse", "refs/heads/main"], at: remote)
        XCTAssertEqual(beforeVerification, remoteHead)
        XCTAssertNotEqual(merged.revision, fix.revision)
        // The coordinator supplies this checkpoint only after read-only verification.
        _ = try await checkpoint.reconcileAndPublishFix(fix.revision, at: checkout, expectedRepository: merged)
        let published = try await git(["rev-parse", "refs/heads/main"], at: remote)
        XCTAssertEqual(published, merged.revision)
        let hasFix = try await checkpoint.isAncestor(fix.revision, of: published, at: checkout)
        let hasRemote = try await checkpoint.isAncestor(remoteHead, of: published, at: checkout)
        XCTAssertTrue(hasFix)
        XCTAssertTrue(hasRemote)
    }

    func testConflictingRemoteMergeAbortsAndLeavesBothBranchesUntouched() async throws {
        let (checkout, remote) = try await fixture()
        let file = URL(fileURLWithPath: checkout).appendingPathComponent("shared.txt")
        try Data("base\n".utf8).write(to: file)
        _ = try await git(["add", "."], at: checkout)
        _ = try await git(["commit", "-m", "Base"], at: checkout)
        _ = try await git(["push", "-u", "origin", "main"], at: checkout)
        let other = try await otherCheckout(remote)
        try Data("remote\n".utf8).write(to: URL(fileURLWithPath: other).appendingPathComponent("shared.txt"))
        _ = try await git(["commit", "-am", "Remote change"], at: other)
        _ = try await git(["push", "origin", "main"], at: other)
        let remoteHead = try await git(["rev-parse", "HEAD"], at: other)
        try Data("local\n".utf8).write(to: file)
        _ = try await git(["commit", "-am", "Local fix"], at: checkout)
        let checkpoint = ReviewRepositoryCheckpoint()
        let fix = try await checkpoint.repository(at: checkout)
        do {
            _ = try await checkpoint.reconcileAndPublishFix(fix.revision, at: checkout, expectedRepository: fix)
            XCTFail("Conflicts require attention")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("could not be merged automatically"))
        }
        let unchanged = try await checkpoint.repository(at: checkout)
        XCTAssertEqual(unchanged, fix)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "local\n")
        let published = try await git(["rev-parse", "refs/heads/main"], at: remote)
        XCTAssertEqual(published, remoteHead)
    }

    func testRemoteRecoveryDoesNotAbortAnExistingCleanPendingMerge() async throws {
        let (checkout, remote) = try await fixture()
        _ = try await git(["push", "-u", "origin", "main"], at: checkout)
        let other = try await otherCheckout(remote)
        _ = try await git(["commit", "--allow-empty", "-m", "Remote work"], at: other)
        _ = try await git(["push", "origin", "main"], at: other)
        _ = try await git(["commit", "--allow-empty", "-m", "Local fix"], at: checkout)
        _ = try await git(["fetch", "origin", "main"], at: checkout)
        _ = try await git(["merge", "--no-commit", "--no-ff", "origin/main"], at: checkout)
        let pending = try await git(["rev-parse", "MERGE_HEAD"], at: checkout)
        let checkpoint = ReviewRepositoryCheckpoint()
        let fix = try await checkpoint.repository(at: checkout)
        XCTAssertTrue(fix.clean, "An empty pending merge is invisible to porcelain status")
        do {
            _ = try await checkpoint.reconcileAndPublishFix(fix.revision, at: checkout, expectedRepository: fix)
            XCTFail("An existing Git operation must be left alone")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("existing Git operation"))
        }
        let preserved = try await git(["rev-parse", "MERGE_HEAD"], at: checkout)
        XCTAssertEqual(preserved, pending)
    }

    func testPushRejectsChangedCheckoutAndMissingRemote() async throws {
        let (checkout, _) = try await fixture()
        let checkpoint = ReviewRepositoryCheckpoint()
        let initial = try await checkpoint.repository(at: checkout)
        _ = try await git(["commit", "--allow-empty", "-m", "Unexpected"], at: checkout)
        do {
            _ = try await checkpoint.reconcileAndPublishFix(initial.revision, at: checkout, expectedRepository: initial)
            XCTFail("Changed HEAD must prevent pushing")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("checkout changed"))
        }
        _ = try await git(["remote", "remove", "origin"], at: checkout)
        let current = try await checkpoint.repository(at: checkout)
        do {
            _ = try await checkpoint.reconcileAndPublishFix(current.revision, at: checkout, expectedRepository: current)
            XCTFail("A missing remote must prevent pushing")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Push needs a remote"))
        }
        let statuses = await ProjectGitStatusProvider().loadStatuses(for: [checkout], policy: .refresh)
        XCTAssertEqual(statuses[checkout], .clean, "A local-only repository has no unpushed status")
    }
}
