import WebKit
import XCTest
@testable import CodexDashboard

@MainActor
final class ReviewLoopWebTests: SerializedDashboardWebTestCase {
    func testPanelQueuesOnceAndAcknowledgesWithoutTouchingComposer() async throws {
        let webView = try await DashboardWebTestHarness.mountedWebView(html: DashboardWebTestHarness.basicTodoHTML, baseURL: URL(string: "https://review-loop.test"))
        let result = try await webView.evaluateAsyncJavaScript("""
        (() => {
          window.__codexDashboard.applyReviewLoop({projects:[{id:'p',name:'Example',path:'/tmp/example'}],loop:null,error:null});
          window.__codexDashboard.openReviews();
          document.querySelector('[data-review-priority]').value = 'P1';
          document.querySelector('[data-review-start]').click();
          const first = JSON.parse(window.__codexDashboard.pendingReviewAction());
          document.querySelector('[data-review-start]').click();
          const same = first.id === JSON.parse(window.__codexDashboard.pendingReviewAction()).id;
          window.__codexDashboard.applyReviewLoop({projects:[{id:'p',name:'Example',path:'/tmp/example'}],loop:null,error:'Dirty checkout',acknowledgedActionID:first.id});
          return [first.kind,first.projectID,first.maxRounds,first.instructions === undefined,first.priorityLimit,same,window.__codexDashboard.pendingReviewAction() === null,document.querySelector('[data-review-error]').textContent];
        })()
        """) as? [AnyHashable]
        XCTAssertEqual(result, ["start", "p", 5, true, "P1", true, true, "Dirty checkout"])
    }

    func testExpandedPanelFitsNarrowWindow() async throws {
        let webView = try await DashboardWebTestHarness.mountedWebView(html: """
        <html><head><style>
        * { box-sizing:border-box; } body { margin:0; font-family:-apple-system,sans-serif; }
        .host { display:grid; grid-template-columns:160px 1fr; } aside { width:160px; }
        #codex-dashboard-review-page { transition:none !important; opacity:1 !important; visibility:visible !important; transform:none !important; }
        </style></head><body><div class="host"><aside role="navigation"><button class="sidebar-item">New chat</button></aside><main>Conversation</main></div></body></html>
        """, baseURL: URL(string: "https://review-loop.test"))
        webView.frame = CGRect(x: 0, y: 0, width: 640, height: 800)
        _ = try await webView.evaluateAsyncJavaScript("""
        (() => {
        window.__codexDashboard.openReviews();
        window.__codexDashboard.applyReviewLoop({projects:[{id:'p',name:'Example project',path:'/tmp/example-project'}],loop:null,error:null});
        window.__codexDashboard.openReviews();
        return true;
        })()
        """)
        try await Task.sleep(for: .milliseconds(150))
        let overflow = try await webView.evaluateAsyncJavaScript("""
        (() => { const panel = document.querySelector('[data-review-loop]'); return panel.scrollWidth > panel.clientWidth; })()
        """) as? Bool
        XCTAssertEqual(overflow, false)
        let image = try await webView.takeSnapshot(configuration: nil)
        if let data = image.tiffRepresentation.flatMap({ NSBitmapImageRep(data: $0) })?.representation(using: .png, properties: [:]) {
            try data.write(to: URL(fileURLWithPath: "/tmp/codex-review-panel.png"))
        }
    }

    func testReviewPageNavigationRepairAndModelSelection() async throws {
        let webView = try await DashboardWebTestHarness.mountedWebView(html: DashboardWebTestHarness.basicTodoHTML, baseURL: URL(string: "https://review-loop.test"))
        let result = try await webView.evaluateAsyncJavaScript("""
        (() => {
          const api = window.__codexDashboard;
          api.applyReviewLoop({projects:[{id:'p',name:'Example',path:'/tmp/example'}], models:[{model:'model-a',displayName:'Model A',efforts:['low','high']},{model:'model-b',displayName:'Model B',efforts:['medium']}],loop:null,error:null});
          const nav = document.getElementById('codex-dashboard-review-navigation');
          const placed = nav.previousElementSibling.id === 'codex-dashboard-todo-navigation';
          nav.click();
          const exclusive = document.querySelectorAll('section.is-open').length === 1 && document.getElementById('codex-dashboard-review-page').classList.contains('is-open');
          document.getElementById('codex-dashboard-review-page').remove();
          api.ensureMounted();
          const restored = document.getElementById('codex-dashboard-review-page').classList.contains('is-open');
          const model = document.querySelector('[data-review-model]');
          model.value = 'model-a'; model.dispatchEvent(new Event('change'));
          const effort = document.querySelector('[data-review-effort]');
          const choices = [...effort.options].map(o => o.value).join(',');
          effort.value = 'high';
          document.querySelector('[data-review-start]').click();
          const action = JSON.parse(api.pendingReviewAction());
          api.openTodos();
          const closed = !document.getElementById('codex-dashboard-review-page').classList.contains('is-open');
          return [placed,exclusive,restored,choices,action.selection.model,action.selection.effort,closed];
        })()
        """) as? [AnyHashable]
        XCTAssertEqual(result, [true, true, true, ",low,high", "model-a", "high", true])
    }

    func testRequestUsesLocalDesktopConnectionAndCorrelatesResponses() async throws {
        let webView = try await DashboardWebTestHarness.mountedWebView(html: DashboardWebTestHarness.basicTodoHTML, baseURL: URL(string: "https://review-loop.test"))
        let result = try await webView.evaluateAsyncJavaScript("""
        (async () => {
          window.electronBridge = {sendMessageFromView: async request => {
            window.dispatchEvent(new MessageEvent('message',{data:{type:'mcp-response',hostId:'remote',message:{id:request.request.id,result:{wrong:true}}}}));
            window.dispatchEvent(new MessageEvent('message',{data:{type:'mcp-response',hostId:'local',message:{id:request.request.id,result:{method:request.request.method,host:request.hostId}}}}));
          }};
          const response = JSON.parse(await window.__codexDashboard.reviewRequest({method:'project/list',params:{limit:100}}));
          const rejected = JSON.parse(await window.__codexDashboard.reviewRequest({method:'turn/interrupt',params:{}}));
          return [response.result.method,response.result.host,!!rejected.error];
        })()
        """) as? [AnyHashable]
        XCTAssertEqual(result, ["project/list", "local", true])
    }

    func testTeardownSettlesPendingRequestWithoutRetry() async throws {
        let webView = try await DashboardWebTestHarness.mountedWebView(html: DashboardWebTestHarness.basicTodoHTML, baseURL: URL(string: "https://review-loop.test"))
        let result = try await webView.evaluateAsyncJavaScript("""
        (async () => {
          let sent = 0;
          window.electronBridge = {sendMessageFromView: async () => {sent += 1;}};
          const response = window.__codexDashboard.reviewRequest({method:'thread/start',params:{}});
          await Promise.resolve();
          window.__codexDashboard.destroy();
          return [sent,!!JSON.parse(await response).error,document.querySelector('[data-review-loop]') === null];
        })()
        """) as? [AnyHashable]
        XCTAssertEqual(result, [1, true, true])
    }
}
