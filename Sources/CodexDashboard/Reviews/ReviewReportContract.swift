import Foundation

/// A readable Markdown contract. Missing or inconsistent fields stop the loop;
/// prose alone must never be mistaken for a clean review or a committed fix.
enum ReviewReportContract {
    struct FixReport {
        let result: ReviewRoundResult
        let withdrawn: [Int]
    }

    static func instructions(for kind: ReviewTurnKind) -> String {
        let format: String
        switch kind {
        case .review(let limit):
            if let limit {
                format = """
            # Review complete
            Findings: N

            ## Summary
            Brief summary.

            ## [P?] Short title
            Evidence, impact, and linked file location.

            \(limit.rawValue)+. N is the number reported; if zero, omit finding sections. If blocked, use # Review blocked and explain why in Summary.
            """
            } else {
                format = """
            # Review complete
            Findings: N

            ## Summary
            Brief summary.

            ## Short title
            Evidence, impact, and linked file location.

            Report all actionable findings without priority labels or rankings. N is the number reported; if zero, omit finding sections. If blocked, use # Review blocked and explain why in Summary.
            """
            }
        case .fix:
            format = """
            # Fixes committed
            Findings addressed: N
            Findings withdrawn: none or comma-separated review numbers
            Commit: `FULL_COMMIT_ID`

            ## Summary
            Brief description of changes.

            N is the number fixed. List invalid findings by their 1-based position in the review, or use none. If every finding is invalid, use # Findings withdrawn, Findings addressed: 0, and Commit: `none`. If blocked, use # Fixes blocked, Commit: `none`, and explain why in Summary.
            """
        }
        return """
        Apply this format only to your final response, after completing the work. Use Markdown in this structure:
        \(format)
        Keep fixed headings and labels; replace placeholders. No code fences or other level-one or level-two headings.
        """
    }

    static func review(_ text: String?, priorityLimit: ReviewFinding.Priority?) throws -> ReviewReport {
        let sections = try sections(text)
        let header = lines(sections[0])
        guard header.count == 2,
              let outcome = ["# Review complete": ReviewReport.Outcome.reviewed, "# Review blocked": .blocked][header[0]],
              let count = count(header[1], prefix: "Findings: "),
              sections[1].hasPrefix("Summary\n") else { throw invalid() }
        let summary = try content(sections[1], prefix: "Summary\n")
        let findings = try sections.dropFirst(2).map { section -> ReviewFinding in
            guard let newline = section.firstIndex(of: "\n") else { throw invalid() }
            let titleLine = String(section[..<newline])
            let priority: ReviewFinding.Priority?
            let title: String
            if priorityLimit != nil {
                guard titleLine.count > 5, titleLine.hasPrefix("["),
                      titleLine.dropFirst(3).hasPrefix("] "),
                      let parsed = ReviewFinding.Priority(rawValue: String(titleLine.dropFirst().prefix(2))) else { throw invalid() }
                priority = parsed
                title = String(titleLine.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            } else {
                guard !titleLine.isEmpty, !titleLine.hasPrefix("[P0] "),
                      !titleLine.hasPrefix("[P1] "), !titleLine.hasPrefix("[P2] "),
                      !titleLine.hasPrefix("[P3] ") else { throw invalid() }
                priority = nil
                title = titleLine.trimmingCharacters(in: .whitespaces)
            }
            let body = String(section[section.index(after: newline)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty, !body.isEmpty else { throw invalid() }
            return ReviewFinding(priority: priority, title: title, body: body)
        }
        guard count == findings.count else { throw invalid() }
        return ReviewReport(outcome: outcome, findings: findings, summary: summary)
    }

    static func fix(_ text: String?) throws -> FixReport {
        let sections = try sections(text)
        let header = lines(sections[0])
        guard sections.count == 2, header.count == 4,
              let outcome = ["# Fixes committed": ReviewRoundResult.Outcome.fixed,
                             "# Findings withdrawn": .withdrawn,
                             "# Fixes blocked": .blocked][header[0]],
              let addressedCount = count(header[1], prefix: "Findings addressed: "),
              header[2].hasPrefix("Findings withdrawn: "),
              header[3].hasPrefix("Commit: `"), header[3].hasSuffix("`") else { throw invalid() }
        let commit = String(header[3].dropFirst(9).dropLast())
        let withdrawnValue = String(header[2].dropFirst("Findings withdrawn: ".count))
        let withdrawn: [Int]
        if withdrawnValue == "none" {
            withdrawn = []
        } else {
            let numbers = withdrawnValue.components(separatedBy: ", ")
            guard !numbers.isEmpty,
                  numbers.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy({ (48...57).contains($0) }) }),
                  numbers.allSatisfy({ Int($0).map({ $0 > 0 }) == true }) else { throw invalid() }
            withdrawn = numbers.compactMap(Int.init)
        }
        guard !withdrawnValue.isEmpty,
              Set(withdrawn).count == withdrawn.count,
              !commit.isEmpty, !commit.contains("`"),
              (outcome == .fixed && addressedCount > 0 && commit != "none") ||
              (outcome == .withdrawn && addressedCount == 0 && !withdrawn.isEmpty && commit == "none") ||
              (outcome == .blocked && commit == "none") else { throw invalid() }
        return FixReport(result: ReviewRoundResult(outcome: outcome, findingCount: addressedCount,
                                                   commit: outcome == .fixed ? commit : "",
                                                   summary: try content(sections[1], prefix: "Summary\n")),
                         withdrawn: withdrawn)
    }

    private static func sections(_ text: String?) throws -> [String] {
        guard let text else { throw invalid() }
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.contains("```"), !normalized.contains("~~~"),
              !normalized.contains("\n# ") else { throw invalid() }
        let sections = normalized.components(separatedBy: "\n## ")
        guard sections.count >= 2 else { throw invalid() }
        return sections
    }

    private static func lines(_ text: String) -> [String] {
        text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private static func count(_ text: String, prefix: String) -> Int? {
        guard text.hasPrefix(prefix) else { return nil }
        let value = text.dropFirst(prefix.count)
        guard !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
        return Int(value)
    }

    private static func content(_ text: String, prefix: String) throws -> String {
        guard text.hasPrefix(prefix) else { throw invalid() }
        let body = text.dropFirst(prefix.count).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { throw invalid() }
        return body
    }

    private static func invalid() -> ReviewLoopError {
        ReviewLoopError("The task did not return a complete review-loop report. Open its chat to inspect the result.")
    }
}
