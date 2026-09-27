import Foundation

/// A readable Markdown contract. Missing or inconsistent fields stop the loop;
/// prose alone must never be mistaken for a clean review or a committed fix.
enum ReviewReportContract {
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

            Report only \(limit.included.joined(separator: ", ")) findings. Repeat the finding section for each, replacing P? with its actual priority. N is the number reported; if zero, omit finding sections. If blocked, use # Review blocked and explain why in Summary.
            """
            } else {
                format = """
            # Review complete
            Findings: N

            ## Summary
            Brief summary.

            ## Short title
            Evidence, impact, and linked file location.

            Report all actionable findings without priority labels or rankings. Repeat the finding section for each. N is the number reported; if zero, omit finding sections. If blocked, use # Review blocked and explain why in Summary.
            """
            }
        case .fix:
            format = """
            # Fixes committed
            Findings addressed: N
            Commit: `FULL_COMMIT_ID`

            ## Summary
            Brief description of changes.

            N is the number addressed. Use the full Git commit ID. If blocked, use # Fixes blocked, Commit: `none`, and explain why in Summary.
            """
        }
        return """
        Return only Markdown in this structure:
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

    static func fix(_ text: String?) throws -> ReviewRoundResult {
        let sections = try sections(text)
        let header = lines(sections[0])
        guard sections.count == 2, header.count == 3,
              let outcome = ["# Fixes committed": ReviewRoundResult.Outcome.fixed, "# Fixes blocked": .blocked][header[0]],
              let count = count(header[1], prefix: "Findings addressed: "),
              header[2].hasPrefix("Commit: `"), header[2].hasSuffix("`") else { throw invalid() }
        let commit = String(header[2].dropFirst(9).dropLast())
        guard !commit.isEmpty, !commit.contains("`"), outcome != .fixed || commit != "none" else { throw invalid() }
        return ReviewRoundResult(outcome: outcome, findingCount: count, commit: outcome == .blocked ? "" : commit,
                                 summary: try content(sections[1], prefix: "Summary\n"))
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
