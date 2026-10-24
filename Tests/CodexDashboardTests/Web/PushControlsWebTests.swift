import WebKit
import XCTest

@testable import CodexDashboard

@MainActor
final class PushControlsWebTests: SerializedDashboardWebTestCase {

    private func fixture() async throws -> WKWebView {
        try await DashboardWebTestHarness.mountedWebView(html: """
        <!doctype html><html><body>
        <aside role="navigation"><button class="sidebar-item">New chat</button></aside>
        <main><div id="composer"><textarea placeholder="Do anything"></textarea></div></main>
        <div role="dialog" id="commit-dialog"><div class="command-menu-dialog">
          <div cmdk-root data-codex-shortcut-capture><input id="message">
            <div cmdk-item role="option" data-value="commit" aria-selected="false">Commit</div>
            <div cmdk-item role="option" data-value="commit-and-push" aria-selected="true">Commit and push</div>
            <div cmdk-item role="option" data-value="push" aria-disabled="true" data-disabled="true">Push</div>
          </div>
        </div></div>
        <script>
          window.activeProps = { conversationId: 'thread' };
          document.getElementById('composer').__reactFiber$test = { memoizedProps: activeProps };
          window.modalProps = { open: true, conversationId: 'thread', enablePushActions: true,
            onOpenChange() {}, target: { root: '/tmp/repository', hostConfig: { id: 'local' } } };
          document.getElementById('commit-dialog').__reactFiber$test = { memoizedProps: modalProps };
          window.requestSequence = 0;
          crypto.randomUUID = () => `fixture-${++requestSequence}`;
          window.remoteRequests = [];
          window.workerListener = null;
          window.electronBridge = {
            subscribeToWorkerMessages(workerID, receive) { workerListener = receive; return () => { workerListener = null; }; },
            sendWorkerMessageFromView(workerID, message) {
              remoteRequests.push(message);
              if (message.type === 'worker-request') window.lastRemoteRequest = message.request;
              return Promise.resolve();
            },
          };
          window.respondRemote = (value, request = lastRemoteRequest, override = {}) => workerListener?.({
            type: 'worker-response', workerId: 'git', response: {
              id: request.id, method: request.method,
              result: value === null ? { type: 'error', error: { message: 'Unavailable' } }
                : { type: 'ok', value: { status: 'complete', remotes: value ? [{ name: 'custom' }] : [], remotesOmitted: 0, ...override } },
            },
          });
          window.activations = [];
          document.querySelectorAll('[cmdk-item]').forEach(item => {
            for (const type of ['click', 'cmdk-item-select']) item.addEventListener(type, () => activations.push(item.dataset.value));
          });
          document.querySelector('[cmdk-root]').addEventListener('keydown', e => {
            if (e.key === 'Enter') activations.push('keyboard');
          });
        </script></body></html>
        """)
    }

    func testDialogRequestsMetadataImmediatelyAndBlocksOnlyPushAfterReply() async throws {
        let webView = try await fixture()
        let result = try await webView.evaluateJavaScript("""
        (() => {
          // No dashboard read/poll is needed to issue or apply this request.
          const requestsAtMount = remoteRequests.filter(r => r.type === 'worker-request').length;
          respondRemote(false);
          document.querySelector('[data-value="commit-and-push"]').click();
          document.querySelector('[data-value="push"]').dispatchEvent(new Event('cmdk-item-select'));
          document.getElementById('message').dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', metaKey: true, bubbles: true }));
          document.querySelector('[data-value="commit"]').click();
          return [requestsAtMount, lastRemoteRequest.method, lastRemoteRequest.params.cwd,
            document.querySelectorAll('[data-dashboard-no-remote]').length, activations.join(',')];
        })()
        """) as? [Any]
        let values = try XCTUnwrap(result)
        XCTAssertEqual(values[0] as? Int, 1)
        XCTAssertEqual(values[1] as? String, "git-context")
        XCTAssertEqual(values[2] as? String, "/tmp/repository")
        XCTAssertEqual(values[3] as? Int, 2)
        XCTAssertEqual(values[4] as? String, "commit")
    }

    func testReopeningUsesFreshCacheImmediatelyAndRevalidatesRemoteAdded() async throws {
        let webView = try await fixture()
        let result = try await webView.evaluateJavaScript("""
        (() => {
          respondRemote(false);
          modalProps.open = false;
          window.__codexDashboard.readPushControls();
          modalProps.open = true;
          window.__codexDashboard.readPushControls();
          const cached = document.querySelectorAll('[data-dashboard-no-remote]').length;
          respondRemote(true);
          return [cached, remoteRequests.filter(r => r.type === 'worker-request').length,
            document.querySelector('[data-value="commit-and-push"]').getAttribute('aria-disabled'),
            document.querySelector('[data-value="push"]').getAttribute('aria-disabled')];
        })()
        """) as? [Any]
        let values = try XCTUnwrap(result)
        XCTAssertEqual(values[0] as? Int, 2)
        XCTAssertEqual(values[1] as? Int, 2)
        XCTAssertTrue(values[2] is NSNull)
        XCTAssertEqual(values[3] as? String, "true")
    }

    func testExpiredCacheIsNotAppliedAndUnreadableMetadataRaisesWarning() async throws {
        let webView = try await fixture()
        let result = try await webView.evaluateJavaScript("""
        (() => {
          respondRemote(false);
          const now = Date.now(); Date.now = () => now + 6000;
          modalProps.open = false; window.__codexDashboard.readPushControls();
          modalProps.open = true; window.__codexDashboard.readPushControls();
          const expired = document.querySelectorAll('[data-dashboard-no-remote]').length;
          respondRemote(null);
          return [expired, window.__codexDashboard.readPushControls().state,
            document.querySelectorAll('[data-dashboard-no-remote]').length];
        })()
        """) as? [Any]
        let values = try XCTUnwrap(result)
        XCTAssertEqual(values[0] as? Int, 0)
        XCTAssertEqual(values[1] as? String, "remote-unavailable")
        XCTAssertEqual(values[2] as? Int, 0)
    }

    func testRepositorySwitchRejectsOldReplyAndRemoteHostsAreExcluded() async throws {
        let webView = try await fixture()
        let result = try await webView.evaluateJavaScript("""
        (() => {
          const old = lastRemoteRequest;
          modalProps.target.root = '/tmp/another-repository';
          window.__codexDashboard.readPushControls();
          respondRemote(false, old);
          const stale = document.querySelectorAll('[data-dashboard-no-remote]').length;
          respondRemote(false);
          const current = document.querySelectorAll('[data-dashboard-no-remote]').length;
          modalProps.target.hostConfig.id = 'remote-machine';
          const remote = window.__codexDashboard.readPushControls();
          return [stale, current, remote.path, document.querySelectorAll('[data-dashboard-no-remote]').length];
        })()
        """) as? [Any]
        let values = try XCTUnwrap(result)
        XCTAssertEqual(values[0] as? Int, 0)
        XCTAssertEqual(values[1] as? Int, 2)
        XCTAssertTrue(values[2] is NSNull)
        XCTAssertEqual(values[3] as? Int, 0)
    }

    func testChangedControlsAndTeardownRestoreHostStatesAndUnsubscribe() async throws {
        let webView = try await fixture()
        let result = try await webView.evaluateJavaScript("""
        (() => {
          respondRemote(false);
          document.querySelector('[data-value="push"]').setAttribute('data-value', 'new-push-command');
          const changed = window.__codexDashboard.readPushControls();
          const restored = document.querySelectorAll('[data-dashboard-no-remote]').length;
          window.__codexDashboard.destroy();
          return [changed.state, restored, workerListener === null];
        })()
        """) as? [Any]
        let values = try XCTUnwrap(result)
        XCTAssertEqual(values[0] as? String, "incompatible")
        XCTAssertEqual(values[1] as? Int, 0)
        XCTAssertEqual(values[2] as? Bool, true)
    }

    func testRestorationPreservesNewDisabledStateRenderedByCodex() async throws {
        let webView = try await fixture()
        let result = try await webView.evaluateJavaScript("""
        (() => {
          respondRemote(false);
          const item = document.querySelector('[data-value="commit-and-push"]');
          item.__reactFiber$test = { memoizedProps: { 'aria-disabled': true, 'data-disabled': true } };
          window.__codexDashboard.destroy();
          return [item.getAttribute('aria-disabled'), item.getAttribute('data-disabled'), item.hasAttribute('data-dashboard-no-remote')];
        })()
        """) as? [Any]
        let values = try XCTUnwrap(result)
        XCTAssertEqual(values[0] as? String, "true")
        XCTAssertEqual(values[1] as? String, "true")
        XCTAssertEqual(values[2] as? Bool, false)
    }

    func testChangedTargetContractIsReportedWithoutModifyingControls() async throws {
        let webView = try await fixture()
        let result = try await webView.evaluateJavaScript("""
        (() => {
          respondRemote(false);
          delete modalProps.target;
          return [window.__codexDashboard.readPushControls().state,
            document.querySelectorAll('[data-dashboard-no-remote]').length];
        })()
        """) as? [Any]
        let values = try XCTUnwrap(result)
        XCTAssertEqual(values[0] as? String, "incompatible")
        XCTAssertEqual(values[1] as? Int, 0)
    }

    func testChatSwitchCancelsRequestAndRejectsPendingReply() async throws {
        let webView = try await fixture()
        let result = try await webView.evaluateJavaScript("""
        (() => {
          const old = lastRemoteRequest;
          activeProps.conversationId = 'other-thread';
          window.__codexDashboard.readPushControls();
          respondRemote(false, old);
          return [remoteRequests.some(r => r.type === 'worker-request-cancel' && r.id === old.id),
            document.querySelectorAll('[data-dashboard-no-remote]').length];
        })()
        """) as? [Any]
        let values = try XCTUnwrap(result)
        XCTAssertEqual(values[0] as? Bool, true)
        XCTAssertEqual(values[1] as? Int, 0)
    }

    func testMissingWorkerChannelLeavesControlsAloneAndReportsWarning() async throws {
        let webView = try await fixture()
        let result = try await webView.evaluateJavaScript("""
        (() => {
          respondRemote(false);
          electronBridge.sendWorkerMessageFromView = () => { throw new Error('Bridge changed'); };
          modalProps.target.root = '/tmp/new-repository';
          return [window.__codexDashboard.readPushControls().state,
            document.querySelectorAll('[data-dashboard-no-remote]').length];
        })()
        """) as? [Any]
        let values = try XCTUnwrap(result)
        XCTAssertEqual(values[0] as? String, "remote-unavailable")
        XCTAssertEqual(values[1] as? Int, 0)
    }

    func testTimedOutWorkerReplyIsIgnoredAndTeardownCancelsRequests() async throws {
        let webView = try await fixture()
        try await DashboardWebTestHarness.waitForJavaScript(
            "window.__codexDashboard.readPushControls().state === 'remote-unavailable'", in: webView, timeout: .seconds(4))
        let result = try await webView.evaluateJavaScript("""
        (() => {
          respondRemote(false);
          const afterTimeout = document.querySelectorAll('[data-dashboard-no-remote]').length;
          modalProps.target.root = '/tmp/new-repository';
          window.__codexDashboard.readPushControls();
          const pending = lastRemoteRequest.id;
          window.__codexDashboard.destroy();
          return [afterTimeout, workerListener === null,
            remoteRequests.some(r => r.type === 'worker-request-cancel' && r.id === pending)];
        })()
        """) as? [Any]
        let values = try XCTUnwrap(result)
        XCTAssertEqual(values[0] as? Int, 0)
        XCTAssertEqual(values[1] as? Bool, true)
        XCTAssertEqual(values[2] as? Bool, true)
    }

    func testOmittedRemotesCannotBeMistakenForNoRemote() async throws {
        let webView = try await fixture()
        let result = try await webView.evaluateJavaScript("""
        (() => {
          respondRemote(false, lastRemoteRequest, { status: 'partial', remotesOmitted: 1 });
          return [window.__codexDashboard.readPushControls().state,
            document.querySelectorAll('[data-dashboard-no-remote]').length];
        })()
        """) as? [Any]
        let values = try XCTUnwrap(result)
        XCTAssertEqual(values[0] as? String, "remote-unavailable")
        XCTAssertEqual(values[1] as? Int, 0)
    }
}
