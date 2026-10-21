import Foundation
import XCTest

@testable import CodexDashboard

@MainActor
extension AppCoordinatorTests {
    private func questionResult(_ coordinator: AppCoordinator) -> ThreadActivityObservation {
        let initial = ThreadSummary.fixture(id: "question-chat")
        _ = coordinator.observeThreadActivity(in: [initial])
        var question = initial
        question.latestQuestionEvent = ThreadQuestionEvent(id: "question", timestamp: .now.addingTimeInterval(1))
        return coordinator.observeThreadActivity(in: [question])
    }

    func testNewQuestionForegroundsCodexAndOpensItsChat() async {
        let foregrounder = RecordingCodexForegrounder()
        let runtime = StubDashboardRuntime()
        let coordinator = makeAppCoordinator(observeFileChanges: false, codexForegrounder: foregrounder, runtimeFactory: { _ in runtime })
        await coordinator.handleThreadActivity(questionResult(coordinator))
        XCTAssertEqual(foregrounder.callCount, 1)
        XCTAssertEqual(runtime.openedThreadIDs, ["question-chat"])
    }

    func testFrontmostCodexOpensQuestionChatAndDoesNotReplayItLater() async {
        let foregrounder = RecordingCodexForegrounder()
        foregrounder.isCodexFrontmost = true
        let runtime = StubDashboardRuntime()
        let coordinator = makeAppCoordinator(observeFileChanges: false, codexForegrounder: foregrounder, runtimeFactory: { _ in runtime })
        await coordinator.handleThreadActivity(questionResult(coordinator))
        foregrounder.isCodexFrontmost = false
        var thread = ThreadSummary.fixture(id: "question-chat")
        thread.latestQuestionEvent = ThreadQuestionEvent(id: "question", timestamp: .now)
        XCTAssertEqual(runtime.openedThreadIDs, ["question-chat"])
        // The same question must not navigate again after switching away from Codex.
        let result = coordinator.observeThreadActivity(in: [thread])
        XCTAssertNil(result.questionThreadIDToOpen)
        await coordinator.handleThreadActivity(result)
        XCTAssertEqual(foregrounder.callCount, 0)
        XCTAssertEqual(runtime.openedThreadIDs, ["question-chat"])
    }

    func testQuestionToggleDisablesFocusIndependentlyOfCompletionToggle() async {
        let foregrounder = RecordingCodexForegrounder()
        let runtime = StubDashboardRuntime()
        let coordinator = makeAppCoordinator(observeFileChanges: false, codexForegrounder: foregrounder, runtimeFactory: { _ in runtime })
        coordinator.automaticallyOpenQuestionChats = false
        await coordinator.handleThreadActivity(questionResult(coordinator))
        XCTAssertTrue(coordinator.automaticallyOpenCompletedChats)
        XCTAssertEqual(foregrounder.callCount, 0)
        XCTAssertTrue(runtime.openedThreadIDs.isEmpty)
    }

    func testFrontmostCodexOpensCompletedChat() async {
        let foregrounder = RecordingCodexForegrounder()
        foregrounder.isCodexFrontmost = true
        let runtime = StubDashboardRuntime()
        let coordinator = makeAppCoordinator(observeFileChanges: false, codexForegrounder: foregrounder, runtimeFactory: { _ in runtime })
        await coordinator.handleThreadActivity(.init(completion: .init(hasCompletion: true, threadIDToOpen: "completed-chat"), questionThreadIDToOpen: nil))
        XCTAssertEqual(foregrounder.callCount, 0)
        XCTAssertEqual(runtime.openedThreadIDs, ["completed-chat"])
    }

    func testTypingAndVoiceSuppressQuestionFocus() async {
        for (speechIsActive, codexIsFrontmost) in [(false, false), (true, false), (false, true), (true, true)] {
            let foregrounder = RecordingCodexForegrounder()
            foregrounder.isCodexFrontmost = codexIsFrontmost
            let runtime = StubDashboardRuntime()
            runtime.speechInputIsActive = speechIsActive
            let coordinator = makeAppCoordinator(
                observeFileChanges: false, codexForegrounder: foregrounder,
                keyboardActivityDetector: StubKeyboardActivityDetector(hasRecentKeyboardActivity: !speechIsActive),
                runtimeFactory: { _ in runtime }
            )
            await coordinator.handleThreadActivity(questionResult(coordinator))
            XCTAssertEqual(foregrounder.callCount, 0)
            XCTAssertTrue(runtime.openedThreadIDs.isEmpty)
        }
    }

}
