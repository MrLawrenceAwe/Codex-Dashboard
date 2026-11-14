import WebKit
import XCTest

@testable import CodexDashboard

@MainActor
final class GitToolbarWebTests: SerializedDashboardWebTestCase {
    func testFileChangesBlockActionsAcrossInterruptionUntilSuccessfulCompletion() async throws {
        let webView = try await fixture()
        try await DashboardWebTestHarness.waitForJavaScript("!document.querySelector('[data-git-action=Push]').disabled", in: webView)
        let states: [(ThreadRunState, Bool)] = [(.running, false), (.running, true), (.idle, true), (.running, true), (.idle, false)]
        for (runState, blocked) in states {
            let payload = try DashboardWebTestHarness.snapshotPayload(for: [
                .fixture(id: "current", checkoutPath: "/tmp/current", runState: runState,
                         projectGitStatus: .uncommittedChangesAndUnpushedCommits,
                         gitActionsBlockedUntilCompletion: blocked),
            ])
            _ = try await webView.evaluateJavaScript("window.__codexDashboard.applyThreads((\(payload)).threads)")
            let matchesState = try await webView.evaluateJavaScript("""
            [...document.querySelectorAll('.dashboard-git-toolbar button')].every(button =>
              button.disabled === \(blocked)
                && Number(getComputedStyle(button).opacity) === \(blocked ? "0.4" : "1")
                && (\(blocked) ? button.title.includes('finish without interruption') : button.title === button.dataset.gitAction))
            """) as? Bool
            XCTAssertEqual(matchesState, true)
            if blocked {
                _ = try await webView.evaluateJavaScript("document.querySelectorAll('.dashboard-git-toolbar button').forEach(button => button.click())")
                let actionCount = try await webView.evaluateJavaScript("window.actions.length") as? Int
                XCTAssertEqual(actionCount, 0)
            }
        }
        _ = try await webView.evaluateJavaScript("window.showCommitDialog = true; document.querySelector('[data-git-action=Commit]').click()")
        try await DashboardWebTestHarness.waitForJavaScript("window.confirmedAction === 'commit'", in: webView)
        let actionCount = try await webView.evaluateJavaScript("window.actions.length") as? Int
        XCTAssertEqual(actionCount, 1)
    }

    private func fixture(noRemote: Bool = false, deferredGit: Bool = false) async throws -> WKWebView {
        let webView = try await DashboardWebTestHarness.mountedWebView(html: """
        <!doctype html><html><body>
          <aside><nav><div class="sidebar-item"><button>New chat</button></div></nav></aside>
          <main>
            <div data-app-shell-header-toolbar><div>Chat title</div><div id="header-actions">
              <div data-app-shell-focus-area="main"><button aria-label="Toggle summary">…</button></div>
            </div></div>
            <div id="composer"><textarea></textarea></div>
            <div hidden><button id="other-git" aria-label="Git actions"></button></div>
            <div hidden><button id="current-git" aria-label="Git actions" aria-controls="git-menu"></button></div>
            <div hidden data-summary-panel-variant="summary"><button id="checkout-actions" aria-label="Actions"></button></div>
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
                if (worker === 'git' && message.request?.method === 'status-summary') {
                  setTimeout(() => remoteListener({
                    type: 'worker-response', workerId: 'git', response: {
                      id: message.request.id, method: 'status-summary',
                      result: { type: 'ok', value: { type: 'success',
                        stagedCount: 0, unstagedCount: window.uncommittedCount ?? 1, untrackedCount: 0 } }
                    }
                  }), 10);
                  return Promise.resolve();
                }
                if (worker === 'git' && message.request?.method === 'branch-ahead-count') {
                  window.aheadChecks = (window.aheadChecks || 0) + 1;
                  setTimeout(() => remoteListener({
                    type: 'worker-response', workerId: 'git', response: {
                      id: message.request.id, method: 'branch-ahead-count',
                      result: { type: 'ok', value: { commitsAhead: window.commitsAhead ?? 0 } }
                    }
                  }), 10);
                  return Promise.resolve();
                }
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
                      item.setAttribute('aria-disabled', String((action === 'Push' && !window.allowPush)
                        || (action === 'Commit' && !window.allowCommit)));
                      item.addEventListener('click', () => {
                        window.menuOpacityAtSelection = getComputedStyle(wrapper).opacity;
                        window.actions.push([threadID, path, action]);
                        if (['Commit', 'Push'].includes(action) && window.showCommitDialog) {
                          const dialog = document.createElement('div'); dialog.setAttribute('role', 'dialog');
                          const root = document.createElement('div'); root.setAttribute('cmdk-root', '');
                          root.setAttribute('data-codex-shortcut-capture', ''); root.tabIndex = -1;
                          for (const value of ['commit', 'commit-and-push', 'push']) {
                            const option = document.createElement('div');
                            option.setAttribute('cmdk-item', ''); option.setAttribute('role', 'option');
                            option.setAttribute('data-value', value); option.setAttribute('aria-selected', String(value === 'commit'));
                            option.setAttribute('aria-disabled', String(value === 'commit' && window.disableCommitConfirmation === true));
                            option.setAttribute('data-disabled', 'false');
                            option.addEventListener('click', () => {
                              window.dialogOpacityAtSelection = getComputedStyle(dialog).opacity;
                              window.confirmed = true; window.confirmedAction = value; dialog.remove();
                            });
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
            if (\(deferredGit)) {
              const git = document.getElementById('current-git');
              const oldMenu = git.__reactFiber$test.return;
              const scope = oldMenu.return;
              scope.memoizedProps.deferQueries = true;
              const effect = {
                deps: [null, true, () => oldMenu.memoizedProps.onOpenChange(true), 'git.commit'],
                inst: { destroy() {} }
              };
              effect.next = effect;
              const summary = {
                memoizedProps: { surface: 'summary-panel', deferGitQueries: true, registerCommands: true },
                child: { memoizedProps: { deferQueries: true }, child: { updateQueue: { lastEffect: effect } } },
                return: scope
              };
              document.getElementById('checkout-actions').__reactFiber$test = { return: summary };
              git.remove();
              const observer = new MutationObserver(() => {
                // Reuse the native commit-dialog fixture without exposing a Git menu trigger.
                const item = document.querySelector('#git-menu [role=menuitem]');
                if (!item) return;
                item.click();
                oldMenu.memoizedProps.onOpenChange(false);
              });
              observer.observe(document.body, { childList: true, subtree: true });
            }
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

    func testDeferredNativeGitCommandUsesTheMatchingDialogForAllThreeShortcuts() async throws {
        let webView = try await fixture(deferredGit: true)
        _ = try await webView.evaluateJavaScript("window.showCommitDialog = true; window.commitsAhead = 1")
        for (action, command) in [("Commit", "commit"), ("Commit & push", "commit-and-push"), ("Push", "push")] {
            let button = #"document.querySelector('[data-git-action="\#(action)"]')"#
            try await DashboardWebTestHarness.waitForJavaScript("\(button)?.disabled === false", in: webView)
            _ = try await webView.evaluateJavaScript("\(button).click()")
            try await DashboardWebTestHarness.waitForJavaScript(
                "window.confirmedAction === '\(command)' && !document.body.hasAttribute('data-dashboard-git-handoff')",
                in: webView)
        }
    }

    func testPushCompletesWhenNativeMenuOpensItsDialog() async throws {
        let webView = try await fixture()
        _ = try await webView.evaluateJavaScript("window.allowPush = true; window.showCommitDialog = true")
        try await DashboardWebTestHarness.waitForJavaScript("!document.querySelector('[data-git-action=Push]').disabled", in: webView)
        _ = try await webView.evaluateJavaScript("document.querySelector('[data-git-action=Push]').click()")
        try await DashboardWebTestHarness.waitForJavaScript(
            "window.confirmedAction === 'push' && !document.body.hasAttribute('data-dashboard-git-handoff')",
            in: webView)
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
          next.innerHTML = '<div><button aria-label="Toggle summary">…</button></div>';
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

    func testCommitStartsNativeWorkflowWithoutShowingEitherMenu() async throws {
        for noRemote in [false, true] {
            let webView = try await fixture(noRemote: noRemote)
            _ = try await webView.evaluateJavaScript("""
            window.showCommitDialog = true;
            document.querySelector('[data-git-action=Commit]').click();
            """)
            try await DashboardWebTestHarness.waitForJavaScript(
                "window.confirmedAction === 'commit' && !document.body.hasAttribute('data-dashboard-git-handoff')", in: webView)
            let result = try await webView.evaluateJavaScript("""
            [window.actions.length === 1, window.menuOpacityAtSelection === '0',
              window.dialogOpacityAtSelection === '0', !document.querySelector('#git-menu, [role=dialog]')]
            """) as? [Bool]
            XCTAssertEqual(result, [true, true, true, true])
        }
    }

    func testDisabledCommitConfirmationIsNotActivatedAndNavigationCancelsHandoff() async throws {
        let webView = try await fixture()
        _ = try await webView.evaluateJavaScript("""
        window.showCommitDialog = true;
        window.disableCommitConfirmation = true;
        document.querySelector('[data-git-action=Commit]').click();
        """)
        try await DashboardWebTestHarness.waitForJavaScript("!!document.querySelector('[role=dialog]')", in: webView)
        try await Task.sleep(for: .milliseconds(150))
        let blocked = try await webView.evaluateJavaScript("window.confirmed !== true") as? Bool
        XCTAssertEqual(blocked, true)
        _ = try await webView.evaluateJavaScript("""
        window.selected = 'other';
        document.querySelector('[cmdk-item][data-value=commit]').setAttribute('aria-disabled', 'false');
        """)
        try await DashboardWebTestHarness.waitForJavaScript(
            "!document.body.hasAttribute('data-dashboard-git-handoff')", in: webView)
        let cancelled = try await webView.evaluateJavaScript("window.confirmed !== true") as? Bool
        XCTAssertEqual(cancelled, true)
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
        [window.confirmedAction === 'commit-and-push', window.actions.length === 1,
          window.menuOpacityAtSelection === '0', window.dialogOpacityAtSelection === '0',
          !document.body.hasAttribute('data-dashboard-git-handoff')]
        """) as? [Bool]
        XCTAssertEqual(started, [true, true, true, true, true])
    }

    func testCommitOnlyEnablesPushDespiteStaleNativeNothingToPushHint() async throws {
        let webView = try await fixture()
        let dirtyPayload = try DashboardWebTestHarness.snapshotPayload(for: [
            .fixture(id: "current", checkoutPath: "/tmp/current", projectGitStatus: .uncommittedChanges),
        ])
        _ = try await webView.evaluateJavaScript("""
        window.__codexDashboard.applyThreads((\(dirtyPayload)).threads);
        window.showCommitDialog = true;
        document.querySelector('[data-git-action=Commit]').click();
        """)
        try await DashboardWebTestHarness.waitForJavaScript(
            "window.confirmedAction === 'commit' && !document.body.hasAttribute('data-dashboard-git-handoff')", in: webView)
        // The hidden native menu may retain its pre-commit no-commits hint.
        _ = try await webView.evaluateJavaScript("""
        (() => {
          const trigger = document.getElementById('current-git');
          trigger.__reactFiber$test.return.memoizedProps.children = { props: { children: [
            { props: { children: { props: { id: 'localConversation.gitActions.commit' } } } },
            { props: { onSelect() {}, disabled: true,
              tooltipText: { props: { reason: 'nothing-to-push' } },
              children: { props: { id: 'localConversation.gitActions.push' } } } }
          ] } };
          trigger.replaceChildren(document.createElement('svg'));
        })()
        """)
        let committedPayload = try DashboardWebTestHarness.snapshotPayload(for: [
            .fixture(id: "current", checkoutPath: "/tmp/current", projectGitStatus: .unpushedCommits),
        ])
        _ = try await webView.evaluateJavaScript("window.__codexDashboard.applyThreads((\(committedPayload)).threads)")
        let state = try await webView.evaluateJavaScript("""
        [...document.querySelectorAll('.dashboard-git-toolbar button')].map(button => button.disabled)
        """) as? [Bool]
        XCTAssertEqual(state, [true, true, false])
        // A later clean snapshot, after a push, disables Push again.
        let cleanPayload = try DashboardWebTestHarness.snapshotPayload(for: [
            .fixture(id: "current", checkoutPath: "/tmp/current", projectGitStatus: .clean),
        ])
        _ = try await webView.evaluateJavaScript("window.__codexDashboard.applyThreads((\(cleanPayload)).threads)")
        let reason = try await webView.evaluateJavaScript("document.querySelector('[data-git-action=Push]').title") as? String
        XCTAssertEqual(reason, "No unpushed commits.")
    }

    func testCombinedWorkflowKeepsPushDisabledUntilGitConfirmsCommitsRemain() async throws {
        let webView = try await fixture()
        let dirty = try DashboardWebTestHarness.snapshotPayload(for: [
            .fixture(id: "current", checkoutPath: "/tmp/current", projectGitStatus: .uncommittedChanges),
        ])
        let ahead = try DashboardWebTestHarness.snapshotPayload(for: [
            .fixture(id: "current", checkoutPath: "/tmp/current", projectGitStatus: .unpushedCommits),
        ])
        let clean = try DashboardWebTestHarness.snapshotPayload(for: [
            .fixture(id: "current", checkoutPath: "/tmp/current", projectGitStatus: .clean),
        ])
        try await DashboardWebTestHarness.waitForJavaScript("!document.querySelector('[data-git-action=Push]').disabled", in: webView)
        _ = try await webView.evaluateJavaScript("""
        window.showCommitDialog = true;
        window.__codexDashboard.applyThreads((\(dirty)).threads);
        const push = document.querySelector('[data-git-action=Push]');
        window.pushEnabled = false;
        new MutationObserver(() => { if (!push.disabled) window.pushEnabled = true; })
          .observe(push, { attributes: true, attributeFilter: ['disabled'] });
        document.querySelector('[data-git-action="Commit & push"]').click();
        """)
        try await DashboardWebTestHarness.waitForJavaScript(
            "window.confirmedAction === 'commit-and-push' && !document.body.hasAttribute('data-dashboard-git-handoff')", in: webView)
        _ = try await webView.evaluateJavaScript("window.__codexDashboard.applyThreads((\(ahead)).threads)")
        try await DashboardWebTestHarness.waitForJavaScript("window.aheadChecks >= 2", in: webView)
        _ = try await webView.evaluateJavaScript("window.__codexDashboard.applyThreads((\(clean)).threads)")
        let flashed = try await webView.evaluateJavaScript("window.pushEnabled") as? Bool
        XCTAssertEqual(flashed, false)

        // A later combined operation can leave an unpushed commit after failure.
        _ = try await webView.evaluateJavaScript("""
        window.confirmedAction = null;
        window.commitsAhead = 1;
        window.__codexDashboard.applyThreads((\(dirty)).threads);
        document.querySelector('[data-git-action="Commit & push"]').click();
        """)
        try await DashboardWebTestHarness.waitForJavaScript(
            "window.confirmedAction === 'commit-and-push' && !document.body.hasAttribute('data-dashboard-git-handoff')", in: webView)
        _ = try await webView.evaluateJavaScript("window.__codexDashboard.applyThreads((\(ahead)).threads)")
        try await DashboardWebTestHarness.waitForJavaScript("!document.querySelector('[data-git-action=Push]').disabled", in: webView)
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

    func testWorkflowUsesMountedReactTreeInsteadOfStaleFiber() async throws {
        let webView = try await fixture()
        try await DashboardWebTestHarness.waitForJavaScript("!document.querySelector('[data-git-action=Push]').disabled", in: webView)
        _ = try await webView.evaluateJavaScript("""
        (() => {
          const trigger = document.getElementById('current-git');
          const old = trigger.__reactFiber$test;
          const menu = old.return;
          const scope = menu.return;
          const root = { stateNode: {} };
          scope.return = root;
          const nextRoot = { stateNode: root.stateNode };
          const nextScope = { memoizedProps: scope.memoizedProps, return: nextRoot };
          const nextMenu = { memoizedProps: { ...menu.memoizedProps, children: {
            props: { children: { props: { id: 'localConversation.gitActions.cancelWorkflow' } } }
          } }, return: nextScope };
          const next = { memoizedProps: old.memoizedProps, return: nextMenu };
          for (const [a, b] of [[old, next], [menu, nextMenu], [scope, nextScope], [root, nextRoot]]) {
            a.alternate = b; b.alternate = a;
          }
          root.child = scope; scope.child = menu; menu.child = old;
          nextRoot.child = nextScope; nextScope.child = nextMenu; nextMenu.child = next;
          root.stateNode.current = nextRoot;
          window.finishWorkflow = () => {
            root.stateNode.current = root;
            trigger.replaceChildren(document.createElement('svg'));
          };
          trigger.replaceChildren(document.createElement('span'));
        })()
        """)
        try await DashboardWebTestHarness.waitForJavaScript(
            "document.querySelector('[data-git-action=Push]').title.includes('Git operation')", in: webView)
        _ = try await webView.evaluateJavaScript("window.finishWorkflow()")
        try await DashboardWebTestHarness.waitForJavaScript("!document.querySelector('[data-git-action=Push]').disabled", in: webView)
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
