import XCTest
@testable import CodexDashboard

@MainActor
final class ReviewLoopPromptsTests: ReviewLoopTestCase {
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
        loop.focus = .performance
        XCTAssertEqual(ReviewPrompts.reviewPrompt(for: loop),
                       "Review project for performance and responsiveness (this is a project for personal use)." + reviewBoundary)
    }

    func testCombinedReviewIncludesOptionalProjectContext() {
        let loop = ReviewLoop(id: UUID(), startActionID: "combined", project: project,
                              promptContext: .personal, maxRounds: 3, focus: .bugsAndPerformance)
        XCTAssertEqual(ReviewPrompts.reviewPrompt(for: loop),
                       "Review project for bugs, issues, performance and responsiveness (this is a project for personal use)." + reviewBoundary)
    }

    func testReviewsWithoutProjectContextIgnoreSavedContext() throws {
        for focus in [ReviewFocus.organisation, .organisationAndNaming, .content] {
            let store = ReviewTestStore()
            let coordinator = ReviewLoopCoordinator(store: store)
            var action = startAction(id: focus.rawValue, kind: .start, projectID: project.id,
                                     promptContext: .personal, maxRounds: 3, loopID: nil)
            action.focus = focus
            try coordinator.apply(action, projects: [project])
            XCTAssertEqual(store.loops.first?.promptContext, .general)
            XCTAssertFalse(ReviewPrompts.reviewPrompt(for: store.loops[0]).contains("personal use"))

            let savedLoop = ReviewLoop(id: store.loops[0].id, startActionID: action.id,
                                       project: project, promptContext: .personal,
                                       maxRounds: 3, focus: focus)
            XCTAssertFalse(ReviewPrompts.reviewPrompt(for: savedLoop).contains("personal use"))
        }
    }
}
