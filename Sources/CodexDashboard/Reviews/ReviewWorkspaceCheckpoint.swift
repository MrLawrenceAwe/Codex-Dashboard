import Foundation

protocol ReviewWorkspaceChecking: Sendable {
    func workspace(at path: String) async throws -> ReviewWorkspaceState
    func resolveCommit(_ commit: String, at path: String) async throws -> String
    func isAncestor(_ commit: String, of head: String, at path: String) async throws -> Bool
}

struct ReviewWorkspaceCheckpoint: ReviewWorkspaceChecking {
    static func hasGitMetadata(at path: String) -> Bool {
        var directory = FileSystemPath.canonicalURL(path)
        while true {
            if (try? FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent(".git").path)) != nil { return true }
            guard directory.path != "/", !directory.path.isEmpty else { return false }
            directory.deleteLastPathComponent()
        }
    }

    func workspace(at path: String) async throws -> ReviewWorkspaceState {
        let probe = try await ReviewGitCommand.run(["rev-parse", "--is-inside-work-tree"], at: path)
        if probe.terminationStatus != 0 {
            // A damaged or inaccessible repository must not silently become a folder loop.
            if Self.hasGitMetadata(at: path) {
                throw ReviewLoopError("The Git repository could not be inspected: " + String(decoding: probe.standardError, as: UTF8.self))
            }
            return try await ReviewFolderCheckpoint.workspace(at: path)
        }
        guard String(decoding: probe.standardOutput, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == "true" else {
            throw ReviewLoopError("Choose a working folder, rather than a bare Git repository.")
        }
        let root = try await ReviewGitCommand.output(["rev-parse", "--show-toplevel"], at: path)
        let branch = try await ReviewGitCommand.output(["symbolic-ref", "--quiet", "--short", "HEAD"], at: path)
        let head = try await ReviewGitCommand.output(["rev-parse", "HEAD"], at: path)
        let status = try await ReviewGitCommand.output(["status", "--porcelain=v1", "--untracked-files=all", "--ignore-submodules=none"], at: path)
        // Read HEAD again to reject a checkpoint taken across a concurrent commit.
        guard head == (try await ReviewGitCommand.output(["rev-parse", "HEAD"], at: path)) else {
            throw ReviewLoopError("HEAD changed while checking the commit checkpoint.")
        }
        return ReviewWorkspaceState(root: root, branch: branch, revision: head, clean: status.isEmpty)
    }

    func resolveCommit(_ commit: String, at path: String) async throws -> String {
        guard (4...64).contains(commit.count),
              commit.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) || (65...70).contains($0) }) else {
            throw ReviewLoopError("Commit checkpoint failed: the fix report must contain a Git commit ID.")
        }
        let result = try await ReviewGitCommand.run(["rev-parse", "--verify", "--end-of-options", commit.lowercased() + "^{commit}"], at: path)
        guard result.terminationStatus == 0 else {
            throw ReviewLoopError("Commit checkpoint failed: the reported commit ID is missing, ambiguous, or does not identify a commit.")
        }
        return String(decoding: result.standardOutput, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func isAncestor(_ commit: String, of head: String, at path: String) async throws -> Bool {
        let result = try await ReviewGitCommand.run(["merge-base", "--is-ancestor", commit, head], at: path)
        guard result.terminationStatus <= 1 else { throw ReviewLoopError("Could not verify the review commit ancestry.") }
        return result.terminationStatus == 0
    }

}
