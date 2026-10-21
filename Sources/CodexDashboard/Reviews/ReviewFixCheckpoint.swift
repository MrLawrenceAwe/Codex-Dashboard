import Foundation

/// Validates a completed fix report without changing loop state or publishing commits.
enum ReviewFixCheckpoint {
    static func validateFindings(
        _ fixReport: ReviewReportContract.FixReport,
        against review: ReviewReport,
        priorityLimit: ReviewFinding.Priority?
    ) throws {
        let findings = review.findings(upTo: priorityLimit)
        let acceptedNumbers = Set(review.findings.enumerated().compactMap { index, finding in
            findings.contains(finding) ? index + 1 : nil
        })
        let accountedCount = fixReport.result.addressedFindingCount + fixReport.withdrawn.count
        guard accountedCount == findings.count,
              fixReport.withdrawn.allSatisfy({ acceptedNumbers.contains($0) }) else {
            throw ReviewLoopError("Fix checkpoint failed: the fix report accounted for \(accountedCount) of \(findings.count) findings.")
        }
    }

    @MainActor
    static func validateCommit(
        _ reportedCommit: String, result: ReviewRoundResult, baseRevision: String,
        workspace: ReviewWorkspaceState, at path: String, using driver: any ReviewLoopDriving
    ) async throws {
        if result.outcome == .fixed {
            guard reportedCommit != baseRevision else {
                throw ReviewLoopError("Commit checkpoint failed: no new fix commit was created.")
            }
            guard try await driver.isAncestor(baseRevision, of: reportedCommit, at: path) else {
                throw ReviewLoopError("Commit checkpoint failed: the fix commit is not a descendant of the starting commit.")
            }
        }
        if workspace.revision != reportedCommit {
            guard result.outcome == .fixed,
                  try await driver.isAncestor(reportedCommit, of: workspace.revision, at: path) else {
                throw ReviewLoopError("Commit checkpoint failed: the current branch no longer contains the reported fix commit. Restore its history or inspect the changes in the review chat before resuming.")
            }
        }
    }
}
