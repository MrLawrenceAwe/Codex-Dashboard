import XCTest
@testable import CodexDashboard

final class ReviewLoopReportTests: XCTestCase {
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
        let report = try ReviewLoopReport.review(review.replacingOccurrences(of: "\n", with: "\r\n"))
        XCTAssertEqual(report.outcome, .reviewed)
        XCTAssertEqual(report.findings.map(\.priority), [.p1, .p2])
        XCTAssertEqual(report.findings[0].title, "Stop can be undone")
        XCTAssertTrue(report.findings[0].body.contains("\n\nSee [Coordinator.swift](/tmp/Coordinator.swift:12)."))
        XCTAssertEqual(report.summary, "Found two issues. Validation passed.")
    }

    func testCleanAndBlockedReviewsAreDistinct() throws {
        let clean = "# Review complete\nFindings: 0\n\n## Summary\nNo issues found."
        XCTAssertEqual(try ReviewLoopReport.review(clean).findings, [])
        XCTAssertEqual(try ReviewLoopReport.review(clean.replacingOccurrences(of: "complete", with: "blocked")).outcome, .blocked)
    }

    func testMalformedOrIncompleteReviewsFailClosed() {
        for text: String? in [nil, "Done", "{}", review.replacingOccurrences(of: "Findings: 2", with: "Findings: 0"),
                            review.replacingOccurrences(of: "[P1]", with: "[P4]"),
                            review.replacingOccurrences(of: "## Summary", with: "## Other"),
                            "```markdown\n" + review + "\n```",
                            "# Review complete\nFindings: 0\n\n## Summary\n",
                            review + "\n# Review complete\nFindings: 0"] {
            XCTAssertThrowsError(try ReviewLoopReport.review(text))
        }
    }

    func testFixReportRequiresExplicitCountCommitAndSummary() throws {
        let text = "# Fixes committed\n\nFindings addressed: 2\nCommit: `abc1234`\n\n## Summary\nFixed both races."
        let result = try ReviewLoopReport.fix(text)
        XCTAssertEqual(result.outcome, .fixed)
        XCTAssertEqual(result.findings, 2)
        XCTAssertEqual(result.commit, "abc1234")
        XCTAssertEqual(result.summary, "Fixed both races.")
        let blocked = text.replacingOccurrences(of: "committed", with: "blocked").replacingOccurrences(of: "abc1234", with: "none")
        XCTAssertEqual(try ReviewLoopReport.fix(blocked).outcome, .blocked)
        for invalid in [text.replacingOccurrences(of: "abc1234", with: "none"),
                        text.replacingOccurrences(of: "Findings addressed: 2", with: "Findings addressed: -1"),
                        text.replacingOccurrences(of: "Commit: `abc1234`", with: ""),
                        text + "\n## Extra\nUnexpected"] {
            XCTAssertThrowsError(try ReviewLoopReport.fix(invalid))
        }
    }
}
