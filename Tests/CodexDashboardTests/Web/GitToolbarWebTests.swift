import WebKit
import XCTest

@testable import CodexDashboard

@MainActor
final class GitToolbarWebTests: SerializedDashboardWebTestCase {
    private func fixture(noRemote: Bool = false) async throws -> WKWebView {
        let webView = try await DashboardWebTestHarness.mountedWebView(html: """
        <!doctype html><html><body>
          <aside><nav><div class="sidebar-item"><button>New chat</button></div></nav></aside>
          <main>
            <div data-app-shell-header-toolbar><div>Chat title</div><div id="header-actions">
              <div data-app-shell-focus-area="main"><button aria-label="Chat actions">…</button></div>
            </div></div>
            <div id="composer"><textarea></textarea></div>
            <div hidden><button id="other-git" aria-label="Git actions"></button></div>
            <div hidden><button id="current-git" aria-label="Git actions" aria-controls="git-menu"></button></div>
          </main>
          <script>
            window.selected = 'current';
            window.noRemote = \(noRemote);
            let remoteListener;
            let sequence = 0;
            crypto.randomUUID = () => `toolbar-${++sequence}`;
            window.electronBridge = {
              subscribeToWorkerMessages(worker, callback) { if (worker === 'git') remoteListener = callback; return () => {}; },
              sendWorkerMessageFromView(worker, message) {
                if (worker === 'git' && message.type === 'worker-request') setTimeout(() => remoteListener({
                  type: 'worker-response', workerId: 'git', response: {
                    id: message.request.id, method: 'git-context', result: { type: 'ok', value: {
                      status: 'complete', remotes: window.noRemote ? [] : [{ name: 'origin' }], remotesOmitted: 0
                    } }
                  }
                }), 10);
                return Promise.resolve();
              }
            };
            window.actions = [];
            window.allowCommit = true;
            window.delayMenu = 0;
            document.getElementById('composer').__reactFiber$test = {
              get memoizedProps() { return { conversationId: window.selected }; }
            };
            function attachGit(id, threadID, path) {
              const trigger = document.getElementById(id);
              const menu = {
                triggerButton: { props: { label: 'Git actions' } },
                children: { props: { children: [{ props: { children: { props: { id: 'localConversation.gitActions.commit' } } } }] } },
                open: false,
                onOpenChange(open) {
                  menu.open = open;
                  document.getElementById('git-wrapper')?.remove();
                  if (!open) return;
                  setTimeout(() => {
                    if (!menu.open) return;
                    const wrapper = document.createElement('div');
                    wrapper.id = 'git-wrapper';
                    wrapper.setAttribute('data-radix-popper-content-wrapper', '');
                    const content = document.createElement('div');
                    content.id = 'git-menu'; content.setAttribute('role', 'menu');
                    for (const action of ['Commit', 'Push', 'Switch branch']) {
                      const item = document.createElement('button');
                      item.setAttribute('role', 'menuitem'); item.textContent = action;
                      item.setAttribute('aria-disabled', String(action === 'Push' || (action === 'Commit' && !window.allowCommit)));
                      item.addEventListener('click', () => {
                        window.actions.push([threadID, path, action]);
                        if (action === 'Commit' && window.showCommitDialog) {
                          const dialog = document.createElement('div'); dialog.setAttribute('role', 'dialog');
                          const root = document.createElement('div'); root.setAttribute('cmdk-root', '');
                          root.setAttribute('data-codex-shortcut-capture', ''); root.tabIndex = -1;
                          for (const value of ['commit', 'commit-and-push', 'push']) {
                            const option = document.createElement('div');
                            option.setAttribute('cmdk-item', ''); option.setAttribute('role', 'option');
                            option.setAttribute('data-value', value); option.setAttribute('aria-selected', String(value === 'commit'));
                            option.setAttribute('aria-disabled', 'false'); option.setAttribute('data-disabled', 'false');
                            option.addEventListener('click', () => { window.confirmed = true; });
                            root.append(option);
                          }
                          dialog.__reactFiber$test = { memoizedProps: { open: true, enablePushActions: true,
                            onOpenChange() {}, conversationId: threadID, target: { root: path, hostConfig: { id: 'local' } } } };
                          dialog.append(root); document.body.append(dialog);
                        }
                      });
                      content.append(item);
                    }
                    wrapper.append(content); document.body.append(wrapper);
                  }, window.delayMenu);
                }
              };
              trigger.__reactFiber$test = { memoizedProps: {}, return: { memoizedProps: menu, return: {
                memoizedProps: { surface: 'summary-panel', conversationId: threadID, registerCommands: true,
                  target: { hostId: 'local', root: path } }
              } } };
            }
            attachGit('other-git', 'other', '/tmp/other');
            attachGit('current-git', 'current', '/tmp/current');
            window.setWorkflowRunning = (id, running) => {
              const trigger = document.getElementById(id);
              trigger.__reactFiber$test.return.memoizedProps.children = { props: { children: [
                { props: { children: { props: { id: running
                  ? 'localConversation.gitActions.cancelWorkflow' : 'localConversation.gitActions.commit' } } } }
              ] } };
              trigger.replaceChildren(document.createElement(running ? 'span' : 'svg'));
            };
          </script>
        </body></html>
        """)
        let payload = try DashboardWebTestHarness.snapshotPayload(for: [
            .fixture(id: "current", checkoutPath: "/tmp/current", projectGitStatus: .uncommittedChangesAndUnpushedCommits),
        ])
        _ = try await webView.evaluateJavaScript("window.__codexDashboard.applyThreads((\(payload)).threads)")
        return webView
    }

    func testHeaderActionsUseSelectedRepositoryWithSummaryHiddenAndRepairAfterReplacement() async throws {
        let webView = try await fixture()
        let labels = try await webView.evaluateJavaScript("""
        [...document.querySelectorAll('#header-actions .dashboard-git-toolbar button')].map(button => button.textContent)
        """) as? [String]
        XCTAssertEqual(labels, ["Commit", "Commit & push", "Push"])
        _ = try await webView.evaluateJavaScript("document.querySelector('[data-git-action=Commit]').click()")
        try await DashboardWebTestHarness.waitForJavaScript("window.actions.length === 1", in: webView)
        let action = try await webView.evaluateJavaScript("window.actions[0]") as? [String]
        XCTAssertEqual(action, ["current", "/tmp/current", "Commit"])
        _ = try await webView.evaluateJavaScript("""
        (() => {
          const old = document.getElementById('header-actions');
          const next = document.createElement('div'); next.id = 'header-actions';
          next.setAttribute('data-app-shell-header-slot-content', 'end');
          next.innerHTML = '<div><button aria-label="Chat actions">…</button></div>';
          const slot = document.createElement('div');
          slot.setAttribute('data-app-shell-header-slot', 'end');
          slot.append(next);
          old.closest('[data-app-shell-header-toolbar]').replaceWith(slot);
        })()
        """)
        try await DashboardWebTestHarness.waitForJavaScript(
            "document.querySelectorAll('#header-actions .dashboard-git-toolbar').length === 1", in: webView)
        _ = try await webView.evaluateJavaScript("window.__codexDashboard.destroy()")
        try await Task.sleep(for: .milliseconds(80))
        let removed = try await webView.evaluateJavaScript("!document.querySelector('.dashboard-git-toolbar, [data-dashboard-git-menu]')") as? Bool
        XCTAssertEqual(removed, true)
    }

    func testDisabledPushNeverRunsAndMenuPlacementRestoresOnDestroy() async throws {
        let webView = try await fixture()
        try await DashboardWebTestHarness.waitForJavaScript("!document.querySelector('[data-git-action=Push]').disabled", in: webView)
        _ = try await webView.evaluateJavaScript("document.querySelector('[data-git-action=Push]').click()")
        try await DashboardWebTestHarness.waitForJavaScript("!!document.querySelector('[data-dashboard-git-menu]')", in: webView)
        try await Task.sleep(for: .milliseconds(100))
        let count = try await webView.evaluateJavaScript("window.actions.length") as? Int
        XCTAssertEqual(count, 0)
        _ = try await webView.evaluateJavaScript("window.__codexDashboard.destroy()")
        try await Task.sleep(for: .milliseconds(80))
        let restored = try await webView.evaluateJavaScript("!document.querySelector('.dashboard-git-toolbar, [data-dashboard-git-menu], #git-menu')") as? Bool
        XCTAssertEqual(restored, true)
    }

    func testCommitAndPushStartsCombinedWorkflowWithOneClick() async throws {
        let webView = try await fixture()
        _ = try await webView.evaluateJavaScript("""
        window.showCommitDialog = true;
        """)
        try await DashboardWebTestHarness.waitForJavaScript("!document.querySelector('[data-git-action=Push]').disabled", in: webView)
        _ = try await webView.evaluateJavaScript("""
        document.querySelector('[data-git-action="Commit & push"]').click();
        """)
        try await DashboardWebTestHarness.waitForJavaScript(
            "window.confirmed === true", in: webView)
        try await Task.sleep(for: .milliseconds(150))
        let started = try await webView.evaluateJavaScript("""
        [window.confirmed === true, window.actions.length === 1]
        """) as? [Bool]
        XCTAssertEqual(started, [true, true])
    }

    func testPushStaysDisabledDuringNativeWorkflowAndRecoversWithoutSnapshot() async throws {
        let webView = try await fixture()
        try await DashboardWebTestHarness.waitForJavaScript("!document.querySelector('[data-git-action=Push]').disabled", in: webView)
        // An operation in another mounted summary must not block this repository.
        _ = try await webView.evaluateJavaScript("window.setWorkflowRunning('other-git', true)")
        try await Task.sleep(for: .milliseconds(150))
        let available = try await webView.evaluateJavaScript("!document.querySelector('[data-git-action=Push]').disabled") as? Bool
        XCTAssertEqual(available, true)

        // Native pushes can start outside our toolbar, with the summary hidden.
        _ = try await webView.evaluateJavaScript("window.setWorkflowRunning('current-git', true)")
        try await DashboardWebTestHarness.waitForJavaScript("document.querySelector('[data-git-action=Push]').disabled", in: webView)
        let blocked = try await webView.evaluateJavaScript("""
        (() => {
          const buttons = [...document.querySelectorAll('.dashboard-git-toolbar button')];
          buttons.forEach(button => button.click());
          const push = buttons.find(button => button.dataset.gitAction === 'Push');
          return buttons.every(button => button.disabled)
            && Number(getComputedStyle(push).opacity) === 0.4
            && push.title.includes('Git operation') && window.actions.length === 0;
        })()
        """) as? Bool
        XCTAssertEqual(blocked, true)

        // Failure/cancellation may leave unpushed commits and no new snapshot.
        _ = try await webView.evaluateJavaScript("window.setWorkflowRunning('current-git', false)")
        try await DashboardWebTestHarness.waitForJavaScript("!document.querySelector('[data-git-action=Push]').disabled", in: webView)
        let restored = try await webView.evaluateJavaScript("document.querySelector('[data-git-action=Push]').title === 'Push'") as? Bool
        XCTAssertEqual(restored, true)
    }

    func testNoRemoteDisablesBothPushShortcutsAndNativeMenuPush() async throws {
        let webView = try await fixture(noRemote: true)
        try await DashboardWebTestHarness.waitForJavaScript(
            "document.querySelector('[data-git-action=Push]').title.includes('No Git remote')", in: webView)
        let disabled = try await webView.evaluateJavaScript("""
        [document.querySelector('[data-git-action=Push]').disabled,
          document.querySelector('[data-git-action="Commit & push"]').disabled,
          !document.querySelector('[data-git-action=Commit]').disabled]
        """) as? [Bool]
        XCTAssertEqual(disabled, [true, true, true])
        _ = try await webView.evaluateJavaScript("window.allowCommit = false; document.querySelector('[data-git-action=Commit]').click()")
        try await DashboardWebTestHarness.waitForJavaScript("!!document.querySelector('[data-dashboard-git-menu]')", in: webView)
        let blocked = try await webView.evaluateJavaScript("""
        (() => {
          const push = [...document.querySelectorAll('#git-menu [role=menuitem]')].find(item => item.textContent === 'Push');
          push.click();
          return push.getAttribute('aria-disabled') === 'true' && window.actions.length === 0;
        })()
        """) as? Bool
        XCTAssertEqual(blocked, true)
    }

    func testButtonsFollowRepositoryChangesAndUnpushedCommitsAcrossSnapshots() async throws {
        let webView = try await fixture()
        try await DashboardWebTestHarness.waitForJavaScript("!document.querySelector('[data-git-action=Push]').disabled", in: webView)
        let cases: [(ProjectGitStatus, [Bool])] = [
            (.clean, [true, true, true]),
            (.unavailable, [true, true, true]),
            (.uncommittedChanges, [false, false, true]),
            (.unpushedCommits, [true, true, false]),
            (.uncommittedChangesAndUnpushedCommits, [false, false, false]),
            (.clean, [true, true, true]),
        ]
        for (status, expected) in cases {
            let payload = try DashboardWebTestHarness.snapshotPayload(for: [
                .fixture(id: "current", checkoutPath: "/tmp/current", projectGitStatus: status),
            ])
            let actual = try await webView.evaluateJavaScript("""
            (() => {
              window.__codexDashboard.applyThreads((\(payload)).threads);
              return [...document.querySelectorAll('.dashboard-git-toolbar button')].map(button => button.disabled);
            })()
            """) as? [Bool]
            XCTAssertEqual(actual, expected, "Unexpected availability for \(status)")
        }
        _ = try await webView.evaluateJavaScript("""
        document.querySelector('[data-git-action=Commit]').click();
        document.querySelector('[data-git-action=Push]').click();
        document.querySelector('[data-git-action="Commit & push"]').click();
        """)
        let activations = try await webView.evaluateJavaScript("window.actions.length") as? Int
        XCTAssertEqual(activations, 0)
    }

    func testOverviewCommitUsesScopedNativeMenuWithSummaryHidden() async throws {
        let webView = try await fixture()
        _ = try await webView.evaluateJavaScript("""
        window.__codexDashboard.openChatOverview();
        document.querySelector('[data-filter="changedProjects"]').click();
        document.querySelector('[data-project-git-action]').click();
        """)
        try await DashboardWebTestHarness.waitForJavaScript("window.actions.length === 1", in: webView)
        let result = try await webView.evaluateJavaScript("""
        [window.actions[0][0] === 'current', window.actions[0][1] === '/tmp/current',
          window.actions[0][2] === 'Commit', !document.getElementById('git-menu'),
          !window.__codexDashboard.isOpen()]
        """) as? [Bool]
        XCTAssertEqual(result, [true, true, true, true, true])
    }

    func testOverviewFailedHandoffClosesItsNativeMenu() async throws {
        let webView = try await fixture()
        _ = try await webView.evaluateJavaScript("""
        window.allowCommit = false;
        window.__codexDashboard.openChatOverview();
        document.querySelector('[data-filter="changedProjects"]').click();
        document.querySelector('[data-project-git-action]').click();
        """)
        try await DashboardWebTestHarness.waitForJavaScript("!!document.getElementById('git-menu')", in: webView)
        try await DashboardWebTestHarness.waitForJavaScript(
            "window.__codexDashboard.isOpen() && !document.getElementById('git-menu')", in: webView, timeout: .seconds(7))
        let activations = try await webView.evaluateJavaScript("window.actions.length") as? Int
        XCTAssertEqual(activations, 0)
    }

    func testNavigationCancelsDelayedCommitInsteadOfActingOnAnotherChat() async throws {
        let webView = try await fixture()
        _ = try await webView.evaluateJavaScript("""
        window.delayMenu = 200;
        document.querySelector('[data-git-action=Commit]').click();
        window.selected = 'other';
        document.querySelector('textarea').setAttribute('aria-expanded', 'false');
        """)
        try await Task.sleep(for: .milliseconds(350))
        let count = try await webView.evaluateJavaScript("window.actions.length") as? Int
        XCTAssertEqual(count, 0)
    }
}
