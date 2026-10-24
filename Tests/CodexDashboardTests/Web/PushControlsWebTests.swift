import WebKit
import XCTest

@testable import CodexDashboard

@MainActor
final class PushControlsWebTests: XCTestCase {
    override func tearDown() {
        DashboardWebTestHarness.releaseWebViews()
        super.tearDown()
    }

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
          window.activations = [];
          document.querySelectorAll('[cmdk-item]').forEach(item => {
            for (const type of ['click', 'cmdk-item-select']) {
              item.addEventListener(type, () => activations.push(item.dataset.value));
            }
          });
          document.querySelector('[cmdk-root]').addEventListener('keydown', e => {
            if (e.key === 'Enter') activations.push('keyboard');
          });
        </script></body></html>
        """)
    }

    func testNoRemoteBlocksPushByMouseKeyboardAndCommandSelectionButAllowsCommit() async throws {
        let webView = try await fixture()
        let result = try await webView.evaluateJavaScript("""
        (() => {
          const bridge = window.__codexDashboard;
          const state = bridge.readPushControls();
          bridge.applyPushRemote(state.requestID, false);
          document.querySelector('[data-value="commit-and-push"]').click();
          document.querySelector('[data-value="push"]').dispatchEvent(new Event('cmdk-item-select'));
          document.getElementById('message').dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', metaKey: true, bubbles: true }));
          document.querySelector('[data-value="commit"]').click();
          return [state.path, state.state, document.querySelectorAll('[data-dashboard-no-remote]').length, activations.join(',')];
        })()
        """) as? [Any]
        let values = try XCTUnwrap(result)
        XCTAssertEqual(values[0] as? String, "/tmp/repository")
        XCTAssertEqual(values[1] as? String, "compatible")
        XCTAssertEqual(values[2] as? Int, 2)
        XCTAssertEqual(values[3] as? String, "commit")
    }

    func testRemoteAddedRestoresHostDisabledStateAndUnknownDoesNotDisable() async throws {
        let webView = try await fixture()
        let result = try await webView.evaluateJavaScript("""
        (() => {
          const bridge = window.__codexDashboard;
          const id = bridge.readPushControls().requestID;
          bridge.applyPushRemote(id, null);
          const unknown = document.querySelectorAll('[data-dashboard-no-remote]').length;
          bridge.applyPushRemote(id, false);
          bridge.applyPushRemote(id, true);
          return [unknown, document.querySelector('[data-value="commit-and-push"]').getAttribute('aria-disabled'),
            document.querySelector('[data-value="push"]').getAttribute('aria-disabled'),
            document.querySelectorAll('[data-dashboard-no-remote]').length];
        })()
        """) as? [Any]
        let values = try XCTUnwrap(result)
        XCTAssertEqual(values[0] as? Int, 0)
        XCTAssertTrue(values[1] is NSNull)
        XCTAssertEqual(values[2] as? String, "true")
        XCTAssertEqual(values[3] as? Int, 0)
    }

    func testRepositorySwitchRejectsOldResultAndRemoteHostsAreExcluded() async throws {
        let webView = try await fixture()
        let result = try await webView.evaluateJavaScript("""
        (() => {
          const bridge = window.__codexDashboard;
          const old = bridge.readPushControls().requestID;
          bridge.applyPushRemote(old, false);
          modalProps.target.root = '/tmp/another-repository';
          const next = bridge.readPushControls();
          const staleApplied = bridge.applyPushRemote(old, false);
          modalProps.target.hostConfig.id = 'remote-machine';
          const remote = bridge.readPushControls();
          return [next.path, staleApplied, remote.path, document.querySelectorAll('[data-dashboard-no-remote]').length];
        })()
        """) as? [Any]
        let values = try XCTUnwrap(result)
        XCTAssertEqual(values[0] as? String, "/tmp/another-repository")
        XCTAssertEqual(values[1] as? Bool, false)
        XCTAssertTrue(values[2] is NSNull)
        XCTAssertEqual(values[3] as? Int, 0)
    }

    func testChangedControlsDisableFeatureAndDestroyRestoresControls() async throws {
        let webView = try await fixture()
        let result = try await webView.evaluateJavaScript("""
        (() => {
          const bridge = window.__codexDashboard;
          bridge.applyPushRemote(bridge.readPushControls().requestID, false);
          document.querySelector('[data-value="push"]').setAttribute('data-value', 'new-push-command');
          const changed = bridge.readPushControls();
          const restored = document.querySelectorAll('[data-dashboard-no-remote]').length;
          document.querySelector('[data-value="new-push-command"]').setAttribute('data-value', 'push');
          bridge.applyPushRemote(bridge.readPushControls().requestID, false);
          bridge.destroy();
          return [changed.state, restored, document.querySelectorAll('[data-dashboard-no-remote]').length,
            document.querySelector('[data-value="commit-and-push"]').getAttribute('aria-disabled')];
        })()
        """) as? [Any]
        let values = try XCTUnwrap(result)
        XCTAssertEqual(values[0] as? String, "incompatible")
        XCTAssertEqual(values[1] as? Int, 0)
        XCTAssertEqual(values[2] as? Int, 0)
        XCTAssertTrue(values[3] is NSNull)
    }

    func testRestorationPreservesNewDisabledStateRenderedByCodex() async throws {
        let webView = try await fixture()
        let result = try await webView.evaluateJavaScript("""
        (() => {
          const bridge = window.__codexDashboard;
          const id = bridge.readPushControls().requestID;
          bridge.applyPushRemote(id, false);
          const item = document.querySelector('[data-value="commit-and-push"]');
          item.__reactFiber$test = { memoizedProps: { 'aria-disabled': true, 'data-disabled': true } };
          bridge.applyPushRemote(id, true);
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
          const bridge = window.__codexDashboard;
          const id = bridge.readPushControls().requestID;
          bridge.applyPushRemote(id, false);
          delete modalProps.target;
          return [bridge.readPushControls().state, bridge.applyPushRemote(id, false),
            document.querySelectorAll('[data-dashboard-no-remote]').length];
        })()
        """) as? [Any]
        let values = try XCTUnwrap(result)
        XCTAssertEqual(values[0] as? String, "incompatible")
        XCTAssertEqual(values[1] as? Bool, false)
        XCTAssertEqual(values[2] as? Int, 0)
    }

    func testChatSwitchRestoresControlsAndRejectsPendingResult() async throws {
        let webView = try await fixture()
        let result = try await webView.evaluateJavaScript("""
        (() => {
          const bridge = window.__codexDashboard;
          const id = bridge.readPushControls().requestID;
          bridge.applyPushRemote(id, false);
          activeProps.conversationId = 'other-thread';
          const applied = bridge.applyPushRemote(id, false);
          return [applied, document.querySelectorAll('[data-dashboard-no-remote]').length];
        })()
        """) as? [Any]
        let values = try XCTUnwrap(result)
        XCTAssertEqual(values[0] as? Bool, false)
        XCTAssertEqual(values[1] as? Int, 0)
    }
}
