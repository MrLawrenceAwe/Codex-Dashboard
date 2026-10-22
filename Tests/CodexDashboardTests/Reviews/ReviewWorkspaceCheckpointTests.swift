import XCTest
@testable import CodexDashboard

final class ReviewWorkspaceCheckpointTests: XCTestCase {
    func testRealGitCheckpointIncludesUntrackedFilesAndCommitAncestry() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("review-git-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        func git(_ arguments: [String]) async throws {
            let result = try await Subprocess.run(executableURL: URL(fileURLWithPath: "/usr/bin/git"), arguments: ["-C", directory.path] + arguments, timeout: 5)
            XCTAssertEqual(result.terminationStatus, 0)
        }
        try await git(["init", "-b", "main"])
        try await git(["-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "--allow-empty", "-m", "Initial"])
        let checkpoint = ReviewWorkspaceCheckpoint()
        let initial = try await checkpoint.workspace(at: directory.path)
        XCTAssertEqual(initial.git?.isClean, true)
        XCTAssertEqual(initial.git?.branch, "main")
        XCTAssertEqual(initial.kind, .git)
        let nested = directory.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let nestedState = try await checkpoint.workspace(at: nested.path)
        XCTAssertEqual(nestedState.kind, .git)
        XCTAssertEqual(nestedState.root, initial.root)
        XCTAssertTrue(ReviewWorkspaceCheckpoint.hasGitMetadata(at: nested.path))
        let worktree = directory.appendingPathComponent("linked", isDirectory: true)
        try await git(["worktree", "add", "-b", "linked", worktree.path])
        let linkedState = try await checkpoint.workspace(at: worktree.path)
        XCTAssertEqual(linkedState.kind, .git)
        XCTAssertTrue(ReviewWorkspaceCheckpoint.hasGitMetadata(at: worktree.path))
        try await git(["worktree", "remove", worktree.path])
        try Data("change".utf8).write(to: directory.appendingPathComponent("fix.txt"))
        let dirty = try await checkpoint.workspace(at: directory.path)
        XCTAssertEqual(dirty.git?.isClean, false)
        try await git(["add", "fix.txt"])
        try await git(["-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "-m", "Fix"])
        let fixed = try await checkpoint.workspace(at: directory.path)
        XCTAssertEqual(fixed.git?.isClean, true)
        XCTAssertNotEqual(fixed.revision, initial.revision)
        let isAncestor = try await checkpoint.isAncestor(initial.revision, of: fixed.revision, at: directory.path)
        XCTAssertTrue(isAncestor)
        for reported in [fixed.revision, String(fixed.revision.prefix(7)), String(fixed.revision.prefix(7)).uppercased()] {
            let resolved = try await checkpoint.resolveCommit(reported, at: directory.path)
            XCTAssertEqual(resolved, fixed.revision)
        }
        for invalid in ["", "HEAD", "main", "--help", "abc", "deadbeef", fixed.revision + "~1"] {
            do {
                _ = try await checkpoint.resolveCommit(invalid, at: directory.path)
                XCTFail("Accepted invalid commit ID: \(invalid)")
            } catch { }
        }
    }
}
