import Foundation

enum ReviewPrompts {
    private static func structureReviewInstruction(for loop: ReviewLoop, verifyingFixes: Bool = false) -> String {
        guard loop.focus == .organisation || loop.focus == .organisationAndNaming else { return "" }
        let verification = verifyingFixes
            ? "Verify findings and changes by inspecting source, call sites, tests, documentation, and manifests. Run relevant builds, type checks, and automated checks that do not launch or drive a browser or application UI."
            : "Review source files, call sites, tests, documentation, and manifests statically."
        return "\n\nKeep this task within the \(loop.focus.label.lowercased()) review scope: \(loop.focus.scopeDescription) \(verification) Do not perform live testing, browser or UI testing, Computer Use, or extension reloads unless the user explicitly requests them for this task. General extension-development verification instructions do not require live testing for this structure review loop."
    }

    private static func extensionReloadInstruction(for loop: ReviewLoop, verifyingFixes: Bool = false) -> String {
        guard loop.liveTesting && loop.focus.supportsLiveTesting && loop.reloadExtensionBeforeTesting else { return "" }
        let timing = verifyingFixes
            ? "After changes, run any required build and reload the same extension before live verification."
            : "Reload the browser extension before live testing to establish the current behaviour."
        return "\n\nUse the globally configured chrome-devtools MCP server for Chrome extension reloads. Identify the installed extension ID and source folder with list_extensions and project context, then use reload_extension. Prefer these tools over Computer Use on chrome://extensions. \(timing) Verify reload success, refresh affected test pages, and reopen the popup or side panel as needed with trigger_extension_action. If the tools are unavailable or reload fails, explain the reason and return # Extension reload required using the required report format; do not claim verification is complete." + "\n\n" + ReviewReportContract.extensionReloadInstructions
    }

    private static func mutedMediaInstruction(for loop: ReviewLoop) -> String {
        loop.liveTesting && loop.focus.supportsLiveTesting && loop.muteMedia
            ? "\n\nMute only media playback that you start or cause to start for live testing, including autoplay in test tabs you open. Mute that specific test tab or player before playback and keep it muted after navigation or extension reloads. Leave the user’s existing playback and mute/volume settings untouched, including TikTok picture-in-picture. Never mute the entire browser or system audio. Use separate test tabs when needed and verify that only your test playback is muted."
            : ""
    }

    static func extensionReloadContinuation(for loop: ReviewLoop, round: ReviewRound) -> String {
        if loop.focus == .organisation || loop.focus == .organisationAndNaming {
            return (round.fixRequested
                ? "Continue the unfinished fix task. Preserve existing changes and return the final fix report."
                : "Continue the unfinished read-only review and return the final review report.")
                + structureReviewInstruction(for: loop, verifyingFixes: round.fixRequested)
        }
        return "The user confirmed that the browser extension has been manually reloaded. Continue the unfinished "
            + (round.fixRequested ? "fix and verification task. Preserve existing changes, finish verification, and return the final fix report." : "read-only review and return the final review report.")
            + " If another manual reload is needed, return the extension reload request again."
            + "\n\n" + ReviewReportContract.extensionReloadInstructions
            + mutedMediaInstruction(for: loop)
    }

    static func reviewPrompt(for loop: ReviewLoop) -> String {
        let context = loop.focus.supportsProjectContext ? loop.promptContext.promptSuffix : ""
        let task: String
        switch loop.focus {
        case .bugs:
            task = "Review project for bugs and issues\(context)."
        case .bugsAndPerformance:
            task = "Review project for bugs, issues, performance and responsiveness\(context)."
        case .organisation:
            task = "Do a code and content minimisation and organisation review\(context)."
        case .organisationAndNaming:
            task = "Do a code and content minimisation and organisation review, and suggest improvements where naming (e.g. folders, files, classes, variables, functions, UI, etc.) is undescriptive, too long, overly abbreviated, or misleading\(context)."
        case .performance:
            task = "Review project for performance and responsiveness\(context)."
        case .content:
            task = "Review project for content accuracy, clarity, wording, consistency, completeness, presentation, and effectiveness for its intended purpose\(context)."
        }
        let liveTesting = loop.liveTesting && loop.focus.supportsLiveTesting
            ? "\n\nUse code review and live testing to find bugs and issues."
            : ""
        return task + "\n\nThis is a read-only review. Fixes will be requested in a separate follow-up after the review is accepted." + structureReviewInstruction(for: loop) + liveTesting + extensionReloadInstruction(for: loop) + mutedMediaInstruction(for: loop)
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
        switch loop.focus {
        case .bugs, .bugsAndPerformance:
            task = "Fix \(findings) and commit"
        case .organisation, .organisationAndNaming, .content, .performance:
            task = "Address \(findings) and commit"
        }
        var prompt = task + ". Verify each finding first. Mark invalid findings as withdrawn; if all are invalid, make no commit."
        prompt += structureReviewInstruction(for: loop, verifyingFixes: true)
        if loop.liveTesting && loop.focus.supportsLiveTesting {
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
