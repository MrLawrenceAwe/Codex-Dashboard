import WebKit
import XCTest
@testable import CodexDashboard

@MainActor
final class ReviewLoopWebTests: SerializedDashboardWebTestCase {
    func testConcurrentCardsTargetControlsAndExcludeBusyProjects() async throws {
        let webView = try await DashboardWebTestHarness.mountedWebView(html: DashboardWebTestHarness.basicTodoHTML, baseURL: URL(string: "https://review-loop.test"))
        let result = try await webView.evaluateAsyncJavaScript("""
        (() => {
          const api = window.__codexDashboard;
          const projects = [{id:'a',name:'A',path:'/tmp/a'},{id:'b',name:'B',path:'/tmp/b'},{id:'c',name:'C',path:'/tmp/c'}];
          const loops = projects.slice(0,2).map((project,index) => ({id:project.id,project,phase:index ? 'paused' : 'running',priorityLimit:'P2',maxRounds:5,rounds:[],message:project.name}));
          api.applyReviewLoop({projects,loops,error:null});
          const cards = document.querySelectorAll('[data-review-activity]');
          const setup = document.querySelector('[data-review-project]');
          const before = [cards.length,setup.value,...[...setup.options].map(option => option.disabled),document.querySelector('[data-review-start]').disabled,document.querySelector('[data-review-form]').hidden];
          document.querySelector('[data-review-action="stop"]').click();
          const action = JSON.parse(api.pendingReviewAction());
          return [...before,action.kind,action.loopID];
        })()
        """) as? [AnyHashable]
        XCTAssertEqual(result, [2, "c", true, true, false, false, false, "stop", "a"])
    }

    func testConcurrentCardsPreserveDetailsAndScopePendingStatus() async throws {
        let webView = try await DashboardWebTestHarness.mountedWebView(html: """
        <html><head><style>body { margin:0; } aside { width:160px; }
        #codex-dashboard-review-page { transition:none !important; }
        </style></head><body><aside role="navigation"><button class="sidebar-item">New chat</button></aside><main>Conversation</main></body></html>
        """, baseURL: URL(string: "https://review-loop.test"))
        webView.frame = CGRect(x: 0, y: 0, width: 1440, height: 1100)
        let result = try await webView.evaluateAsyncJavaScript("""
        (() => {
          const api = window.__codexDashboard;
          const projects = ['Dashboard', 'Website', 'Archive'].map((name, i) => ({id:String(i),name,path:'/tmp/' + i}));
          const loops = projects.map((project, i) => ({id:project.id,project,phase:i === 2 ? 'completed' : 'running',priorityLimit:'P2',maxRounds:5,
            message:i === 2 ? 'Review complete' : 'Reviewing changes',rounds:[{number:1,result:{outcome:'fixed',summary:'Fixed issue',commit:'1234567890'}}]}));
          const snapshot = {projects,loops,error:null};
          api.applyReviewLoop(snapshot); api.openReviews();
          const cards = () => [...document.querySelectorAll('[data-review-activity]')];
          const first = cards()[0];
          first.querySelector('details').open = true;
          api.applyReviewLoop(snapshot);
          const preserved = cards()[0] === first && first.querySelector('details').open && !cards()[1].querySelector('details').open;
          cards()[1].querySelector('[data-review-action="pause"]').click();
          const action = JSON.parse(api.pendingReviewAction());
          const scoped = first.querySelector('[data-review-status]').textContent === 'Reviewing changes' && cards()[1].querySelector('[data-review-status]').textContent === 'Requesting pause…';
          api.applyReviewLoop({...snapshot,acknowledgedActionID:action.id});
          const a = cards()[0].getBoundingClientRect(), b = cards()[1].getBoundingClientRect();
          return [preserved,action.loopID,scoped,a.top === b.top,b.left > a.left,document.querySelector('[data-review-overview]').textContent];
        })()
        """) as? [AnyHashable]
        XCTAssertEqual(result, [true, "1", true, true, true, "2 active · 3 total"])
        try await Task.sleep(for: .milliseconds(150))
        let image = try await webView.takeSnapshot(configuration: nil)
        if let data = image.tiffRepresentation.flatMap({ NSBitmapImageRep(data: $0) })?.representation(using: .png, properties: [:]) {
            try data.write(to: URL(fileURLWithPath: "/tmp/codex-review-board.png"))
        }
        webView.frame = CGRect(x: 0, y: 0, width: 640, height: 900)
        try await Task.sleep(for: .milliseconds(150))
        let narrow = try await webView.evaluateAsyncJavaScript("""
        (() => {
          const panel = document.querySelector('[data-review-loop]');
          const cards = [...document.querySelectorAll('[data-review-activity]')];
          const a = cards[0].getBoundingClientRect(), b = cards[1].getBoundingClientRect();
          return panel.scrollWidth <= panel.clientWidth && a.left === b.left && b.top > a.top;
        })()
        """) as? Bool
        XCTAssertEqual(narrow, true)
        _ = try await webView.evaluateAsyncJavaScript("""
        window.__codexDashboard.applyReviewLoop({projects:[],loops:[],error:null})
        """)
        let remaining = try await webView.evaluateAsyncJavaScript("document.querySelectorAll('[data-review-activity]').length") as? Int
        XCTAssertEqual(remaining, 0)
    }

    func testHistoryShowsOneSelectionAndHandlesSnapshotChanges() async throws {
        let webView = try await DashboardWebTestHarness.mountedWebView(html: DashboardWebTestHarness.basicTodoHTML, baseURL: URL(string: "https://review-loop.test"))
        let result = try await webView.evaluateAsyncJavaScript("""
        (() => {
          const api = window.__codexDashboard;
          const projects = ['A', 'B', 'C', 'D', 'E', 'F'].map(id => ({id,name:id,path:'/tmp/' + id}));
          const loops = projects.map((project, i) => ({id:project.id,project,
            phase:['running','paused','completed','limitReached','stopped','blocked'][i],
            priorityLimit:'P2',maxRounds:5,message:'Status',rounds:[{number:1,result:{outcome:'fixed',summary:'Saved summary'}}]}));
          const snapshot = {projects,loops,error:null};
          const apply = () => api.applyReviewLoop(snapshot);
          const active = () => [...document.querySelectorAll('[data-review-board] [data-review-activity]')].map(card => card.dataset.loopId).join(',');
          const history = () => [...document.querySelectorAll('[data-review-history-card] [data-review-activity]')].map(card => card.dataset.loopId).join(',');
          apply();
          const select = document.querySelector('[data-review-history-select]');
          const states = [active(),history(),select.options.length];
          select.value = 'D'; select.dispatchEvent(new Event('change'));
          const card = document.querySelector('[data-review-history-card] article');
          card.querySelector('.review-round-details').open = true;
          apply();
          states.push(history(),card === document.querySelector('[data-review-history-card] article'),card.querySelector('.review-round-details').open);
          loops[0].phase = 'completed'; apply();
          states.push(active(),history(),select.options.length);
          snapshot.loops = loops.filter(loop => loop.id !== 'D'); apply();
          states.push(history(),select.value);
          snapshot.loops = [loops[1]]; apply();
          states.push(history(),document.querySelector('[data-review-history]').hidden,active());
          snapshot.loops = []; apply();
          states.push(document.querySelectorAll('[data-review-activity]').length,document.querySelector('[data-review-empty]').hidden);
          return states;
        })()
        """) as? [AnyHashable]
        XCTAssertEqual(result, ["A,B", "C", 4, "D", true, true, "B", "D", 5, "A", "A", "", true, "B", 0, false])
    }

    func testPreviousReviewDetailsStartCollapsedAndStayOpenDuringRefresh() async throws {
        let webView = try await DashboardWebTestHarness.mountedWebView(html: DashboardWebTestHarness.basicTodoHTML, baseURL: URL(string: "https://review-loop.test"))
        let result = try await webView.evaluateAsyncJavaScript("""
        (() => {
          const api = window.__codexDashboard;
          const project = {id:'p',name:'Example',path:'/tmp/example'};
          const snapshot = {projects:[project],loops:[{id:'finished',project,phase:'completed',priorityLimit:'P2',maxRounds:5,
            rounds:[{number:1,result:{outcome:'clean',summary:'No findings'}}]}],error:null};
          api.applyReviewLoop(snapshot);
          const history = document.querySelector('[data-review-history]');
          const details = document.querySelector('[data-review-history-details]');
          const card = document.querySelector('[data-review-history-card]');
          const initial = [history.hidden,details.open,card.getBoundingClientRect().height];
          details.querySelector('summary').click();
          api.applyReviewLoop(snapshot);
          return [...initial,details.open,card.getBoundingClientRect().height > 0];
        })()
        """) as? [AnyHashable]
        XCTAssertEqual(result, [false, false, 0, true, true])
    }

    func testPriorityOptionsDescribeIncludedFindings() async throws {
        let webView = try await DashboardWebTestHarness.mountedWebView(
            html: DashboardWebTestHarness.basicTodoHTML,
            baseURL: URL(string: "https://review-loop.test")
        )
        let labels = try await webView.evaluateAsyncJavaScript("""
        (() => {
          const select = document.querySelector('[data-review-priority]');
          return [select.getAttribute('aria-label'), ...[...select.options].map(option => option.textContent)];
        })()
        """) as? [String]
        XCTAssertEqual(labels, ["Review and fix priority limit", "P0 only · Critical",
                                "P0–P1 · High and critical", "P0–P2 · Medium and higher",
                                "P0–P3 · All priorities"])
    }

    func testSidebarSpinnerTracksActiveLoopAndNavigationRemount() async throws {
        let webView = try await DashboardWebTestHarness.mountedWebView(html: DashboardWebTestHarness.basicTodoHTML, baseURL: URL(string: "https://review-loop.test"))
        let states = try await webView.evaluateAsyncJavaScript("""
        (() => {
          const api = window.__codexDashboard;
          const project = {id:'p',name:'Example',path:'/tmp/example'};
          const loop = {id:'loop-1',project,phase:'waiting',priorityLimit:'P2',maxRounds:5,rounds:[],message:'Waiting'};
          const snapshot = {projects:[project],loops:[loop],error:null};
          const spinner = () => document.querySelector('[data-review-navigation-running]');
          const states = [spinner().hidden];
          api.applyReviewLoop(snapshot);
          states.push(spinner().hidden, spinner().getAttribute('aria-label'));
          loop.phase = 'running'; api.applyReviewLoop(snapshot);
          states.push(spinner().hidden);
          document.getElementById('codex-dashboard-review-navigation').remove();
          api.ensureMounted();
          states.push(spinner().hidden);
          loop.phase = 'paused'; api.applyReviewLoop(snapshot);
          states.push(spinner().hidden);
          loop.phase = 'completed'; api.applyReviewLoop(snapshot);
          states.push(spinner().hidden);
          api.applyReviewLoop({...snapshot,loops:[]});
          states.push(spinner().hidden);
          return states;
        })()
        """) as? [AnyHashable]
        XCTAssertEqual(states, [true, false, "Review loop running", false, false, true, true, true])
    }

    func testReviewTypesQueueSelectedFocusAndKeepProjectTypeOptional() async throws {
        let webView = try await DashboardWebTestHarness.mountedWebView(html: DashboardWebTestHarness.basicTodoHTML, baseURL: URL(string: "https://review-loop.test"))
        let result = try await webView.evaluateAsyncJavaScript("""
        (() => {
          const api = window.__codexDashboard;
          const snapshot = {projects:[{id:'p',name:'Example',path:'/tmp/example'}],loops:[],error:null};
          api.applyReviewLoop(snapshot);
          const select = document.querySelector('[data-review-focus]');
          const results = [];
          for (const option of select.options) {
            select.value = option.value;
            select.dispatchEvent(new Event('change'));
            const hidden = document.querySelector('.review-priority').hidden;
            document.querySelector('[data-review-start]').click();
            const action = JSON.parse(api.pendingReviewAction());
            results.push(action.focus, hidden, action.priorityLimit);
            api.applyReviewLoop({...snapshot, acknowledgedActionID:action.id});
          }
          return results;
        })()
        """) as? [AnyHashable]
        XCTAssertEqual(result, ["bugs", false, "P2", "organisation", true, NSNull(),
                                "naming", true, NSNull(), "performance", false, "P2"])
    }

    func testPanelQueuesOnceAndAcknowledgesWithoutTouchingComposer() async throws {
        let webView = try await DashboardWebTestHarness.mountedWebView(html: DashboardWebTestHarness.basicTodoHTML, baseURL: URL(string: "https://review-loop.test"))
        let result = try await webView.evaluateAsyncJavaScript("""
        (() => {
          window.__codexDashboard.applyReviewLoop({projects:[{id:'p',name:'Example',path:'/tmp/example'}],loops:[],error:null});
          window.__codexDashboard.openReviews();
          document.querySelector('[data-review-priority]').value = 'P1';
          document.querySelector('[data-review-project-type]').value = 'personal';
          document.querySelector('[data-review-start]').click();
          const first = JSON.parse(window.__codexDashboard.pendingReviewAction());
          document.querySelector('[data-review-start]').click();
          const same = first.id === JSON.parse(window.__codexDashboard.pendingReviewAction()).id;
          window.__codexDashboard.applyReviewLoop({projects:[{id:'p',name:'Example',path:'/tmp/example'}],loops:[],error:'Dirty checkout',acknowledgedActionID:first.id});
          return [first.kind,first.projectID,first.maxRounds,first.projectType.kind,first.priorityLimit,same,window.__codexDashboard.pendingReviewAction() === null,document.querySelector('[data-review-error]').textContent];
        })()
        """) as? [AnyHashable]
        XCTAssertEqual(result, ["start", "p", 5, "personal", "P1", true, true, "Dirty checkout"])
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
        window.__codexDashboard.applyReviewLoop({projects:[{id:'p',name:'Example project',path:'/tmp/example-project'}],loops:[],error:null});
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
          api.applyReviewLoop({projects:[{id:'p',name:'Example',path:'/tmp/example'}], models:[{modelID:'model-a',displayName:'Model A',supportedReasoningEfforts:['low','high']},{modelID:'model-b',displayName:'Model B',supportedReasoningEfforts:['medium']}],loops:[],error:null});
          const nav = document.getElementById('codex-dashboard-review-navigation');
          const placed = nav.previousElementSibling.id === 'codex-dashboard-todo-navigation';
          const sameWidth = Math.abs(nav.getBoundingClientRect().width - nav.previousElementSibling.getBoundingClientRect().width) < 1;
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
          const fixModel = document.querySelector('[data-fix-model]');
          fixModel.value = 'model-b'; fixModel.dispatchEvent(new Event('change'));
          const fixEffort = document.querySelector('[data-fix-effort]');
          const fixChoices = [...fixEffort.options].map(o => o.value).join(',');
          fixEffort.value = 'medium';
          const speed = document.querySelector('[data-review-speed]');
          const defaultSpeed = speed.value;
          speed.value = 'fast';
          document.querySelector('[data-review-start]').click();
          const action = JSON.parse(api.pendingReviewAction());
          api.openTodos();
          const closed = !document.getElementById('codex-dashboard-review-page').classList.contains('is-open');
          return [placed,sameWidth,exclusive,restored,choices,fixChoices,defaultSpeed,action.speed,action.reviewSelection.modelID,action.reviewSelection.reasoningEffort,action.fixSelection.modelID,action.fixSelection.reasoningEffort,closed];
        })()
        """) as? [AnyHashable]
        XCTAssertEqual(result, [true, true, true, true, ",low,high", ",medium", "standard", "fast", "model-a", "high", "model-b", "medium", true])
    }

    func testActivityPreservesExpandedSummaryAndShowsLoopState() async throws {
        let webView = try await DashboardWebTestHarness.mountedWebView(html: DashboardWebTestHarness.basicTodoHTML, baseURL: URL(string: "https://review-loop.test"))
        let result = try await webView.evaluateAsyncJavaScript("""
        (() => {
          const api = window.__codexDashboard;
          const project = {id:'p',name:'Example <project>',path:'/tmp/example'};
          const loop = {id:'loop-1',project,phase:'running',priorityLimit:'P2',maxRounds:5,message:'Reviewing changes',rounds:[
            {number:1,threadID:'task-1',result:{outcome:'fixed',commit:'1234567890',summary:'Fixed <issue>'}},
            {number:2,threadID:'task-2',fixRequested:false}
          ]};
          const snapshot = {projects:[project],loops:[loop],error:null};
          api.applyReviewLoop(snapshot);
          api.openReviews();
          document.querySelector('.review-round-details').open = true;
          api.applyReviewLoop(snapshot);
          const active = [document.querySelector('[data-review-form]').hidden,
            !document.querySelector('[data-review-activity]').hidden,
            document.querySelector('[data-review-project-name]').textContent,
            document.querySelector('.review-round-details').open,
            document.querySelector('.review-round-details p').textContent,
            document.querySelector('[data-review-action="pause"]').textContent,
            document.querySelector('[data-review-meter]').value,
            document.querySelector('[data-review-round-count]').textContent,
            !!(document.querySelector('[data-review-activity]').compareDocumentPosition(document.querySelector('[data-review-form]')) & Node.DOCUMENT_POSITION_FOLLOWING)];
          loop.pauseRequested = true;
          api.applyReviewLoop(snapshot);
          active.push(document.querySelector('[data-review-action="pause"]').disabled,
            document.querySelector('[data-review-action="pause"]').textContent);
          loop.phase = 'completed';
          api.applyReviewLoop(snapshot);
          return [...active,document.querySelector('[data-review-form]').hidden,
            document.querySelector('[data-review-controls]').children.length,
            document.querySelector('[data-review-badge]').textContent];
        })()
        """) as? [AnyHashable]
        XCTAssertEqual(result, [false, true, "Example <project>", true, "Fixed <issue>", "Pause after round", 1, "1 of 5", true, true, "Pausing after round…", false, 0, "Completed"])
    }

    func testRoundLimitShowsFinalStatusWithoutResume() async throws {
        let webView = try await DashboardWebTestHarness.mountedWebView(html: DashboardWebTestHarness.basicTodoHTML, baseURL: URL(string: "https://review-loop.test"))
        let result = try await webView.evaluateAsyncJavaScript("""
        (() => {
          const project = {id:'p',name:'Example',path:'/tmp/example'};
          const loop = {id:'limited',project,phase:'limitReached',priorityLimit:'P2',maxRounds:1,
            message:'All configured review rounds completed.',
            rounds:[{number:1,result:{outcome:'fixed',commit:'1234567890',summary:'Fixed issue'}}]};
          window.__codexDashboard.applyReviewLoop({projects:[project],loops:[loop],error:null,
            progress:{[loop.id]:{step:'Limit reached',currentLabel:'Latest prompt',current:null,upcoming:null,
              nextMessage:'No further prompts scheduled.',threadID:null}}});
          window.__codexDashboard.openReviews();
          const badge = document.querySelector('[data-review-badge]');
          const limitColor = getComputedStyle(badge).color;
          badge.dataset.phase = 'completed';
          const successColor = getComputedStyle(badge).color;
          badge.dataset.phase = 'limitReached';
          return [badge.textContent,
            document.querySelector('[data-review-step]').textContent,
            document.querySelector('[data-review-controls]').children.length,
            document.querySelector('[data-review-form]').hidden,
            document.querySelector('[data-review-status]').textContent,
            limitColor === successColor];
        })()
        """) as? [AnyHashable]
        XCTAssertEqual(result, ["Limit reached", "Limit reached", 0, false, "All configured review rounds completed.", true])
    }

    func testLivePromptsStayVisibleAfterRefreshAndRenderAsText() async throws {
        let webView = try await DashboardWebTestHarness.mountedWebView(html: DashboardWebTestHarness.basicTodoHTML, baseURL: URL(string: "https://review-loop.test"))
        let result = try await webView.evaluateAsyncJavaScript("""
        (() => {
          const api = window.__codexDashboard;
          const project = {id:'p',name:'Example',path:'/tmp/example'};
          const snapshot = {projects:[project],error:null,
            loops:[{id:'live',project,phase:'running',priorityLimit:'P2',maxRounds:5,rounds:[],message:'Reviewing'}],
            progress:{live:{step:'Reviewing',currentLabel:'Current prompt',threadID:'task-1',nextMessage:'',
              current:{title:'Review · round 1',text:'Review <code> & files',note:''},
              upcoming:{title:'Fix & commit',text:'Address all and commit',note:'Only if issues are found.'}}}};
          api.applyReviewLoop(snapshot);
          const current = document.querySelector('[data-review-current-prompt]');
          const upcoming = document.querySelector('[data-review-upcoming-prompt]');
          api.applyReviewLoop(snapshot);
          const active = [!document.querySelector('[data-review-live]').hidden,
            current.tagName,upcoming.tagName,!current.hidden,!upcoming.hidden,
            document.querySelector('[data-review-current-text]').textContent,
            document.querySelector('[data-review-upcoming-text]').textContent,
            document.querySelector('[data-review-current-text]').children.length,
            document.querySelector('[data-review-current-task]').dataset.reviewThread];
          snapshot.loops[0].phase = 'completed';
          snapshot.progress.live.upcoming = null;
          snapshot.progress.live.nextMessage = 'No further prompts scheduled.';
          api.applyReviewLoop(snapshot);
          return [...active,document.querySelector('[data-review-upcoming-prompt]').hidden,
            document.querySelector('[data-review-next-message]').textContent];
        })()
        """) as? [AnyHashable]
        XCTAssertEqual(result, [true, "DIV", "DIV", true, true, "Review <code> & files", "Address all and commit", 0, "task-1", true, "No further prompts scheduled."])
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
