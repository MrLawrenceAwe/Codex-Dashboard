import Foundation

/// A readable Markdown contract. Missing or inconsistent fields stop the loop;
/// prose alone must never be mistaken for a clean review or a committed fix.
enum ReviewLoopReport {
    static func instructions(for kind: ReviewTurnKind) -> String {
        let format: String
        switch kind {
        case .review(let limit):
            format = """
            Start with `# Review complete` (or `# Review blocked` if unable to finish).
            On the next nonblank line write `Findings: N`, with the exact finding count.
            Then write `## Summary` and a short summary, including relevant validation.
            For each finding, write `## [P1] Short title` using its actual priority, followed by a paragraph explaining the evidence, impact, and a linked file location. Only include \(limit.included.joined(separator: ", ")) findings.
            Use zero findings only when there are none; keep the Summary section even then.
            """
        case .fix:
            format = """
            Start with `# Fixes committed` (or `# Fixes blocked` if unable to finish).
            On the next nonblank lines write `Findings addressed: N` and `Commit: ` followed by the full Git commit ID in backticks (use `none` when blocked).
            Then write `## Summary` and a concise description of the changes or the blocker.
            """
        }
        return """
        Final response format for this review loop: use readable Markdown, never JSON or an outer code fence.
        \(format)
        Keep these exact headings and field labels so the loop can read the report. Use normal Markdown paragraphs, lists, inline code, and links within sections; do not add other level-one or level-two headings or fenced code blocks.
        """
    }

    static func review(_ text: String?) throws -> ReviewReport {
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
            guard titleLine.count > 5, titleLine.hasPrefix("["),
                  titleLine.dropFirst(3).hasPrefix("] "),
                  let priority = ReviewFinding.Priority(rawValue: String(titleLine.dropFirst().prefix(2))) else { throw invalid() }
            let title = String(titleLine.dropFirst(5)).trimmingCharacters(in: .whitespaces)
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
        return ReviewRoundResult(outcome: outcome, findings: count, commit: outcome == .blocked ? "" : commit,
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
