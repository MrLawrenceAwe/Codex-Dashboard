import WebKit
import XCTest

@testable import CodexDashboard

@MainActor
final class SentMessageDictationWebTests: SerializedDashboardWebTestCase {
    private func fixture() async throws -> WKWebView {
        let webView = DashboardWebTestHarness.makeWebView()
        webView.loadHTMLString("""
        <!doctype html><html><head></head><body>
        <aside role="navigation"><button class="sidebar-item">New chat</button></aside>
        <main><form><div contenteditable="true" role="textbox" aria-label="Edit message">Before old after</div><button type="button" id="native-cancel">Cancel</button><button type="submit">Send</button></form>
        <textarea placeholder="Do anything">Separate draft</textarea></main></body></html>
        """, baseURL: URL(string: "https://dictation.codex-dashboard.test"))
        try await DashboardWebTestHarness.waitUntilLoaded(webView)
        let injection = try InjectionBundle.load().mountExpression
            .replacingOccurrences(of: "function createSentMessageDictation({", with: "window.__createDictation = createSentMessageDictation; function createSentMessageDictation({")
            .replacingOccurrences(of: "if (!event.isTrusted) return;", with: "/* trusted input simulated only in WebKit test */")
        _ = try await webView.evaluateJavaScript(injection)
        _ = try await webView.evaluateAsyncJavaScript("""
        (async () => {
          window.__codexDashboard.destroy();
          const editor = document.querySelector('[aria-label="Edit message"]');
          const state = { text: editor.textContent, stopped: 0, closed: 0 };
          const doc = { content: {size: state.text.length}, textBetween: (a,b) => state.text.slice(a,b) };
          const view = {dom:editor, state:{doc, selection:{from:7,to:10}, get tr() {
            return { insertText(text,from,to) {this.text=text;this.from=from;this.to=to;return this;},scrollIntoView(){return this;} };
          }}, dispatch(tr) {state.text = state.text.slice(0,tr.from)+tr.text+state.text.slice(tr.to);editor.textContent=state.text;},focus(){editor.focus();}};
          class Streaming {start(){return Promise.resolve();}finish(){return new Promise(resolve=>{state.resolve=resolve;});}close(){state.closed++;}}
          Object.defineProperty(navigator,'mediaDevices',{value:{getUserMedia:async()=>({getTracks:()=>[{stop(){state.stopped++;}}]})}});
          const feature = window.__createDictation({loadHost:async()=>({Streaming,host:'test'}),editorController:()=>({view}),hasOtherSpeech:()=>false});
          feature.mount();
          window.__dictationFixture={editor,state,view,feature};
        })()
        """)
        return webView
    }

    func testSelectionReplacementPreservesOtherDraft() async throws {
        let web = try await fixture()
        let result = try await web.evaluateAsyncJavaScript("""
        (async () => {
          const {state,feature}=window.__dictationFixture;
          document.querySelector('[data-edit-dictation-controls] button[aria-pressed]').click();
          for(let i=0;i<20&&feature.status().state!=='recording';i++) await new Promise(r=>setTimeout(r,10));
          document.querySelector('[data-edit-dictation-controls] button[aria-pressed]').click();
          state.resolve('new words');
          await new Promise(r=>setTimeout(r,20));
          const result=[state.text,document.querySelector('textarea').value,feature.status().state,state.stopped>0];
          feature.destroy();return result;
        })()
        """) as? [AnyHashable]
        XCTAssertEqual(result, ["Before new words after", "Separate draft", "inserted", true])
    }

    func testCancelBeforeDelayedTranscriptLeavesOriginal() async throws {
        let web = try await fixture()
        let result = try await web.evaluateAsyncJavaScript("""
        (async () => {
          const {state,feature}=window.__dictationFixture;
          document.querySelector('[data-edit-dictation-controls] button[aria-pressed]').click();
          for(let i=0;i<20&&feature.status().state!=='recording';i++) await new Promise(r=>setTimeout(r,10));
          document.querySelector('[data-edit-dictation-controls] button[aria-pressed]').click();
          document.getElementById('native-cancel').click();
          state.resolve('must never appear');
          await new Promise(r=>setTimeout(r,20));
          const result=[state.text,document.querySelector('textarea').value,feature.status().state,state.stopped>0];
          feature.destroy();return result;
        })()
        """) as? [AnyHashable]
        XCTAssertEqual(result, ["Before old after", "Separate draft", "cancelled", true])
    }

    func testDocumentChangeRejectsStaleInsertion() async throws {
        let web = try await fixture()
        let result = try await web.evaluateAsyncJavaScript("""
        (async () => {
          const {state,view,feature}=window.__dictationFixture;
          document.querySelector('[data-edit-dictation-controls] button[aria-pressed]').click();
          for(let i=0;i<20&&feature.status().state!=='recording';i++) await new Promise(r=>setTimeout(r,10));
          document.querySelector('[data-edit-dictation-controls] button[aria-pressed]').click();
          view.state.doc = {...view.state.doc};
          state.resolve('must never appear');
          await new Promise(r=>setTimeout(r,20));
          const result=[state.text,feature.status().state,state.stopped>0];
          feature.destroy();return result;
        })()
        """) as? [AnyHashable]
        XCTAssertEqual(result, ["Before old after", "error", true])
    }
}
