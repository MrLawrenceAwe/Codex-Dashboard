import XCTest

@testable import CodexDashboard

@MainActor
final class SpeechInputWebTests: SerializedDashboardWebTestCase {

    func testSpeechDetectionCoversDictationVoiceAndInactiveControls() async throws {
        let webView = DashboardWebTestHarness.makeWebView()
        webView.loadHTMLString("<html><body><button id='speech'>Dictate</button></body></html>", baseURL: nil)
        try await DashboardWebTestHarness.waitUntilLoaded(webView)
        let cases = [
            ("document.body.insertAdjacentHTML('beforeend', '<div data-dictation-enabled></div>')", false),
            ("document.body.insertAdjacentHTML('beforeend', '<div data-dictation-view=waveform></div>')", true),
            ("document.querySelector('[data-dictation-view]').setAttribute('data-dictation-view', 'text')", true),
            ("document.querySelector('[data-dictation-view]').remove()", false),
            ("document.body.insertAdjacentHTML('beforeend', '<div data-realtime-voice-orb></div>')", true),
            ("document.querySelector('[data-realtime-voice-orb]').remove()", false),
            ("document.querySelector('button').__reactFiber$test = {memoizedProps: {}, return: {memoizedProps: {startDictation() {}, isStarting: true}}}", true),
            ("document.querySelector('button').__reactFiber$test.return.memoizedProps = {isTranscribing: true}", true),
            ("document.querySelector('button').__reactFiber$test.return.memoizedProps = {realtimeSession: {thread: {phase: 'connecting'}}}", true),
            ("document.querySelector('button').__reactFiber$test.return.memoizedProps = {realtimeSession: {thread: {phase: 'inactive'}}}", false),
        ]
        for (setup, expected) in cases {
            _ = try await webView.evaluateJavaScript(setup + "; true")
            let active = try await webView.evaluateJavaScript(RendererScript.hasActiveSpeechInput) as? Bool
            XCTAssertEqual(active, expected, setup)
        }
    }
}
