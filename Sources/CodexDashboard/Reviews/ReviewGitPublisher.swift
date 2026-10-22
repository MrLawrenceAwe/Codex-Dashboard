import Foundation

protocol ReviewGitPublishing: Sendable {
    func reconcileAndPublishFix(_ commit: String, at path: String, expectedWorkspace: ReviewWorkspaceState) async throws -> ReviewPublicationOutcome
}

enum ReviewPublicationOutcome: Equatable, Sendable {
    case published
    case verificationRequired(ReviewWorkspaceState)
}

/// Owns remote synchronization and publication, including merge and upstream writes.
struct ReviewGitPublisher: ReviewGitPublishing {
    private let workspaceCheckpoint: any ReviewWorkspaceChecking

    init(workspaceCheckpoint: any ReviewWorkspaceChecking = ReviewWorkspaceCheckpoint()) {
        self.workspaceCheckpoint = workspaceCheckpoint
    }

    func reconcileAndPublishFix(_ commit: String, at path: String, expectedWorkspace: ReviewWorkspaceState) async throws -> ReviewPublicationOutcome {
        guard let git = expectedWorkspace.git, git.isClean,
              try await workspaceCheckpoint.workspace(at: path) == expectedWorkspace else {
            throw ReviewLoopError("The checkout changed before pushing. Inspect it before resuming.")
        }
        guard try await workspaceCheckpoint.resolveCommit(commit, at: path) == commit,
              try await workspaceCheckpoint.isAncestor(commit, of: expectedWorkspace.revision, at: path) else {
            throw ReviewLoopError("The reported fix commit is not in the current checkout history. Inspect it before pushing.")
        }
        let remotes = try await ReviewGitCommand.output(["remote"], at: path).split(separator: "\n").map(String.init)
        let branch = git.branch
        let configuredRemote = try await configuration("branch.\(branch).remote", at: path)
        let configuredMerge = try await configuration("branch.\(branch).merge", at: path)
        let remote: String
        let destination: String
        let needsUpstream: Bool
        if let configuredRemote, let configuredMerge {
            remote = configuredRemote
            destination = configuredMerge
            needsUpstream = false
        } else {
            guard let selected = remotes.contains("origin") ? "origin" : remotes.count == 1 ? remotes.first : nil else {
                throw ReviewLoopError("Push needs a remote: configure a branch upstream, origin, or a single remote, then resume the loop.")
            }
            remote = selected
            destination = "refs/heads/" + branch
            needsUpstream = true
        }
        guard remotes.contains(remote), destination.hasPrefix("refs/heads/") else {
            throw ReviewLoopError("Push needs a configured remote branch upstream. Inspect the branch settings before resuming.")
        }
        // Push only the verified commit to one branch, regardless of push.default,
        // followTags, mirror, or force settings. Git rejects non-fast-forward updates.
        do {
            let remoteRef = try await Subprocess.run(executableURL: URL(fileURLWithPath: "/usr/bin/env"),
                arguments: ["GIT_TERMINAL_PROMPT=0", "/usr/bin/git", "-C", path,
                            "ls-remote", "--exit-code", "--refs", "--", remote, destination], timeout: 60)
            guard remoteRef.terminationStatus == 0 || remoteRef.terminationStatus == 2 else {
                throw ReviewLoopError(String(decoding: remoteRef.standardError, as: UTF8.self))
            }
            var remoteCommit: String?
            if remoteRef.terminationStatus == 0 {
                // Fetch the actual destination, including commits absent from this checkout.
                // Never fetch into or rewrite the local branch.
                let fetched = try await Subprocess.run(executableURL: URL(fileURLWithPath: "/usr/bin/env"),
                    arguments: ["GIT_TERMINAL_PROMPT=0", "/usr/bin/git", "-C", path,
                                "fetch", "--no-tags", "--no-recurse-submodules", "--", remote, destination], timeout: 60)
                guard fetched.terminationStatus == 0 else {
                    throw ReviewLoopError(String(decoding: fetched.standardError, as: UTF8.self))
                }
                remoteCommit = try await ReviewGitCommand.output(["rev-parse", "FETCH_HEAD^{commit}"], at: path)
            }
            var alreadyPublished = false
            var commitToPublish = commit
            if let remoteCommit {
                alreadyPublished = try await workspaceCheckpoint.isAncestor(commit, of: remoteCommit, at: path)
                if !alreadyPublished, !(try await workspaceCheckpoint.isAncestor(remoteCommit, of: commit, at: path)) {
                    if try await workspaceCheckpoint.isAncestor(remoteCommit, of: expectedWorkspace.revision, at: path) {
                        // The current HEAD has been reverified by the coordinator and includes
                        // both histories. Publish it rather than retrying the pre-merge fix.
                        commitToPublish = expectedWorkspace.revision
                    } else {
                        guard try await workspaceCheckpoint.workspace(at: path) == expectedWorkspace else {
                            throw ReviewLoopError("The checkout changed during remote synchronization.")
                        }
                        try await mergeRemote(remoteCommit, at: path)
                        return .verificationRequired(try await workspaceCheckpoint.workspace(at: path))
                    }
                }
            }
            if !alreadyPublished {
                guard try await workspaceCheckpoint.workspace(at: path) == expectedWorkspace else {
                    throw ReviewLoopError("The checkout changed during remote synchronization.")
                }
                let result = try await Subprocess.run(executableURL: URL(fileURLWithPath: "/usr/bin/env"),
                    arguments: ["GIT_TERMINAL_PROMPT=0", "/usr/bin/git", "-C", path,
                                "push", "--no-force", "--no-mirror", "--no-follow-tags", "--recurse-submodules=no",
                                "--", remote, commitToPublish + ":" + destination], timeout: 60)
                guard result.terminationStatus == 0 else {
                    throw ReviewLoopError(String(decoding: result.standardError, as: UTF8.self)
                        .trimmingCharacters(in: .whitespacesAndNewlines))
                }
            }
        } catch {
            throw ReviewLoopError("Remote publication failed: \(error.localizedDescription) Inspect the remote and resume to retry.")
        }
        if needsUpstream {
            _ = try await ReviewGitCommand.output(["config", "branch.\(branch).remote", remote], at: path)
            _ = try await ReviewGitCommand.output(["config", "branch.\(branch).merge", destination], at: path)
        }
        return .published
    }

    private func mergeRemote(_ commit: String, at path: String) async throws {
        // A clean index can still belong to an unfinished merge or rebase.
        // Never abort or continue an operation initiated by somebody else.
        let operationNames = ["MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD", "rebase-merge", "rebase-apply"]
        for name in operationNames {
            let operationPath = try await ReviewGitCommand.output(["rev-parse", "--path-format=absolute", "--git-path", name], at: path)
            guard !FileManager.default.fileExists(atPath: operationPath) else {
                throw ReviewLoopError("Finish the existing Git operation before synchronizing remote changes, then resume.")
            }
        }
        do {
            let merge = try await ReviewGitCommand.run(["merge", "--no-edit", "--no-ff", "--no-autostash", commit], at: path, timeout: 60)
            guard merge.terminationStatus == 0 else {
                throw ReviewLoopError("Remote changes could not be merged automatically. Resolve the histories in the review chat, then resume. "
                    + String(decoding: merge.standardOutput + merge.standardError, as: UTF8.self))
            }
        } catch {
            // Abort only our own failed merge, including one interrupted by a timeout.
            let mergePath = try await ReviewGitCommand.output(["rev-parse", "--path-format=absolute", "--git-path", "MERGE_HEAD"], at: path)
            if FileManager.default.fileExists(atPath: mergePath) {
                _ = try await ReviewGitCommand.output(["merge", "--abort"], at: path)
            }
            throw error
        }
    }

    private func configuration(_ key: String, at path: String) async throws -> String? {
        let result = try await ReviewGitCommand.run(["config", "--get", key], at: path)
        if result.terminationStatus == 1 { return nil }
        guard result.terminationStatus == 0 else { throw ReviewLoopError("Could not read the branch push configuration.") }
        return String(decoding: result.standardOutput, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

}
