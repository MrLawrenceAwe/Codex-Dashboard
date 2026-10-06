import WebKit
import XCTest
@testable import CodexDashboard

@MainActor
final class ReviewLoopWebTests: SerializedDashboardWebTestCase {
    private static let modelsJSON = "[{modelID:'model-a',displayName:'Model A',supportedReasoningEfforts:['low']}]"
    private static let reviewTypesJSON = String(
        decoding: try! JSONEncoder().encode(ReviewFocus.allCases.map(ReviewTypeOption.init)),
        as: UTF8.self
    )

    func testCardsResolveLabelsWithoutRenderingSetupAndPreserveUnavailableIdentifiers() async throws {
        let webView = DashboardWebTestHarness.makeWebView()
        webView.loadHTMLString(DashboardWebTestHarness.basicHostHTML, baseURL: URL(string: "https://review-loop.test"))
        try await DashboardWebTestHarness.waitUntilLoaded(webView)
        // History cards must resolve labels even when the setup view never renders.
        let injection = try InjectionBundle.load()
        let expression = try DashboardWebTestHarness.instrumentSource(
            injection.mountExpression,
            anchor: "reviewLoopSetupView.render(snapshot, pendingAction, isFinished);",
            replacement: ""
        )
        _ = try await webView.evaluateJavaScript(expression)
        let result = try await webView.evaluateJavaScript("""
        (() => {
          const project = {id:'p',name:'Example',path:'/tmp/example'};
          const loop = {id:'saved',project,phase:'paused',focus:'organisationAndNaming',completedRoundCount:0,maxRounds:5,rounds:[],
            reviewSelection:{modelID:'model-a',reasoningEffort:'low'},
            fixSelection:{modelID:'retired-model',reasoningEffort:'xhigh'}};
          window.__codexDashboard.applyReviewPageSnapshot({reviewTypes: \(Self.reviewTypesJSON),
            projects:[project],models:\(Self.modelsJSON),loops:[loop],error:null});
          const text = document.querySelector('[data-review-context]').textContent;
          return [text.includes('Review: Model A · Low'),
            text.includes('Fix: retired-model · Extra high'),text.includes('Review: model-a'),
            text.includes('Structure and naming')];
        })()
        """) as? [Bool]
        XCTAssertEqual(result, [true, true, false, true])
    }

    func testExtensionReloadCardShowsInstructionsAndConfirmationAction() async throws {
        let webView = try await DashboardWebTestHarness.mountedWebView(html: DashboardWebTestHarness.basicHostHTML, baseURL: URL(string: "https://review-loop.test"))
        let result = try await webView.evaluateJavaScript("""
        (() => {
          const api = window.__codexDashboard;
          const project = {id:'p',name:'Example',path:'/tmp/example'};
          const loop = {id:'reload',project,phase:'awaitingExtensionReload',message:'Reload Example in Chrome.',completedRoundCount:0,maxRounds:3,rounds:[]};
          api.applyReviewPageSnapshot({reviewTypes: \(Self.reviewTypesJSON),models:\(Self.modelsJSON),projects:[project],loops:[loop],error:null});
          const badge = document.querySelector('[data-review-badge]').textContent;
          const status = document.querySelector('[data-review-status]').textContent;
          const button = document.querySelector('[data-review-action="resume"]');
          const label = button.textContent;
          button.click();
          const action = JSON.parse(api.pendingReviewAction());
          return [badge,status,label,action.kind,action.loopID];
        })()
        """) as? [String]
        XCTAssertEqual(result, ["Waiting for extension reload", "Reload Example in Chrome.", "Extension reloaded — continue", "resume", "reload"])
    }

    func testMuteMediaSetupAndActiveCardActions() async throws {
        let webView = try await DashboardWebTestHarness.mountedWebView(html: DashboardWebTestHarness.basicHostHTML, baseURL: URL(string: "https://review-loop.test"))
        let result = try await webView.evaluateJavaScript("""
        (() => {
          const api = window.__codexDashboard;
          const project = {id:'p',name:'Example',path:'/tmp/example'};
          const snapshot = {reviewTypes: \(Self.reviewTypesJSON), models: \(Self.modelsJSON), projects:[project],loops:[],error:null};
          api.applyReviewPageSnapshot(snapshot); api.openReviews();
          const mute = document.querySelector('[data-review-mute-media]');
          const hiddenBefore = mute.closest('label').hidden;
          const live = document.querySelector('[data-review-live-testing]');
          live.value = 'true'; live.dispatchEvent(new Event('change'));
          const visible = !mute.closest('label').hidden;
          mute.checked = true;
          document.querySelector('[data-review-model]').value = 'model-a';
          document.querySelector('[data-fix-model]').value = 'model-a';
          document.querySelector('[data-review-form]').requestSubmit();
          const start = JSON.parse(api.pendingReviewAction());
          const loop = {id:'blocked',project,phase:'blocked',liveTesting:true,muteMedia:false,completedRoundCount:0,maxRounds:3,rounds:[]};
          api.applyReviewPageSnapshot({...snapshot,loops:[loop],acknowledgedActionID:start.id});
          const toggle = document.querySelector('[data-review-loop-mute-media]');
          toggle.click();
          const update = JSON.parse(api.pendingReviewAction());
          api.applyReviewPageSnapshot({...snapshot,loops:[{...loop,muteMedia:true}],acknowledgedActionID:update.id});
          return [hiddenBefore,visible,start.muteMedia,update.kind,update.loopID,update.muteMedia,
            document.querySelector('[data-review-loop-mute-media]').checked,
            document.querySelector('[data-review-media-setting]').querySelector('p') === null,
            mute.type === 'checkbox'];
        })()
        """) as? [AnyHashable]
        XCTAssertEqual(result, [true,true,true,"setMuteMedia","blocked",true,true,true,true])
    }

    func testStartIncludesOptInRemotePushPreference() async throws {
        let webView = try await DashboardWebTestHarness.mountedWebView(html: DashboardWebTestHarness.basicHostHTML, baseURL: URL(string: "https://review-loop.test"))
        let values = try await webView.evaluateAsyncJavaScript("""
        (() => {
          const api = window.__codexDashboard;
          api.applyReviewPageSnapshot({reviewTypes: \(Self.reviewTypesJSON), models: \(Self.modelsJSON),
            projects:[{id:'p',name:'Example',path:'/tmp/example'}],loops:[],error:null});
          api.openReviews();
          const select = document.querySelector('[data-review-push]');
          const defaultValue = select.value;
          select.value = 'true';
          document.querySelector('[data-review-model]').value = 'model-a';
          document.querySelector('[data-fix-model]').value = 'model-a';
          document.querySelector('[data-review-form]').requestSubmit();
          return [defaultValue, JSON.parse(api.pendingReviewAction()).pushToRemote];
        })()
        """) as? [AnyHashable]
        XCTAssertEqual(values, ["false", true])
    }

    func testBlockedLoopOffersResumeAndDoesNotCountBlockedAttempts() async throws {
        let webView = try await DashboardWebTestHarness.mountedWebView(html: DashboardWebTestHarness.basicHostHTML, baseURL: URL(string: "https://review-loop.test"))
        let result = try await webView.evaluateAsyncJavaScript("""
        (() => {
          const api = window.__codexDashboard;
          const project = {id:'p',name:'Example',path:'/tmp/example'};
          const loop = {id:'blocked',project,phase:'blocked',completedRoundCount:0,maxRounds:1,
            rounds:[{number:1,result:{outcome:'blocked',summary:'Missing evidence'}}]};
          api.applyReviewPageSnapshot({reviewTypes: \(Self.reviewTypesJSON),projects:[project],loops:[loop],finishedLoopIDs:[],error:null});
          const count = document.querySelector('[data-review-round-count]').textContent;
          const stop = !!document.querySelector('[data-review-action="stop"]');
          document.querySelector('[data-review-action="resume"]').click();
          const action = JSON.parse(api.pendingReviewAction());
          return [count,stop,action.kind,action.loopID];
        })()
        """) as? [AnyHashable]
        XCTAssertEqual(result, ["0 of 1", true, "resume", "blocked"])
    }

    func testStoppingLoopKeepsProjectBusyAndOffersOnlyRetryStop() async throws {
        let webView = try await DashboardWebTestHarness.mountedWebView(html: DashboardWebTestHarness.basicHostHTML, baseURL: URL(string: "https://review-loop.test"))
        let result = try await webView.evaluateJavaScript("""
        (() => {
          const api = window.__codexDashboard;
          const project = {id:'p',name:'Example',path:'/tmp/example'};
          const loop = {id:'stopping',project,phase:'stopping',completedRoundCount:0,maxRounds:2,rounds:[]};
          api.applyReviewPageSnapshot({reviewTypes: \(Self.reviewTypesJSON),projects:[project],models:\(Self.modelsJSON),loops:[loop],finishedLoopIDs:[],error:null});
          const stop = document.querySelector('[data-review-action="stop"]');
          const values = [stop.textContent,
            !!document.querySelector('[data-review-action="resume"]'),
            !!document.querySelector('[data-review-action="pause"]'),
            document.querySelector('[data-review-start]').disabled];
          stop.click();
          return [...values,JSON.parse(api.pendingReviewAction()).kind];
        })()
        """) as? [AnyHashable]
        XCTAssertEqual(result, ["Retry Stop", false, false, true, "stop"])
    }

    func testConcurrentCardsTargetControlsAndExcludeBusyProjects() async throws {
        let webView = try await DashboardWebTestHarness.mountedWebView(html: DashboardWebTestHarness.basicHostHTML, baseURL: URL(string: "https://review-loop.test"))
        let result = try await webView.evaluateAsyncJavaScript("""
        (() => {
          const api = window.__codexDashboard;
          const projects = [{id:'a',name:'A',path:'/tmp/a'},{id:'b',name:'B',path:'/tmp/b'},{id:'c',name:'C',path:'/tmp/c'}];
          const loops = projects.slice(0,2).map((project,index) => ({id:project.id,project,phase:index ? 'paused' : 'running',priorityLimit:'P2',completedRoundCount:0,maxRounds:5,rounds:[],message:project.name}));
          api.applyReviewPageSnapshot({reviewTypes: \(Self.reviewTypesJSON),projects,loops,error:null});
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
          const loops = projects.map((project, i) => ({id:project.id,project,phase:i === 2 ? 'completed' : 'running',priorityLimit:'P2',completedRoundCount:1,maxRounds:5,
            message:i === 2 ? 'Review complete' : 'Reviewing changes',rounds:[{number:1,result:{outcome:'fixed',summary:'Fixed issue',commit:'1234567890'}}]}));
          const snapshot = {reviewTypes: \(Self.reviewTypesJSON),projects,loops,finishedLoopIDs:['2'],error:null};
          api.applyReviewPageSnapshot(snapshot); api.openReviews();
          const cards = () => [...document.querySelectorAll('[data-review-activity]')];
          const first = cards()[0];
          first.querySelector('details').open = true;
          api.applyReviewPageSnapshot(snapshot);
          const preserved = cards()[0] === first && first.querySelector('details').open && !cards()[1].querySelector('details').open;
          cards()[1].querySelector('[data-review-action="pause"]').click();
          const action = JSON.parse(api.pendingReviewAction());
          const scoped = first.querySelector('[data-review-status]').textContent === 'Reviewing changes' && cards()[1].querySelector('[data-review-status]').textContent === 'Requesting pause…';
          api.applyReviewPageSnapshot({...snapshot,acknowledgedActionID:action.id});
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
        window.__codexDashboard.applyReviewPageSnapshot({reviewTypes: \(Self.reviewTypesJSON),projects:[],loops:[],error:null})
        """)
        let remaining = try await webView.evaluateAsyncJavaScript("document.querySelectorAll('[data-review-activity]').length") as? Int
        XCTAssertEqual(remaining, 0)
    }

    func testHistoryShowsOneSelectionAndHandlesSnapshotChanges() async throws {
        let webView = try await DashboardWebTestHarness.mountedWebView(html: DashboardWebTestHarness.basicHostHTML, baseURL: URL(string: "https://review-loop.test"))
        let result = try await webView.evaluateAsyncJavaScript("""
        (() => {
          const api = window.__codexDashboard;
          const projects = ['A', 'B', 'C', 'D', 'E', 'F'].map(id => ({id,name:id,path:'/tmp/' + id}));
          const loops = projects.map((project, i) => ({id:project.id,project,
            phase:['running','paused','completed','limitReached','stopped','blocked'][i],
            priorityLimit:'P2',completedRoundCount:1,maxRounds:5,message:'Status',rounds:[{number:1,result:{outcome:'fixed',summary:'Saved summary'}}]}));
          const snapshot = {reviewTypes: \(Self.reviewTypesJSON),projects,loops,finishedLoopIDs:['C','D','E','F'],error:null};
          const apply = () => api.applyReviewPageSnapshot(snapshot);
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
          loops[0].phase = 'completed'; snapshot.finishedLoopIDs.push('A'); apply();
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
        XCTAssertEqual(result, ["A,B", "F", 4, "D", true, true, "B", "D", 5, "F", "F", "", true, "B", 0, false])
    }

    func testPreviousReviewDetailsStartCollapsedAndStayOpenDuringRefresh() async throws {
        let webView = try await DashboardWebTestHarness.mountedWebView(html: DashboardWebTestHarness.basicHostHTML, baseURL: URL(string: "https://review-loop.test"))
        let result = try await webView.evaluateAsyncJavaScript("""
        (() => {
          const api = window.__codexDashboard;
          const project = {id:'p',name:'Example',path:'/tmp/example'};
          const snapshot = {reviewTypes: \(Self.reviewTypesJSON),projects:[project],finishedLoopIDs:['finished'],loops:[{id:'finished',project,phase:'completed',priorityLimit:'P2',completedRoundCount:1,maxRounds:5,
            rounds:[{number:1,result:{outcome:'clean',summary:'No findings'}}]}],error:null};
          api.applyReviewPageSnapshot(snapshot);
          const history = document.querySelector('[data-review-history]');
          const details = document.querySelector('[data-review-history-details]');
          const card = document.querySelector('[data-review-history-card]');
          const initial = [history.hidden,details.open,card.getBoundingClientRect().height];
          details.querySelector('summary').click();
          api.applyReviewPageSnapshot(snapshot);
          return [...initial,details.open,card.getBoundingClientRect().height > 0];
        })()
        """) as? [AnyHashable]
        XCTAssertEqual(result, [false, false, 0, true, true])
    }

    func testHistoryUpdateDatesFollowSelectionAndRefresh() async throws {
        let webView = try await DashboardWebTestHarness.mountedWebView(html: DashboardWebTestHarness.basicHostHTML, baseURL: URL(string: "https://review-loop.test"))
        let result = try await webView.evaluateAsyncJavaScript("""
        (() => {
          const api = window.__codexDashboard;
          const project = {id:'p',name:'Example',path:'/tmp/example'};
          const loops = ['old','new'].map((id,index) => ({id,project,focus:index ? 'performance' : 'organisationAndNaming',phase:'completed',completedRoundCount:1,maxRounds:5,rounds:[]}));
          loops[1].updatedAt = Date.UTC(2026,9,3,14,35) / 1000;
          const snapshot = {reviewTypes: \(Self.reviewTypesJSON),projects:[project],loops,finishedLoopIDs:['old','new'],error:null};
          const dateText = timestamp => new Intl.DateTimeFormat(undefined, {dateStyle:'medium',timeStyle:'short'}).format(new Date(timestamp * 1000));
          const expected = timestamp => 'Last updated: ' + dateText(timestamp);
          const label = () => document.querySelector('[data-review-history-updated]').textContent;
          const type = () => document.querySelector('[data-review-history-type]').textContent;
          api.applyReviewPageSnapshot(snapshot);
          const select = document.querySelector('[data-review-history-select]');
          const states = [label() === expected(loops[1].updatedAt),select.selectedOptions[0].textContent.includes(dateText(loops[1].updatedAt)),document.querySelector('[data-review-history-details]').open];
          states.push(type(),select.selectedOptions[0].textContent === `Example · Performance · ${dateText(loops[1].updatedAt)}`);
          select.value = 'old'; select.dispatchEvent(new Event('change'));
          states.push(label());
          states.push(type(),select.selectedOptions[0].textContent.includes('Structure and naming'));
          loops[0].updatedAt = Date.UTC(2026,9,4,9,10) / 1000;
          api.applyReviewPageSnapshot(snapshot);
          states.push(select.value,label() === expected(loops[0].updatedAt),select.selectedOptions[0].textContent.includes(dateText(loops[0].updatedAt)));
          return states;
        })()
        """) as? [AnyHashable]
        XCTAssertEqual(result, [true, true, false, "Review type: Performance", true,
                                "Last updated: Not recorded", "Review type: Structure and naming", true,
                                "old", true, true])
    }

    func testPriorityOptionsDescribeIncludedFindings() async throws {
        let webView = try await DashboardWebTestHarness.mountedWebView(
            html: DashboardWebTestHarness.basicHostHTML,
            baseURL: URL(string: "https://review-loop.test")
        )
        let labels = try await webView.evaluateAsyncJavaScript("""
        (() => {
          const select = document.querySelector('[data-review-priority]');
          return [select.getAttribute('aria-label'), ...[...select.options].map(option => option.textContent)];
        })()
        """) as? [String]
        XCTAssertEqual(labels, ["Review and fix priority limit", "Critical only · P0",
                                "High and critical · P0–P1", "Medium and higher · P0–P2",
                                "All priorities · P0–P3"])
    }

    func testSidebarSpinnerCountsActiveLoopsAndNavigationRemount() async throws {
        let webView = try await DashboardWebTestHarness.mountedWebView(html: DashboardWebTestHarness.basicHostHTML, baseURL: URL(string: "https://review-loop.test"))
        let states = try await webView.evaluateAsyncJavaScript("""
        (() => {
          const api = window.__codexDashboard;
          const project = {id:'p',name:'Example',path:'/tmp/example'};
          const loop = {id:'loop-1',project,phase:'waiting',priorityLimit:'P2',completedRoundCount:0,maxRounds:5,rounds:[],message:'Waiting'};
          const snapshot = {reviewTypes: \(Self.reviewTypesJSON),projects:[project],loops:[loop],error:null};
          const spinner = () => document.querySelector('[data-review-navigation-running]');
          const states = [spinner().hidden];
          api.applyReviewPageSnapshot(snapshot);
          states.push(spinner().hidden, spinner().querySelector('[data-review-navigation-running-count]').textContent, spinner().getAttribute('aria-label'));
          loop.phase = 'running'; api.applyReviewPageSnapshot(snapshot);
          states.push(spinner().hidden);
          document.getElementById('codex-dashboard-review-navigation').remove();
          api.ensureMounted();
          states.push(spinner().hidden, spinner().querySelector('[data-review-navigation-running-count]').textContent);
          const secondLoop = {id:'loop-2',project:{id:'p2',name:'Second',path:'/tmp/second'},phase:'waiting',priorityLimit:'P2',completedRoundCount:0,maxRounds:5,rounds:[],message:'Waiting'};
          api.applyReviewPageSnapshot({...snapshot,loops:[loop,secondLoop]});
          states.push(spinner().querySelector('[data-review-navigation-running-count]').textContent, spinner().getAttribute('aria-label'), spinner().getAttribute('title'));
          loop.phase = 'paused'; api.applyReviewPageSnapshot({...snapshot,loops:[loop,secondLoop]});
          states.push(spinner().hidden, spinner().querySelector('[data-review-navigation-running-count]').textContent);
          secondLoop.phase = 'completed'; api.applyReviewPageSnapshot({...snapshot,loops:[loop,secondLoop]});
          states.push(spinner().hidden, spinner().querySelector('[data-review-navigation-running-count]').textContent);
          api.applyReviewPageSnapshot({...snapshot,loops:[]});
          states.push(spinner().hidden);
          return states;
        })()
        """) as? [AnyHashable]
        XCTAssertEqual(states, [true, false, "1", "1 running or waiting review loop", false, false, "1", "2", "2 running or waiting review loops", "2 running or waiting review loops", false, "1", true, "0", true])
    }

    func testLiveTestingAvailabilitySelectionResetAndSubmission() async throws {
        let webView = try await DashboardWebTestHarness.mountedWebView(html: DashboardWebTestHarness.basicHostHTML, baseURL: URL(string: "https://review-loop.test"))
        let result = try await webView.evaluateAsyncJavaScript("""
        (() => {
          const api = window.__codexDashboard;
          const snapshot = {reviewTypes: \(Self.reviewTypesJSON),projects:[{id:'p',name:'Example',path:'/tmp/example'}],models:\(Self.modelsJSON),loops:[],error:null};
          api.applyReviewPageSnapshot(snapshot);
          document.querySelector('[data-review-model]').value = 'model-a';
          document.querySelector('[data-fix-model]').value = 'model-a';
          const focus = document.querySelector('[data-review-focus]');
          const live = document.querySelector('[data-review-live-testing]');
          const results = [live.value, live.querySelector('option[value="true"]').textContent];
          for (const kind of ['bugs', 'bugsAndPerformance', 'organisation', 'organisationAndNaming', 'performance', 'content']) {
            live.value = 'true';
            focus.value = kind;
            focus.dispatchEvent(new Event('change'));
            results.push(document.querySelector('.review-live-testing').hidden, live.value);
            document.querySelector('[data-review-start]').click();
            const action = JSON.parse(api.pendingReviewAction());
            results.push(action.liveTesting, live.disabled);
            api.applyReviewPageSnapshot({...snapshot, acknowledgedActionID:action.id});
          }
          focus.value = 'bugs';
          focus.dispatchEvent(new Event('change'));
          results.push(live.value, live.disabled);
          return results;
        })()
        """) as? [AnyHashable]
        XCTAssertEqual(result, ["false", "On", false, "true", true, true, false, "true", true, true,
                                true, "false", false, true, true, "false", false, true,
                                false, "true", true, true, true, "false", false, true, "false", false])
    }

    func testExtensionReloadOptionRequiresLiveTestingAndQueuesSelection() async throws {
        let webView = try await DashboardWebTestHarness.mountedWebView(html: DashboardWebTestHarness.basicHostHTML, baseURL: URL(string: "https://review-loop.test"))
        let result = try await webView.evaluateAsyncJavaScript("""
        (() => {
          const api = window.__codexDashboard;
          const snapshot = {reviewTypes: \(Self.reviewTypesJSON),projects:[{id:'p',name:'Example',path:'/tmp/example'}],models:\(Self.modelsJSON),loops:[],error:null};
          api.applyReviewPageSnapshot(snapshot);
          document.querySelector('[data-review-model]').value = 'model-a';
          document.querySelector('[data-fix-model]').value = 'model-a';
          const live = document.querySelector('[data-review-live-testing]');
          const extension = document.querySelector('[data-review-extension]');
          const results = [extension.parentElement.hidden, extension.value];
          live.value = 'true';
          live.dispatchEvent(new Event('change'));
          extension.value = 'true';
          results.push(extension.parentElement.hidden);
          document.querySelector('[data-review-start]').click();
          const action = JSON.parse(api.pendingReviewAction());
          results.push(action.reloadExtensionBeforeTesting, extension.disabled);
          api.applyReviewPageSnapshot({...snapshot, acknowledgedActionID:action.id});
          results.push(extension.value);
          live.value = 'false';
          live.dispatchEvent(new Event('change'));
          results.push(extension.parentElement.hidden, extension.value);
          extension.value = 'true';
          document.querySelector('[data-review-start]').click();
          results.push(JSON.parse(api.pendingReviewAction()).reloadExtensionBeforeTesting);
          return results;
        })()
        """) as? [AnyHashable]
        XCTAssertEqual(result, [true, "false", false, true, true, "true", true, "false", false])
    }

    func testReviewTypesQueueSelectedFocusAndKeepPromptContextOptional() async throws {
        let webView = try await DashboardWebTestHarness.mountedWebView(html: DashboardWebTestHarness.basicHostHTML, baseURL: URL(string: "https://review-loop.test"))
        let result = try await webView.evaluateAsyncJavaScript("""
        (() => {
          const api = window.__codexDashboard;
          const snapshot = {reviewTypes: \(Self.reviewTypesJSON),projects:[{id:'p',name:'Example',path:'/tmp/example'}],models:\(Self.modelsJSON),loops:[],error:null};
          api.applyReviewPageSnapshot(snapshot);
          document.querySelector('[data-review-model]').value = 'model-a';
          document.querySelector('[data-fix-model]').value = 'model-a';
          const select = document.querySelector('[data-review-focus]');
          const results = [];
          for (const option of select.options) {
            select.value = option.value;
            select.dispatchEvent(new Event('change'));
            const hidden = document.querySelector('.review-priority').hidden;
            document.querySelector('[data-review-start]').click();
            const action = JSON.parse(api.pendingReviewAction());
            results.push(action.focus, hidden, action.priorityLimit);
            api.applyReviewPageSnapshot({...snapshot, acknowledgedActionID:action.id});
          }
          return results;
        })()
        """) as? [AnyHashable]
        XCTAssertEqual(result, ["bugs", false, "P2", "bugsAndPerformance", false, "P2", "organisation", true, NSNull(),
                                "organisationAndNaming", true, NSNull(), "performance", false, "P2", "content", true, NSNull()])
    }

    func testProjectContextAppearsForSupportedReviewTypes() async throws {
        let webView = try await DashboardWebTestHarness.mountedWebView(html: DashboardWebTestHarness.basicHostHTML, baseURL: URL(string: "https://review-loop.test"))
        let result = try await webView.evaluateAsyncJavaScript("""
        (() => {
          const api = window.__codexDashboard;
          const snapshot = {reviewTypes: \(Self.reviewTypesJSON),projects:[{id:'p',name:'Example',path:'/tmp/example'}],models:\(Self.modelsJSON),loops:[],error:null};
          api.applyReviewPageSnapshot(snapshot);
          document.querySelector('[data-review-model]').value = 'model-a';
          document.querySelector('[data-fix-model]').value = 'model-a';
          const focus = document.querySelector('[data-review-focus]');
          const context = document.querySelector('[data-review-prompt-context]');
          const states = [];
          for (const kind of ['bugs', 'bugsAndPerformance', 'organisation', 'organisationAndNaming', 'performance', 'content']) {
            focus.value = kind;
            focus.dispatchEvent(new Event('change'));
            states.push(kind,context.parentElement.hidden,context.value);
            if (!context.parentElement.hidden) context.value = 'personal';
            document.querySelector('[data-review-start]').click();
            const action = JSON.parse(api.pendingReviewAction());
            states.push(action.promptContext.kind);
            api.applyReviewPageSnapshot({...snapshot,acknowledgedActionID:action.id});
          }
          return states;
        })()
        """) as? [AnyHashable]
        XCTAssertEqual(result, ["bugs", false, "", "personal", "bugsAndPerformance", false, "personal", "personal", "organisation", true, "", "general",
                                "organisationAndNaming", true, "", "general", "performance", false, "", "personal",
                                "content", true, "", "general"])
    }

    func testReviewTypeLabelsAndPriorityBehaviorComeFromSnapshot() async throws {
        let webView = try await DashboardWebTestHarness.mountedWebView(
            html: DashboardWebTestHarness.basicHostHTML,
            baseURL: URL(string: "https://review-loop.test")
        )
        let result = try await webView.evaluateAsyncJavaScript("""
        (() => {
          const reviewTypes = [
            {id:'organisationAndNaming',label:'Naming audit',usesPriorities:false},
            {id:'bugs',label:'Bug audit',usesPriorities:true},
          ];
          const project = {id:'p',name:'Example',path:'/tmp/example'};
          window.__codexDashboard.applyReviewPageSnapshot({reviewTypes,projects:[project],models:[],
            loops:[{id:'loop',project,focus:'organisationAndNaming',phase:'paused',rounds:[],completedRoundCount:0,maxRounds:5}],error:null});
          const select = document.querySelector('[data-review-focus]');
          const labels = [...select.options].map(option => option.textContent);
          const namingHidesPriorities = document.querySelector('.review-priority').hidden;
          select.value = 'bugs';
          select.dispatchEvent(new Event('change'));
          return [labels.join(','),namingHidesPriorities,document.querySelector('.review-priority').hidden,
            document.querySelector('[data-review-context]').textContent.includes('Naming audit')];
        })()
        """) as? [AnyHashable]
        XCTAssertEqual(result, ["Naming audit,Bug audit", true, false, true])
    }

    func testPanelQueuesOnceAndAcknowledgesWithoutTouchingComposer() async throws {
        let webView = try await DashboardWebTestHarness.mountedWebView(html: DashboardWebTestHarness.basicHostHTML, baseURL: URL(string: "https://review-loop.test"))
        let result = try await webView.evaluateAsyncJavaScript("""
        (() => {
          window.__codexDashboard.applyReviewPageSnapshot({reviewTypes: \(Self.reviewTypesJSON),projects:[{id:'p',name:'Example',path:'/tmp/example'}],models:\(Self.modelsJSON),loops:[],error:null});
          window.__codexDashboard.openReviews();
          document.querySelector('[data-review-model]').value = 'model-a';
          document.querySelector('[data-fix-model]').value = 'model-a';
          document.querySelector('[data-review-priority]').value = 'P1';
          document.querySelector('[data-review-prompt-context]').value = 'personal';
          document.querySelector('[data-review-start]').click();
          const first = JSON.parse(window.__codexDashboard.pendingReviewAction());
          document.querySelector('[data-review-start]').click();
          const same = first.id === JSON.parse(window.__codexDashboard.pendingReviewAction()).id;
          window.__codexDashboard.applyReviewPageSnapshot({reviewTypes: \(Self.reviewTypesJSON),projects:[{id:'p',name:'Example',path:'/tmp/example'}],models:\(Self.modelsJSON),loops:[],error:'Dirty checkout',acknowledgedActionID:first.id});
          return [first.kind,first.projectID,first.maxRounds,first.promptContext.kind,first.priorityLimit,same,window.__codexDashboard.pendingReviewAction() === null,document.querySelector('[data-review-error]').textContent];
        })()
        """) as? [AnyHashable]
        XCTAssertEqual(result, ["start", "p", 5, "personal", "P1", true, true, "Dirty checkout"])
    }

    func testStartRequiresExplicitReviewAndFixModels() async throws {
        let webView = try await DashboardWebTestHarness.mountedWebView(html: DashboardWebTestHarness.basicHostHTML, baseURL: URL(string: "https://review-loop.test"))
        let result = try await webView.evaluateAsyncJavaScript("""
        (() => {
          const api = window.__codexDashboard;
          api.applyReviewPageSnapshot({reviewTypes: \(Self.reviewTypesJSON),projects:[{id:'p',name:'Example',path:'/tmp/example'}],models:\(Self.modelsJSON),loops:[],error:null});
          const review = document.querySelector('[data-review-model]');
          const fix = document.querySelector('[data-fix-model]');
          const options = [...review.options].map(option => option.textContent);
          const required = review.required && fix.required;
          const executionOptions = document.querySelector('.review-execution-options');
          executionOptions.open = false;
          document.querySelector('[data-review-start]').click();
          const withoutModels = api.pendingReviewAction();
          const reopened = executionOptions.open;
          review.value = 'model-a';
          document.querySelector('[data-review-start]').click();
          const withoutFix = api.pendingReviewAction();
          fix.value = 'model-a';
          document.querySelector('[data-review-start]').click();
          const action = JSON.parse(api.pendingReviewAction());
          return [options.join(','),required,withoutModels,reopened,withoutFix,action.reviewSelection.modelID,action.fixSelection.modelID];
        })()
        """) as? [AnyHashable]
        XCTAssertEqual(result, ["Choose a model,Model A", true, NSNull(), true, NSNull(), "model-a", "model-a"])
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
        window.__codexDashboard.applyReviewPageSnapshot({reviewTypes: \(Self.reviewTypesJSON),projects:[{id:'p',name:'Example project',path:'/tmp/example-project'}],loops:[],error:null});
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
        let webView = try await DashboardWebTestHarness.mountedWebView(html: DashboardWebTestHarness.basicHostHTML, baseURL: URL(string: "https://review-loop.test"))
        let result = try await webView.evaluateAsyncJavaScript("""
        (() => {
          const api = window.__codexDashboard;
          api.applyReviewPageSnapshot({reviewTypes: \(Self.reviewTypesJSON),projects:[{id:'p',name:'Example',path:'/tmp/example'}], models:[{modelID:'model-a',displayName:'Model A',supportedReasoningEfforts:['low','high']},{modelID:'model-b',displayName:'Model B',supportedReasoningEfforts:['medium']}],loops:[],error:null});
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
        let webView = try await DashboardWebTestHarness.mountedWebView(html: DashboardWebTestHarness.basicHostHTML, baseURL: URL(string: "https://review-loop.test"))
        let result = try await webView.evaluateAsyncJavaScript("""
        (() => {
          const api = window.__codexDashboard;
          const project = {id:'p',name:'Example <project>',path:'/tmp/example'};
          const loop = {id:'loop-1',project,phase:'running',priorityLimit:'P2',completedRoundCount:1,maxRounds:5,message:'Reviewing changes',rounds:[
            {number:1,threadID:'task-1',result:{outcome:'fixed',commit:'1234567890',summary:'Fixed <issue>'}},
            {number:2,threadID:'task-2',fixRequested:false}
          ]};
          const snapshot = {reviewTypes: \(Self.reviewTypesJSON),projects:[project],loops:[loop],error:null};
          api.applyReviewPageSnapshot(snapshot);
          api.openReviews();
          document.querySelector('.review-round-details').open = true;
          api.applyReviewPageSnapshot(snapshot);
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
          api.applyReviewPageSnapshot(snapshot);
          active.push(document.querySelector('[data-review-action="pause"]').disabled,
            document.querySelector('[data-review-action="pause"]').textContent);
          loop.phase = 'completed';
          snapshot.finishedLoopIDs = [loop.id];
          api.applyReviewPageSnapshot(snapshot);
          return [...active,document.querySelector('[data-review-form]').hidden,
            document.querySelector('[data-review-controls]').children.length,
            document.querySelector('[data-review-badge]').textContent];
        })()
        """) as? [AnyHashable]
        XCTAssertEqual(result, [false, true, "Example <project>", true, "Fixed <issue>", "Pause after round", 1, "1 of 5", true, true, "Pausing after round…", false, 1, "Completed"])
    }

    func testFinishedLoopStaysOnBoardUntilClearedOrPageCloses() async throws {
        let webView = try await DashboardWebTestHarness.mountedWebView(html: DashboardWebTestHarness.basicHostHTML, baseURL: URL(string: "https://review-loop.test"))
        let result = try await webView.evaluateAsyncJavaScript("""
        (() => {
          const api = window.__codexDashboard;
          const project = {id:'p',name:'Example',path:'/tmp/example'};
          const loop = {id:'loop-1',project,phase:'running',completedRoundCount:0,maxRounds:1,rounds:[],message:'Reviewing'};
          const snapshot = {reviewTypes: \(Self.reviewTypesJSON),projects:[project],loops:[loop],finishedLoopIDs:[],error:null};
          const board = () => document.querySelector('[data-review-board]');
          const history = () => document.querySelector('[data-review-history]');
          api.applyReviewPageSnapshot(snapshot);
          api.openReviews();
          loop.phase = 'completed';
          loop.message = 'No findings remain.';
          snapshot.finishedLoopIDs = [loop.id];
          api.applyReviewPageSnapshot(snapshot);
          api.applyReviewPageSnapshot(snapshot);
          const retained = [board().children.length, board().querySelector('[data-review-status]').textContent,
            !!board().querySelector('[data-review-clear]'), history().hidden];
          board().querySelector('[data-review-clear]').click();
          const cleared = [board().children.length, history().hidden, document.querySelector('[data-review-history-select]').value];
          api.openTodos();
          api.openReviews();
          const reopened = [board().children.length, history().hidden];
          loop.phase = 'running';
          snapshot.finishedLoopIDs = [];
          api.applyReviewPageSnapshot(snapshot);
          loop.phase = 'limitReached';
          snapshot.finishedLoopIDs = [loop.id];
          api.applyReviewPageSnapshot(snapshot);
          const retainedAgain = board().children.length;
          api.openTodos();
          api.openReviews();
          return [...retained, ...cleared, ...reopened, retainedAgain, board().children.length, history().hidden];
        })()
        """) as? [AnyHashable]
        XCTAssertEqual(result, [1, "No findings remain.", true, true, 0, false, "loop-1", 0, false, 1, 0, false])
    }

    func testRoundsShowFindingsAndTheirPriorities() async throws {
        let webView = try await DashboardWebTestHarness.mountedWebView(html: DashboardWebTestHarness.basicHostHTML, baseURL: URL(string: "https://review-loop.test"))
        let result = try await webView.evaluateAsyncJavaScript("""
        (() => {
          const project = {id:'p',name:'Example',path:'/tmp/example'};
          const loop = {id:'loop-1',project,phase:'running',priorityLimit:'P2',completedRoundCount:0,maxRounds:3,message:'Reviewing',rounds:[
            {number:1,review:{findings:[
              {priority:'P1',title:'Broken <link>',body:'Fails on the first click.'},
              {priority:'P2',title:'Stale confirmation',body:'Can open the wrong step.'}
            ]},result:{outcome:'fixed',summary:'Addressed both findings'}},
            {number:2,review:{findings:[{priority:null,title:'Unranked issue',body:'Still actionable.'}]},fixRequested:true},
            {number:3,fixRequested:false}
          ]};
          window.__codexDashboard.applyReviewPageSnapshot({reviewTypes: \(Self.reviewTypesJSON),projects:[project],loops:[loop],error:null});
          window.__codexDashboard.openReviews();
          const rounds = [...document.querySelectorAll('[data-review-rounds] > li')];
          const findings = [...document.querySelectorAll('.review-round-findings li')];
          return [rounds.length,findings.length,
            findings.map(item => item.querySelector('strong').textContent).join('|'),
            findings.map(item => item.querySelector('.review-finding-priority')?.textContent || '').join('|'),
            findings[0].querySelector('p').textContent,
            rounds[2].querySelector('.review-round-findings') === null,
            document.querySelector('.review-round-details').open,
            document.querySelector('.review-round-findings').innerHTML.includes('&lt;link&gt;')];
        })()
        """) as? [AnyHashable]
        XCTAssertEqual(result, [3, 3, "Broken <link>|Stale confirmation|Unranked issue", "P1|P2|", "Fails on the first click.", true, false, true])
    }

    func testFindingsCollapseOnCompletionAndPreserveManualVisibilityDuringRefresh() async throws {
        let webView = try await DashboardWebTestHarness.mountedWebView(html: DashboardWebTestHarness.basicHostHTML, baseURL: URL(string: "https://review-loop.test"))
        let result = try await webView.evaluateAsyncJavaScript("""
        (() => {
          const api = window.__codexDashboard;
          const project = {id:'p',name:'Example',path:'/tmp/example'};
          const round = number => ({number,review:{findings:[{title:'Issue',body:'Details'}]}});
          const loop = {id:'loop',project,phase:'running',completedRoundCount:0,maxRounds:3,rounds:[round(1),round(2)]};
          const snapshot = {reviewTypes: \(Self.reviewTypesJSON),projects:[project],loops:[loop],error:null};
          api.applyReviewPageSnapshot(snapshot); api.openReviews();
          const findings = () => [...document.querySelectorAll('.review-findings-details')];
          const visible = details => details.querySelector('ul').getBoundingClientRect().height > 0;
          const initial = findings().every(details => details.open && visible(details));
          findings()[0].querySelector('summary').click();
          loop.rounds[0].result = {outcome:'fixed',summary:'Fixed'};
          loop.rounds.push(round(3));
          api.applyReviewPageSnapshot(snapshot);
          const refreshed = [findings()[0].open,visible(findings()[0]),findings()[1].open,findings()[2].open,
            document.querySelector('.review-round-details').open];
          findings()[0].querySelector('summary').click();
          api.applyReviewPageSnapshot(snapshot);
          const reopened = [findings()[0].open,visible(findings()[0])];
          loop.rounds[1].result = {outcome:'fixed',summary:'Fixed'};
          api.applyReviewPageSnapshot(snapshot);
          const completed = [findings()[1].open,visible(findings()[1]),findings()[2].open];
          loop.phase = 'stopped';
          snapshot.finishedLoopIDs = [loop.id];
          api.applyReviewPageSnapshot(snapshot);
          const stopped = [findings()[2].open,visible(findings()[2])];
          findings()[2].querySelector('summary').click();
          api.applyReviewPageSnapshot(snapshot);
          return [initial,...refreshed,...reopened,...completed,...stopped,findings()[2].open];
        })()
        """) as? [AnyHashable]
        XCTAssertEqual(result, [true, false, false, true, true, false, true, true, false, false, true, false, false, true])
    }

    func testFindingFileLinksOpenThroughReviewActionAndUnsafeSchemesStayText() async throws {
        let webView = try await DashboardWebTestHarness.mountedWebView(html: DashboardWebTestHarness.basicHostHTML, baseURL: URL(string: "https://review-loop.test"))
        let result = try await webView.evaluateAsyncJavaScript("""
        (() => {
          const project = {id:'p',name:'Example',path:'/tmp/example'};
          const loop = {id:'loop-1',project,phase:'completed',completedRoundCount:0,maxRounds:1,rounds:[{number:1,
            review:{findings:[{priority:'P2',title:'A <bug>',body:'See [source](/tmp/example/Sources/File.swift:12), [relative](File.swift:4), [docs](https://example.com/guide), and [unsafe](javascript:alert(1)).'}]}}]};
          window.__codexDashboard.applyReviewPageSnapshot({reviewTypes: \(Self.reviewTypesJSON),projects:[project],loops:[loop],finishedLoopIDs:['loop-1'],error:null});
          window.__codexDashboard.openReviews();
          const finding = document.querySelector('.review-round-findings p');
          const file = finding.querySelector('[data-review-file]');
          const relative = finding.querySelectorAll('[data-review-file]')[1];
          const docs = finding.querySelector('a');
          const unsafe = finding.textContent.includes('[unsafe](javascript:alert(1))');
          file.click();
          const action = JSON.parse(window.__codexDashboard.pendingReviewAction());
          return [file.textContent,file.dataset.reviewFile,relative.dataset.reviewFile,
            docs.href,docs.rel,unsafe,action.kind,action.loopID,action.filePath];
        })()
        """) as? [AnyHashable]
        XCTAssertEqual(result, ["source", "/tmp/example/Sources/File.swift:12", "File.swift:4",
                                "https://example.com/guide", "noopener noreferrer", true,
                                "openFile", "loop-1", "/tmp/example/Sources/File.swift:12"])
    }

    func testRoundLimitShowsFinalStatusWithoutResume() async throws {
        let webView = try await DashboardWebTestHarness.mountedWebView(html: DashboardWebTestHarness.basicHostHTML, baseURL: URL(string: "https://review-loop.test"))
        let result = try await webView.evaluateAsyncJavaScript("""
        (() => {
          const project = {id:'p',name:'Example',path:'/tmp/example'};
          const loop = {id:'limited',project,phase:'limitReached',priorityLimit:'P2',completedRoundCount:1,maxRounds:1,
            message:'All configured review rounds completed.',
            rounds:[{number:1,result:{outcome:'fixed',commit:'1234567890',summary:'Fixed issue'}}]};
          window.__codexDashboard.applyReviewPageSnapshot({reviewTypes: \(Self.reviewTypesJSON),projects:[project],loops:[loop],finishedLoopIDs:[loop.id],error:null,
            progress:{[loop.id]:{step:'Round limit reached',currentLabel:'Latest prompt',current:null,upcoming:null,
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
        XCTAssertEqual(result, ["Round limit reached", "Round limit reached", 0, false, "All configured review rounds completed.", true])
    }

    func testLivePromptsStayVisibleAfterRefreshAndRenderAsText() async throws {
        let webView = try await DashboardWebTestHarness.mountedWebView(html: DashboardWebTestHarness.basicHostHTML, baseURL: URL(string: "https://review-loop.test"))
        let result = try await webView.evaluateAsyncJavaScript("""
        (() => {
          const api = window.__codexDashboard;
          const project = {id:'p',name:'Example',path:'/tmp/example'};
          const snapshot = {reviewTypes: \(Self.reviewTypesJSON),projects:[project],error:null,
            loops:[{id:'live',project,phase:'running',priorityLimit:'P2',completedRoundCount:0,maxRounds:5,rounds:[],message:'Reviewing'}],
            progress:{live:{step:'Reviewing',currentLabel:'Current prompt',threadID:'task-1',nextMessage:'',
              current:{title:'Review · round 1',text:'Review <code> & files',note:''},
              upcoming:{title:'Fix & commit',text:'Address all and commit',note:'Only if issues are found.'}}}};
          api.applyReviewPageSnapshot(snapshot);
          const current = document.querySelector('[data-review-current-prompt]');
          const upcoming = document.querySelector('[data-review-upcoming-prompt]');
          api.applyReviewPageSnapshot(snapshot);
          const active = [!document.querySelector('[data-review-live]').hidden,
            current.tagName,upcoming.tagName,!current.hidden,!upcoming.hidden,
            document.querySelector('[data-review-current-text]').textContent,
            document.querySelector('[data-review-upcoming-text]').textContent,
            document.querySelector('[data-review-current-text]').children.length,
            document.querySelector('[data-review-current-task]').dataset.reviewThread];
          snapshot.loops[0].phase = 'completed';
          snapshot.finishedLoopIDs = ['live'];
          snapshot.progress.live.upcoming = null;
          snapshot.progress.live.nextMessage = 'No further prompts scheduled.';
          api.applyReviewPageSnapshot(snapshot);
          return [...active,document.querySelector('[data-review-upcoming-prompt]').hidden,
            document.querySelector('[data-review-next-message]').textContent];
        })()
        """) as? [AnyHashable]
        XCTAssertEqual(result, [true, "DIV", "DIV", true, true, "Review <code> & files", "Address all and commit", 0, "task-1", true, "No further prompts scheduled."])
    }

    func testRequestUsesLocalDesktopConnectionAndCorrelatesResponses() async throws {
        let webView = try await DashboardWebTestHarness.mountedWebView(html: DashboardWebTestHarness.basicHostHTML, baseURL: URL(string: "https://review-loop.test"))
        let result = try await webView.evaluateAsyncJavaScript("""
        (async () => {
          window.electronBridge = {sendMessageFromView: async request => {
            window.dispatchEvent(new MessageEvent('message',{data:{type:'mcp-response',hostId:'remote',message:{id:request.request.id,result:{wrong:true}}}}));
            window.dispatchEvent(new MessageEvent('message',{data:{type:'mcp-response',hostId:'local',message:{id:request.request.id,result:{method:request.request.method,host:request.hostId}}}}));
          }};
          const response = JSON.parse(await window.__codexDashboard.reviewRequest({method:'project/list',params:{limit:100}}));
          const interrupted = JSON.parse(await window.__codexDashboard.reviewRequest({method:'turn/interrupt',params:{threadId:'thread',turnId:'turn'}}));
          const rejected = JSON.parse(await window.__codexDashboard.reviewRequest({method:'thread/archive',params:{}}));
          return [response.result.method,response.result.host,interrupted.result.method,!!rejected.error];
        })()
        """) as? [AnyHashable]
        XCTAssertEqual(result, ["project/list", "local", "turn/interrupt", true])
    }

    func testTeardownSettlesPendingRequestWithoutRetry() async throws {
        let webView = try await DashboardWebTestHarness.mountedWebView(html: DashboardWebTestHarness.basicHostHTML, baseURL: URL(string: "https://review-loop.test"))
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
