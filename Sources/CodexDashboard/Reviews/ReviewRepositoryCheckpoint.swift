import Foundation

struct ReviewRepositoryCheckpoint {
    func repository(at path: String) async throws -> ReviewRepositoryState {
        let root = try await git(["rev-parse", "--show-toplevel"], at: path)
        let branch = try await git(["symbolic-ref", "--quiet", "--short", "HEAD"], at: path)
        let head = try await git(["rev-parse", "HEAD"], at: path)
        let status = try await git(["status", "--porcelain=v1", "--untracked-files=all", "--ignore-submodules=none"], at: path)
        // Read HEAD again to reject a checkpoint taken across a concurrent commit.
        guard head == (try await git(["rev-parse", "HEAD"], at: path)) else {
            throw ReviewLoopError("HEAD changed while checking the commit checkpoint.")
        }
        return ReviewRepositoryState(root: root, branch: branch, commit: head, clean: status.isEmpty)
    }

    func resolveCommit(_ commit: String, at path: String) async throws -> String {
        guard (4...64).contains(commit.count),
              commit.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) || (65...70).contains($0) }) else {
            throw ReviewLoopError("Commit checkpoint failed: the fix report must contain a Git commit ID.")
        }
        let result = try await runGit(["rev-parse", "--verify", "--end-of-options", commit.lowercased() + "^{commit}"], at: path)
        guard result.terminationStatus == 0 else {
            throw ReviewLoopError("Commit checkpoint failed: the reported commit ID is missing, ambiguous, or does not identify a commit.")
        }
        return String(decoding: result.standardOutput, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func isAncestor(_ commit: String, of head: String, at path: String) async throws -> Bool {
        let result = try await runGit(["merge-base", "--is-ancestor", commit, head], at: path)
        guard result.terminationStatus <= 1 else { throw ReviewLoopError("Could not verify the review commit ancestry.") }
        return result.terminationStatus == 0
    }

    private func git(_ arguments: [String], at path: String) async throws -> String {
        let result = try await runGit(arguments, at: path)
        guard result.terminationStatus == 0 else {
            throw ReviewLoopError("Git checkpoint failed: " + String(decoding: result.standardError, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return String(decoding: result.standardOutput, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func runGit(_ arguments: [String], at path: String) async throws -> SubprocessOutput {
        try await Subprocess.run(executableURL: URL(fileURLWithPath: "/usr/bin/git"), arguments: ["--no-optional-locks", "-C", path] + arguments, timeout: 5)
    }

}
