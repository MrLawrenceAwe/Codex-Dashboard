import XCTest
@testable import CodexDashboard

final class ReviewReportContractTests: XCTestCase {
    private let review = """
    # Review complete

    ## Summary
    Found two issues. Validation passed.

    ## [P1] Stop can be undone
    An `await` can resume with stale state.

    See [Coordinator.swift](/tmp/Coordinator.swift:12).

    ## [P2] An older paste can overwrite a newer one
    Track the latest read before updating the image.
    """

    func testReadsReadableFindingsWithLinksAndParagraphs() throws {
        let report = try ReviewReportContract.review(review.replacingOccurrences(of: "\n", with: "\r\n"), priorityLimit: .p3)
        XCTAssertEqual(report.outcome, .reviewed)
        XCTAssertEqual(report.findings.map(\.priority), [.p1, .p2])
        XCTAssertEqual(report.findings[0].title, "Stop can be undone")
        XCTAssertTrue(report.findings[0].body.contains("\n\nSee [Coordinator.swift](/tmp/Coordinator.swift:12)."))
        XCTAssertEqual(report.summary, "Found two issues. Validation passed.")
    }

    func testCleanAndBlockedReviewsAreDistinct() throws {
        let clean = "# Review complete\n\n## Summary\nNo issues found."
        XCTAssertEqual(try ReviewReportContract.review(clean, priorityLimit: .p3).findings, [])
        XCTAssertEqual(try ReviewReportContract.review(clean.replacingOccurrences(of: "complete", with: "blocked"), priorityLimit: .p3).outcome, .blocked)
    }

    func testUnprioritisedReportAcceptsPlainFindingsAndRejectsPriorityLabels() throws {
        let text = "# Review complete\n\n## Summary\nOne improvement.\n\n## Simplify the layout\nThe duplicated layout code can be shared."
        let report = try ReviewReportContract.review(text, priorityLimit: nil)
        XCTAssertEqual(report.findings.count, 1)
        XCTAssertNil(report.findings[0].priority)
        XCTAssertEqual(report.findings[0].title, "Simplify the layout")
        XCTAssertThrowsError(try ReviewReportContract.review(text.replacingOccurrences(of: "## Simplify", with: "## [P2] Simplify"), priorityLimit: nil))
        XCTAssertThrowsError(try ReviewReportContract.review(text, priorityLimit: .p2))
        XCTAssertTrue(ReviewReportContract.instructions(for: .review(nil)).contains("without priority labels"))
    }

    func testPriorityInstructionsExplicitlyListAllowedPriorities() {
        for limit in ReviewFinding.Priority.allCases {
            let allowed = ReviewFinding.Priority.allCases.filter { $0.rank <= limit.rank }.map(\.rawValue).joined(separator: ", ")
            let instructions = ReviewReportContract.instructions(for: .review(limit))
            XCTAssertTrue(instructions.contains("Report only priorities \(allowed). Omit lower-priority findings."))
            XCTAssertFalse(instructions.contains("\(limit.rawValue)+"))
        }
    }

    func testFindingSectionsDetermineTotalRegardlessOfSummaryCount() throws {
        for priority: ReviewFinding.Priority? in [nil, .p2] {
            let findings = (1...22).map { number in
                "## \(priority.map { "[\($0.rawValue)] " } ?? "")Improvement \(number)\nImpact and location."
            }.joined(separator: "\n\n")
            let text = "# Review complete\n\n## Summary\nFound 21 improvements.\n\n" + findings
            let report = try ReviewReportContract.review(text, priorityLimit: priority)
            XCTAssertEqual(report.findings.count, 22)
            XCTAssertEqual(report.findings.last?.title, "Improvement 22")
            XCTAssertEqual(report.findings.last?.priority, priority)
        }
    }

    func testReviewInstructionsDelegateCountingToDashboard() {
        for kind in [ReviewTurnKind.review(.p2), .review(nil)] {
            let instructions = ReviewReportContract.instructions(for: kind)
            XCTAssertFalse(instructions.contains("Findings:"))
            XCTAssertTrue(instructions.contains("counts finding sections automatically"))
            XCTAssertTrue(instructions.contains("If there are no findings, omit finding sections"))
        }
    }

    func testMalformedReportsExplainHowToCorrectThem() {
        let cases: [(String?, String)] = [
            (nil, "no final response"),
            ("# Review complete", "needs a '## Summary' section"),
            (review.replacingOccurrences(of: "# Review complete", with: "# Review complete\nFindings: 21"), "omit the findings total"),
            (review.replacingOccurrences(of: "## Summary", with: "## Other"), "first section must be '## Summary'"),
            ("# Review complete\n\n## Summary\n", "section is empty"),
            (review + "\n\n## [P2] Missing description", "Finding 3 needs a title and a description"),
            (review.replacingOccurrences(of: "[P1]", with: "[P4]"), "Finding 1 needs a [P0]"),
            ("```markdown\n" + review + "\n```", "no code fences")
        ]
        for (text, reason) in cases {
            XCTAssertThrowsError(try ReviewReportContract.review(text, priorityLimit: .p3)) { error in
                XCTAssertTrue(error.localizedDescription.contains(reason), error.localizedDescription)
                XCTAssertTrue(error.localizedDescription.contains("corrected report, then Resume"))
            }
        }
    }

    func testReviewInstructionsDoNotRequestEvidence() {
        for kind in [ReviewTurnKind.review(.p2), .review(nil)] {
            let instructions = ReviewReportContract.instructions(for: kind)
            XCTAssertFalse(instructions.lowercased().contains("evidence"))
            XCTAssertTrue(instructions.contains("Impact and linked file location."))
        }
    }

    func testMalformedOrIncompleteReviewsFailClosed() {
        for text: String? in [nil, "Done", "{}",
                            review.replacingOccurrences(of: "[P1]", with: "[P4]"),
                            review.replacingOccurrences(of: "## Summary", with: "## Other"),
                            "```markdown\n" + review + "\n```",
                            "# Review complete\n\n## Summary\n",
                            review + "\n# Review complete",
                            review + "\n\n## [P2] Empty finding\n\n",
                            review.replacingOccurrences(of: "[P1] Stop can be undone", with: "[P1] ")] {
            XCTAssertThrowsError(try ReviewReportContract.review(text, priorityLimit: .p3))
        }
    }

    func testFixReportRequiresExplicitCountCommitAndSummary() throws {
        let text = "# Fixes committed\n\nFindings addressed: 2\nFindings withdrawn: none\nCommit: `abc1234`\n\n## Summary\nFixed both races."
        let result = try ReviewReportContract.fix(text).result
        XCTAssertEqual(result.outcome, .fixed)
        XCTAssertEqual(result.addressedFindingCount, 2)
        XCTAssertEqual(result.commit, "abc1234")
        XCTAssertEqual(result.summary, "Fixed both races.")
        let blocked = text.replacingOccurrences(of: "committed", with: "blocked").replacingOccurrences(of: "abc1234", with: "none")
        XCTAssertEqual(try ReviewReportContract.fix(blocked).result.outcome, .blocked)
        for invalid in [text.replacingOccurrences(of: "abc1234", with: "none"),
                        text.replacingOccurrences(of: "Findings addressed: 2", with: "Findings addressed: -1"),
                        text.replacingOccurrences(of: "Commit: `abc1234`", with: ""),
                        text + "\n## Extra\nUnexpected"] {
            XCTAssertThrowsError(try ReviewReportContract.fix(invalid))
        }
    }

    func testFixReportTracksWithdrawnFindingNumbersWithoutEvidence() throws {
        let text = "# Fixes committed\nFindings addressed: 1\nFindings withdrawn: 2\nCommit: `abc1234`\n\n## Summary\nFixed one issue; the other was invalid."
        let report = try ReviewReportContract.fix(text)
        XCTAssertEqual(report.result.addressedFindingCount, 1)
        XCTAssertEqual(report.withdrawn, [2])
        for invalid in [text.replacingOccurrences(of: "Findings withdrawn: 2", with: "Findings withdrawn: 0"),
                        text.replacingOccurrences(of: "Findings withdrawn: 2", with: "Findings withdrawn: 2, 2"),
                        text.replacingOccurrences(of: "Findings withdrawn: 2", with: "Findings withdrawn: "),
                        text + "\n\n## Extra\nUnexpected"] {
            XCTAssertThrowsError(try ReviewReportContract.fix(invalid))
        }
        let allWithdrawn = "# Findings withdrawn\nFindings addressed: 0\nFindings withdrawn: 1\nCommit: `none`\n\n## Summary\nThe finding was invalid."
        XCTAssertEqual(try ReviewReportContract.fix(allWithdrawn).result.outcome, .withdrawn)
    }

    func testExtensionReloadRequestRequiresDedicatedCompleteReport() throws {
        let request = "# Extension reload required\n\n## Summary\nReload Example in Chrome."
        XCTAssertEqual(try ReviewReportContract.extensionReloadRequest(request), "Reload Example in Chrome.")
        XCTAssertEqual(try ReviewReportContract.extensionReloadRequest(request.replacingOccurrences(of: "\n", with: "\r\n")), "Reload Example in Chrome.")
        XCTAssertNil(try ReviewReportContract.extensionReloadRequest("Please reload the extension."))
        for invalid in ["# Extension reload required", request + "\n## Extra\nOther", request.replacingOccurrences(of: "Reload Example in Chrome.", with: "")] {
            XCTAssertThrowsError(try ReviewReportContract.extensionReloadRequest(invalid))
        }
        for kind in [ReviewTurnKind.review(.p2), .review(nil), .fix, .fixAfterReload] {
            XCTAssertTrue(ReviewReportContract.instructions(for: kind).contains("# Extension reload required"))
        }
    }

    func testRoundResultUsesAddressedFindingCount() throws {
        let stored = Data(#"{"outcome":"fixed","addressedFindingCount":2,"commit":"abc1234","summary":"Done"}"#.utf8)
        let result = try JSONDecoder().decode(ReviewRoundResult.self, from: stored)
        XCTAssertEqual(result.addressedFindingCount, 2)
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(result)) as? [String: Any]
        XCTAssertEqual(encoded?["addressedFindingCount"] as? Int, 2)
        XCTAssertNil(encoded?["findings"])
    }
}
