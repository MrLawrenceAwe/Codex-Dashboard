import XCTest
@testable import CodexDashboard

final class ReviewReportContractTests: XCTestCase {
    private let review = """
    # Review complete

    Findings: 2

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
        let clean = "# Review complete\nFindings: 0\n\n## Summary\nNo issues found."
        XCTAssertEqual(try ReviewReportContract.review(clean, priorityLimit: .p3).findings, [])
        XCTAssertEqual(try ReviewReportContract.review(clean.replacingOccurrences(of: "complete", with: "blocked"), priorityLimit: .p3).outcome, .blocked)
    }

    func testUnprioritisedReportAcceptsPlainFindingsAndRejectsPriorityLabels() throws {
        let text = "# Review complete\nFindings: 1\n\n## Summary\nOne improvement.\n\n## Simplify the layout\nThe duplicated layout code can be shared."
        let report = try ReviewReportContract.review(text, priorityLimit: nil)
        XCTAssertEqual(report.findings.count, 1)
        XCTAssertNil(report.findings[0].priority)
        XCTAssertEqual(report.findings[0].title, "Simplify the layout")
        XCTAssertThrowsError(try ReviewReportContract.review(text.replacingOccurrences(of: "## Simplify", with: "## [P2] Simplify"), priorityLimit: nil))
        XCTAssertThrowsError(try ReviewReportContract.review(text, priorityLimit: .p2))
        XCTAssertTrue(ReviewReportContract.instructions(for: .review(nil)).contains("without priority labels"))
    }

    func testMalformedOrIncompleteReviewsFailClosed() {
        for text: String? in [nil, "Done", "{}", review.replacingOccurrences(of: "Findings: 2", with: "Findings: 0"),
                            review.replacingOccurrences(of: "[P1]", with: "[P4]"),
                            review.replacingOccurrences(of: "## Summary", with: "## Other"),
                            "```markdown\n" + review + "\n```",
                            "# Review complete\nFindings: 0\n\n## Summary\n",
                            review + "\n# Review complete\nFindings: 0"] {
            XCTAssertThrowsError(try ReviewReportContract.review(text, priorityLimit: .p3))
        }
    }

    func testFixReportRequiresExplicitCountCommitAndSummary() throws {
        let text = "# Fixes committed\n\nFindings addressed: 2\nFindings withdrawn: none\nCommit: `abc1234`\n\n## Summary\nFixed both races."
        let result = try ReviewReportContract.fix(text).result
        XCTAssertEqual(result.outcome, .fixed)
        XCTAssertEqual(result.findingCount, 2)
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
        XCTAssertEqual(report.result.findingCount, 1)
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

    func testRoundResultRetainsStoredFindingKey() throws {
        let stored = Data(#"{"outcome":"fixed","findings":2,"commit":"abc1234","summary":"Done"}"#.utf8)
        let result = try JSONDecoder().decode(ReviewRoundResult.self, from: stored)
        XCTAssertEqual(result.findingCount, 2)
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(result)) as? [String: Any]
        XCTAssertEqual(encoded?["findings"] as? Int, 2)
        XCTAssertNil(encoded?["findingCount"])
    }
}
