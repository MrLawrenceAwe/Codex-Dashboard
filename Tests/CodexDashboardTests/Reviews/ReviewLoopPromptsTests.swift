import XCTest
@testable import CodexDashboard

@MainActor
final class ReviewLoopPromptsTests: ReviewLoopTestCase {
    func testFixPromptDoesNotAskForTesting() throws {
        let loop = ReviewLoop(id: UUID(), startActionID: "test", project: ReviewProject(id: "p", name: "Project", path: "/tmp/project"), promptContext: .general, maxRounds: 5)
        let prompt = ReviewPrompts.fixPrompt(for: loop, round: ReviewRound(number: 1, baseRevision: "abc"))
        XCTAssertFalse(prompt.lowercased().contains("test"))
        XCTAssertFalse(prompt.lowercased().contains("checks"))
        XCTAssertEqual(prompt, "Fix all findings and commit. Verify each finding first. Mark invalid findings as withdrawn; if all are invalid, make no commit.")
        XCTAssertFalse(ReviewReportContract.instructions(for: .fix).lowercased().contains("test"))
    }

    func testOrganisationFixPromptNamesFindingsAndCommitForEachCount() {
        for reviewType in [ReviewType.organisation, .organisationAndNaming] {
            var loop = ReviewLoop(id: UUID(), startActionID: "test", project: ReviewProject(id: "p", name: "Project", path: "/tmp/project"), promptContext: .general, maxRounds: 5)
            loop.reviewType = reviewType
            for (count, expected) in [(1, "Address the finding and commit"), (2, "Address both findings and commit"), (3, "Address all findings and commit")] {
                var round = ReviewRound(number: 1, baseRevision: "abc")
                round.review = ReviewReport(outcome: .reviewed, findings: (0..<count).map { index in
                    ReviewFinding(priority: nil, title: "Finding \(index)", body: "Evidence")
                }, summary: "Findings")
                let prompt = ReviewPrompts.fixPrompt(for: loop, round: round)
                XCTAssertEqual(prompt.components(separatedBy: "\n\n").first, expected + ". Verify each finding first. Mark invalid findings as withdrawn; if all are invalid, make no commit.")
            }
        }
    }

    func testLiveDiscoveryMatchesReviewTypeAndUsesConditionalBugVerification() {
        for reviewType in ReviewType.allCases {
            for liveTesting in [false, true] {
                let loop = ReviewLoop(id: UUID(), startActionID: "verification", project: project,
                                      promptContext: .general, maxRounds: 3, reviewType: reviewType,
                                      liveTesting: liveTesting, reloadExtensionBeforeTesting: true)
                var round = ReviewRound(number: 1, baseRevision: "base")
                let review = ReviewPrompts.reviewPrompt(for: loop)
                XCTAssertEqual(review.contains("Use code review and live testing to find bugs and issues."),
                               liveTesting && reviewType == .bugs)
                XCTAssertEqual(review.contains("Use code review and live testing to find performance and responsiveness issues."),
                               liveTesting && reviewType == .performance)
                XCTAssertEqual(review.contains("Use code review and live testing to find bugs, issues, and performance and responsiveness problems."),
                               liveTesting && reviewType == .bugsAndPerformance)
                XCTAssertEqual(review.contains("Measure relevant behaviour"),
                               liveTesting && (reviewType == .performance || reviewType == .bugsAndPerformance))
                XCTAssertFalse(review.contains("only when necessary"))
                let conditional = liveTesting && (reviewType == .bugs || reviewType == .bugsAndPerformance)
                for fixRequested in [false, true] {
                    round.fixRequested = fixRequested
                    for prompt in [ReviewPrompts.interruptedContinuation(for: loop, round: round),
                                   ReviewPrompts.extensionReloadContinuation(for: loop, round: round)] {
                        XCTAssertEqual(prompt.contains("only when necessary"), conditional && fixRequested)
                    }
                }
                for prompt in [ReviewPrompts.fixPrompt(for: loop, round: round),
                               ReviewPrompts.verifyFix(for: loop, round: round, targetRevision: "head")] {
                    XCTAssertEqual(prompt.contains("only when necessary"), conditional)
                    XCTAssertEqual(prompt.contains("Follow these extension reload instructions only when live verification is needed."), conditional)
                    if conditional {
                        XCTAssertTrue(prompt.contains("Verify fixes for findings discovered through live testing using live testing."))
                    }
                }
            }
        }
    }

    func testStructureScopePersistsThroughReviewFixAndReloadContinuation() {
        for reviewType in [ReviewType.organisation, .organisationAndNaming] {
            for liveTesting in [false, true] {
                let loop = ReviewLoop(id: UUID(), startActionID: "structure", project: project,
                                      promptContext: .general, maxRounds: 3, reviewType: reviewType,
                                      liveTesting: liveTesting, reloadExtensionBeforeTesting: true)
                var round = ReviewRound(number: 1, baseRevision: "base")
                let review = ReviewPrompts.reviewPrompt(for: loop)
                let fix = ReviewPrompts.fixPrompt(for: loop, round: round)
                for fixRequested in [false, true] {
                    round.fixRequested = fixRequested
                    let continuation = ReviewPrompts.extensionReloadContinuation(for: loop, round: round)
                    for prompt in [review, continuation] {
                        XCTAssertTrue(prompt.contains(reviewType.scopeDescription))
                        XCTAssertTrue(prompt.contains("No live or UI testing, Computer Use, or extension reloads"))
                        XCTAssertFalse(prompt.contains("# Extension reload required"))
                        XCTAssertFalse(prompt.contains("chrome-devtools MCP server"))
                    }
                    XCTAssertEqual(continuation.contains("run relevant builds"), fixRequested)
                }
                XCTAssertTrue(review.contains("Statically"))
                XCTAssertFalse(review.contains("run relevant builds"))
                XCTAssertEqual(fix.components(separatedBy: "\n\n").last,
                               "Address findings within the original review scope and constraints.")
                XCTAssertFalse(fix.contains(reviewType.scopeDescription))
            }
        }
    }

    func testExtensionReloadRequiresEnabledPreferenceAndLiveTesting() {
        var loop = ReviewLoop(id: UUID(), startActionID: "extension", project: project,
                              promptContext: .general, maxRounds: 3, liveTesting: true)
        let round = ReviewRound(number: 1, baseRevision: "base")
        for reviewType in ReviewType.allCases {
            loop.reviewType = reviewType
            for (liveTesting, reload) in [(true, true), (true, false), (false, true), (false, false)] {
                loop.liveTesting = liveTesting
                loop.reloadExtensionBeforeTesting = reload
                for prompt in [ReviewPrompts.reviewPrompt(for: loop), ReviewPrompts.fixPrompt(for: loop, round: round)] {
                    XCTAssertEqual(prompt.contains("chrome-devtools MCP server"), liveTesting && reload && reviewType.supportsLiveTesting)
                    XCTAssertEqual(prompt.contains("# Extension reload required"), liveTesting && reload && reviewType.supportsLiveTesting)
                    if liveTesting && reload && reviewType.supportsLiveTesting {
                        XCTAssertTrue(prompt.contains("Verify the original extension ID and enabled state"))
                        XCTAssertTrue(prompt.contains("For the everyday Chrome profile, use Chrome Computer Use"))
                        XCTAssertTrue(prompt.contains("only in an explicitly temporary test profile"))
                        XCTAssertTrue(prompt.contains("INSTALLED_VIA_CDP (bit 32768)"))
                        XCTAssertTrue(prompt.contains("back up the existing registration and extension storage"))
                        XCTAssertTrue(prompt.contains("Clean up DevTools debugging connections"))
                        XCTAssertTrue(prompt.contains("including on failure or cancellation"))
                        XCTAssertTrue(prompt.contains("verify its debugging socket is closed"))
                        XCTAssertTrue(prompt.contains("Never stop another task's connection"))
                        XCTAssertTrue(prompt.contains("explain the remaining connection and how to disconnect it"))
                        XCTAssertFalse(prompt.contains("Prefer these tools over Computer Use"))
                        XCTAssertTrue(prompt.contains("return # Extension reload required"))
                    }
                }
            }
        }
    }

    func testMuteTestPlaybackAppliesToReviewAndFixOnlyWithLiveTesting() {
        var loop = ReviewLoop(id: UUID(), startActionID: "muted", project: project,
                              promptContext: .general, maxRounds: 3, liveTesting: true, muteTestPlayback: true)
        let round = ReviewRound(number: 1, baseRevision: "base")
        for reviewType in ReviewType.allCases {
            loop.reviewType = reviewType
            XCTAssertEqual(ReviewPrompts.reviewPrompt(for: loop).contains("Mute only media playback that you start"), reviewType.supportsLiveTesting)
            XCTAssertEqual(ReviewPrompts.fixPrompt(for: loop, round: round).contains("Mute only media playback that you start"), reviewType.supportsLiveTesting)
        }
        loop.reviewType = .bugs
        for prompt in [ReviewPrompts.reviewPrompt(for: loop), ReviewPrompts.fixPrompt(for: loop, round: round)] {
            XCTAssertTrue(prompt.contains("including autoplay in test tabs you open"))
            XCTAssertTrue(prompt.contains("Leave the user’s existing playback and mute/volume settings untouched, including TikTok picture-in-picture"))
            XCTAssertTrue(prompt.contains("Never mute the entire browser or system audio"))
        }
        loop.liveTesting = false
        XCTAssertFalse(ReviewPrompts.reviewPrompt(for: loop).contains("Mute only media playback"))
        XCTAssertFalse(ReviewPrompts.fixPrompt(for: loop, round: round).contains("Mute only media playback"))
        loop.liveTesting = true
        loop.muteTestPlayback = false
        XCTAssertFalse(ReviewPrompts.reviewPrompt(for: loop).contains("Mute only media playback"))
    }

    func testRendererPromptContextDecodesAndBuildsPersonalPrompt() throws {
        let payload = Data("""
        {"id":"start","kind":"start","projectID":"project","promptContext":{"kind":"personal"},"maxRounds":3,"reviewSelection":{"modelID":"review-model"},"fixSelection":{"modelID":"fix-model"}}
        """.utf8)
        let action = try JSONDecoder().decode(ReviewLoopAction.self, from: payload)
        let store = ReviewTestStore()
        let coordinator = ReviewLoopCoordinator(store: store)
        try coordinator.apply(action, projects: [project])
        XCTAssertEqual(coordinator.loops.first?.promptContext, .personal)
        XCTAssertEqual(ReviewPrompts.reviewPrompt(for: try XCTUnwrap(coordinator.loops.first)),
                       "Review project for bugs and issues (this is a project for personal use)." + reviewBoundary)
    }

    func testPerformanceReviewIncludesOptionalProjectContext() {
        var loop = ReviewLoop(id: UUID(), startActionID: "performance", project: project,
                              promptContext: .personal, maxRounds: 3)
        loop.reviewType = .performance
        XCTAssertEqual(ReviewPrompts.reviewPrompt(for: loop),
                       "Review project for performance and responsiveness (this is a project for personal use)." + reviewBoundary)
    }

    func testCombinedReviewIncludesOptionalProjectContext() {
        let loop = ReviewLoop(id: UUID(), startActionID: "combined", project: project,
                              promptContext: .personal, maxRounds: 3, reviewType: .bugsAndPerformance)
        XCTAssertEqual(ReviewPrompts.reviewPrompt(for: loop),
                       "Review project for bugs, issues, performance and responsiveness (this is a project for personal use)." + reviewBoundary)
    }

    func testReviewsWithoutProjectContextIgnoreSavedContext() throws {
        for reviewType in [ReviewType.organisation, .organisationAndNaming, .content] {
            let store = ReviewTestStore()
            let coordinator = ReviewLoopCoordinator(store: store)
            var action = startAction(id: reviewType.rawValue, kind: .start, projectID: project.id,
                                     promptContext: .personal, maxRounds: 3, loopID: nil)
            action.reviewType = reviewType
            try coordinator.apply(action, projects: [project])
            XCTAssertEqual(store.loops.first?.promptContext, .general)
            XCTAssertFalse(ReviewPrompts.reviewPrompt(for: store.loops[0]).contains("personal use"))

            let savedLoop = ReviewLoop(id: store.loops[0].id, startActionID: action.id,
                                       project: project, promptContext: .personal,
                                       maxRounds: 3, reviewType: reviewType)
            XCTAssertFalse(ReviewPrompts.reviewPrompt(for: savedLoop).contains("personal use"))
        }
    }
}
