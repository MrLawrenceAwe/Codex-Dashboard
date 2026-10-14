import Foundation

protocol ReviewRepositoryChecking: Sendable {
    func repository(at path: String) async throws -> ReviewRepositoryState
    func reconcileAndPublishFix(_ commit: String, at path: String, expectedRepository: ReviewRepositoryState) async throws -> ReviewPublicationOutcome
    func resolveCommit(_ commit: String, at path: String) async throws -> String
    func isAncestor(_ commit: String, of head: String, at path: String) async throws -> Bool
}

enum ReviewPublicationOutcome: Equatable, Sendable {
    case published
    case verificationRequired(ReviewRepositoryState)
}

struct ReviewRepositoryCheckpoint: ReviewRepositoryChecking {
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

    func reconcileAndPublishFix(_ commit: String, at path: String, expectedRepository: ReviewRepositoryState) async throws -> ReviewPublicationOutcome {
        guard try await repository(at: path) == expectedRepository, expectedRepository.clean else {
            throw ReviewLoopError("The checkout changed before pushing. Inspect it before resuming.")
        }
        guard try await resolveCommit(commit, at: path) == commit,
              try await isAncestor(commit, of: expectedRepository.commit, at: path) else {
            throw ReviewLoopError("The reported fix commit is not in the current checkout history. Inspect it before pushing.")
        }
        let remotes = try await git(["remote"], at: path).split(separator: "\n").map(String.init)
        let branch = expectedRepository.branch
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
                remoteCommit = try await git(["rev-parse", "FETCH_HEAD^{commit}"], at: path)
            }
            var alreadyPublished = false
            var commitToPublish = commit
            if let remoteCommit {
                alreadyPublished = try await isAncestor(commit, of: remoteCommit, at: path)
                if !alreadyPublished, !(try await isAncestor(remoteCommit, of: commit, at: path)) {
                    if try await isAncestor(remoteCommit, of: expectedRepository.commit, at: path) {
                        // The current HEAD has been reverified by the coordinator and includes
                        // both histories. Publish it rather than retrying the pre-merge fix.
                        commitToPublish = expectedRepository.commit
                    } else {
                        guard try await repository(at: path) == expectedRepository else {
                            throw ReviewLoopError("The checkout changed during remote synchronization.")
                        }
                        try await mergeRemote(remoteCommit, at: path)
                        return .verificationRequired(try await repository(at: path))
                    }
                }
            }
            if !alreadyPublished {
                guard try await repository(at: path) == expectedRepository else {
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
            _ = try await git(["config", "branch.\(branch).remote", remote], at: path)
            _ = try await git(["config", "branch.\(branch).merge", destination], at: path)
        }
        return .published
    }

    private func mergeRemote(_ commit: String, at path: String) async throws {
        // A clean index can still belong to an unfinished merge or rebase.
        // Never abort or continue an operation initiated by somebody else.
        let operationNames = ["MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD", "rebase-merge", "rebase-apply"]
        for name in operationNames {
            let operationPath = try await git(["rev-parse", "--path-format=absolute", "--git-path", name], at: path)
            guard !FileManager.default.fileExists(atPath: operationPath) else {
                throw ReviewLoopError("Finish the existing Git operation before synchronizing remote changes, then resume.")
            }
        }
        do {
            let merge = try await runGit(["merge", "--no-edit", "--no-ff", "--no-autostash", commit], at: path, timeout: 60)
            guard merge.terminationStatus == 0 else {
                throw ReviewLoopError("Remote changes could not be merged automatically. Resolve the histories in the review chat, then resume. "
                    + String(decoding: merge.standardOutput + merge.standardError, as: UTF8.self))
            }
        } catch {
            // Abort only our own failed merge, including one interrupted by a timeout.
            let mergePath = try await git(["rev-parse", "--path-format=absolute", "--git-path", "MERGE_HEAD"], at: path)
            if FileManager.default.fileExists(atPath: mergePath) {
                _ = try await git(["merge", "--abort"], at: path)
            }
            throw error
        }
    }

    private func configuration(_ key: String, at path: String) async throws -> String? {
        let result = try await runGit(["config", "--get", key], at: path)
        if result.terminationStatus == 1 { return nil }
        guard result.terminationStatus == 0 else { throw ReviewLoopError("Could not read the branch push configuration.") }
        return String(decoding: result.standardOutput, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
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

    private func runGit(_ arguments: [String], at path: String, timeout: TimeInterval = 5) async throws -> SubprocessOutput {
        try await Subprocess.run(executableURL: URL(fileURLWithPath: "/usr/bin/git"), arguments: ["--no-optional-locks", "-C", path] + arguments, timeout: timeout)
    }

}
