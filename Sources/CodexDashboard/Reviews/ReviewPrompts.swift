import Foundation

enum ReviewPrompts {
    static func verifyFix(for loop: ReviewLoop, round: ReviewRound, commit: String) -> String {
        let findings = round.review?.findings(upTo: loop.priorityLimit).enumerated().map { index, finding in
            "Finding \(index + 1): \(finding.title)\n\(finding.body)"
        }.joined(separator: "\n\n") ?? ""
        return """
        Reverify the original findings at current HEAD `\(commit)`. The branch advanced after the fix report; Git ancestry alone does not establish that the fixes still work.

        This is a read-only verification. Inspect the actual current code and changes since the reported fix, and run focused checks that exercise each original failure. Check that later commits have not reverted or broken the fixes. Recheck the reasoning for withdrawn findings. Do not edit files, create commits, or push. If HEAD changes during verification, report the verification as blocked.

        Return a review report. Report any original finding still present or any fix regression as a finding. A report with no findings must explain the evidence and checks confirming the fixes at this HEAD. If verification cannot be completed, return a blocked review report.

        Original findings:
        \(findings)
        """ + structureReviewInstruction(for: loop, verifyingFixes: true)
            + bugVerificationInstruction(for: loop, verifyingFixes: true)
            + extensionReloadInstruction(for: loop, verifyingFixes: true) + mutedMediaInstruction(for: loop)
    }

    private static func bugVerificationInstruction(for loop: ReviewLoop, verifyingFixes: Bool = false) -> String {
        guard verifyingFixes && loop.liveTesting && (loop.reviewType == .bugs || loop.reviewType == .bugsAndPerformance) else { return "" }
        return "\n\nFor findings discovered through code review, use live testing to verify bugs and their fixes only when necessary. Verify fixes for findings discovered through live testing using live testing. Connect DevTools, launch test UI, or reload extensions for verification only when live testing is needed."
    }

    private static func structureReviewInstruction(for loop: ReviewLoop, verifyingFixes: Bool = false) -> String {
        guard loop.reviewType == .organisation || loop.reviewType == .organisationAndNaming else { return "" }
        let verification = verifyingFixes
            ? "Inspect source, call sites, tests, docs, and manifests; run relevant builds, type checks, and automated checks without launching a browser or app UI."
            : "Statically inspect source, call sites, tests, docs, and manifests."
        return "\n\nScope: \(loop.reviewType.scopeDescription) \(verification) No live or UI testing, Computer Use, or extension reloads unless explicitly requested for this task, even under general extension-development instructions."
    }

    private static func extensionReloadInstruction(for loop: ReviewLoop, verifyingFixes: Bool = false) -> String {
        guard loop.liveTesting && loop.reviewType.supportsLiveTesting && loop.reloadExtensionBeforeTesting else { return "" }
        let timing = verifyingFixes
            ? "After changes, run any required build and reload the same extension before live verification."
            : "Reload the browser extension before live testing to establish the current behaviour."
        let condition = verifyingFixes && (loop.reviewType == .bugs || loop.reviewType == .bugsAndPerformance)
            ? "\n\nFollow these extension reload instructions only when live verification is needed." : ""
        return condition + "\n\nUse the globally configured chrome-devtools MCP server for Chrome extension reloads. Identify the installed extension ID and source folder with list_extensions and project context, then use reload_extension. Prefer these tools over Computer Use on chrome://extensions. \(timing) Verify reload success, refresh affected test pages, and reopen the popup or side panel as needed with trigger_extension_action. If the tools are unavailable or reload fails, explain the reason and return # Extension reload required using the required report format; do not claim verification is complete." + "\n\n" + ReviewReportContract.extensionReloadInstructions
    }

    private static func mutedMediaInstruction(for loop: ReviewLoop) -> String {
        loop.liveTesting && loop.reviewType.supportsLiveTesting && loop.muteMedia
            ? "\n\nMute only media playback that you start or cause to start for live testing, including autoplay in test tabs you open. Mute that specific test tab or player before playback and keep it muted after navigation or extension reloads. Leave the user’s existing playback and mute/volume settings untouched, including TikTok picture-in-picture. Never mute the entire browser or system audio. Use separate test tabs when needed and verify that only your test playback is muted."
            : ""
    }

    static func interruptedContinuation(for loop: ReviewLoop, round: ReviewRound) -> String {
        let task = round.fixRequested
            ? "Continue the unfinished fix and verification task from where you stopped. Inspect and preserve existing changes and any commit already made; do not repeat completed work. Finish addressing the accepted findings, then return the final fix report with the resulting commit."
            : "Continue the unfinished read-only review from where you stopped, then return the final review report. Leave the checkout unchanged; fixes follow after acceptance."
        return task + structureReviewInstruction(for: loop, verifyingFixes: round.fixRequested)
            + bugVerificationInstruction(for: loop, verifyingFixes: round.fixRequested)
            + extensionReloadInstruction(for: loop, verifyingFixes: round.fixRequested)
            + mutedMediaInstruction(for: loop)
    }

    static func extensionReloadContinuation(for loop: ReviewLoop, round: ReviewRound) -> String {
        if loop.reviewType == .organisation || loop.reviewType == .organisationAndNaming {
            return (round.fixRequested
                ? "Continue the unfinished fix task. Preserve existing changes and return the final fix report."
                : "Continue the unfinished read-only review and return the final review report.")
                + structureReviewInstruction(for: loop, verifyingFixes: round.fixRequested)
        }
        return "The user confirmed that the browser extension has been manually reloaded. Continue the unfinished "
            + (round.fixRequested ? "fix and verification task. Preserve existing changes, finish verification, and return the final fix report." : "read-only review and return the final review report.")
            + " If another manual reload is needed, return the extension reload request again."
            + "\n\n" + ReviewReportContract.extensionReloadInstructions
            + bugVerificationInstruction(for: loop, verifyingFixes: round.fixRequested)
            + mutedMediaInstruction(for: loop)
    }

    static func reviewPrompt(for loop: ReviewLoop) -> String {
        let context = loop.reviewType.supportsProjectContext ? loop.promptContext.promptSuffix : ""
        let task: String
        switch loop.reviewType {
        case .bugs:
            task = "Review project for bugs and issues\(context)."
        case .bugsAndPerformance:
            task = "Review project for bugs, issues, performance and responsiveness\(context)."
        case .organisation:
            task = "Review code and content for simplification and organisation\(context)."
        case .organisationAndNaming:
            task = "Review code and content for simplification, organisation, and unclear, verbose, over-abbreviated, or misleading names\(context)."
        case .performance:
            task = "Review project for performance and responsiveness\(context)."
        case .content:
            task = "Review project for content accuracy, clarity, wording, consistency, completeness, presentation, and effectiveness for its intended purpose\(context)."
        }
        let liveTesting = loop.liveTesting && loop.reviewType.supportsLiveTesting
            ? "\n\nUse code review and live testing to find bugs and issues."
            : ""
        return task + "\n\nRead-only review; fixes follow after acceptance." + structureReviewInstruction(for: loop) + liveTesting + extensionReloadInstruction(for: loop) + mutedMediaInstruction(for: loop)
    }

    static func fixPrompt(for loop: ReviewLoop, round: ReviewRound) -> String {
        let accepted = round.review?.findings(upTo: loop.priorityLimit) ?? []
        let findings: String
        switch accepted.count {
        case 1: findings = "the finding"
        case 2: findings = "both findings"
        default: findings = "all findings"
        }
        let task: String
        switch loop.reviewType {
        case .bugs, .bugsAndPerformance:
            task = "Fix \(findings) and commit"
        case .organisation, .organisationAndNaming, .content, .performance:
            task = "Address \(findings) and commit"
        }
        var prompt = task + ". Verify each finding first. Mark invalid findings as withdrawn; if all are invalid, make no commit."
        prompt += structureReviewInstruction(for: loop, verifyingFixes: true)
        prompt += bugVerificationInstruction(for: loop, verifyingFixes: true)
        if loop.liveTesting && loop.reviewType == .performance {
            prompt += "\n\nVerify fixes for findings discovered through live testing using live testing."
        }
        prompt += extensionReloadInstruction(for: loop, verifyingFixes: true) + mutedMediaInstruction(for: loop)
        guard let review = round.review, accepted.count != review.findings.count else { return prompt }
        let scope = review.findings.enumerated().compactMap { index, finding -> String? in
            guard accepted.contains(finding) else { return nil }
            let priority = finding.priority.map { "[\($0.rawValue)] " } ?? ""
            return "- Finding \(index + 1): \(priority)\(finding.title)"
        }.joined(separator: "\n")
        return prompt
            + "\n\nAddress only these findings from the review. Use their original numbers for withdrawn findings:\n\n" + scope
    }
}
