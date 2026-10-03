import Foundation
import XCTest

@testable import CodexDashboard

@MainActor
extension ChatOverviewWebTests {
    func testMarkAllAsReadAppearsOnlyOnUnreadFilter() async throws {
        let webView = try await DashboardWebTestHarness.chatOverviewWebView()
        let payload = try DashboardWebTestHarness.snapshotPayload(for: [
            .fixture(id: "one", isUnread: true),
        ])
        let visibility = try await webView.evaluateJavaScript(
            """
            (() => {
              window.__codexDashboard.applyThreads((\(payload)).threads);
              window.__codexDashboard.openChatOverview();
              const button = document.querySelector('[data-mark-all-read]');
              document.querySelector('[data-filter="all"]').click();
              const onAll = button.hidden;
              document.querySelector('[data-filter="unread"]').click();
              const onUnread = button.hidden;
              document.querySelector('[data-filter="changedProjects"]').click();
              const onChangedProjects = button.hidden;
              return [onAll, onUnread, onChangedProjects];
            })()
            """
        ) as? [Bool]
        XCTAssertEqual(visibility, [true, false, true])
    }

    func testMarkAllAsReadReportsUnavailableHostActionWithoutOpeningTasks() async throws {
        let webView = try await DashboardWebTestHarness.chatOverviewWebView()
        let payload = try DashboardWebTestHarness.snapshotPayload(for: [
            .fixture(id: "one", isUnread: true),
        ])
        let result = try await webView.evaluateJavaScript(
            """
            (() => {
              window.__unexpectedNavigation = false;
              window.addEventListener('message', (event) => {
                if (event.data?.type === 'navigate-to-route') window.__unexpectedNavigation = true;
              });
              window.__codexDashboard.applyThreads((\(payload)).threads);
              window.__codexDashboard.openChatOverview();
              document.querySelector('[data-filter="unread"]').click();
              document.querySelector('[data-mark-all-read]').click();
              return [
                document.querySelector('[data-chat-overview-notice]').textContent,
                document.querySelector('[data-filter-count="unread"]').textContent,
                window.__unexpectedNavigation,
              ];
            })()
            """
        ) as? [Any]
        XCTAssertEqual(result?[0] as? String,
                       "Codex’s read-state action is unavailable. Restart Codex and try again.")
        XCTAssertEqual(result?[1] as? String, "1")
        XCTAssertEqual(result?[2] as? Bool, false)

        let updatedThread = try DashboardWebTestHarness.snapshotPayload(for: [
            .fixture(id: "one", isUnread: false),
        ])
        _ = try await webView.evaluateJavaScript(
            "window.__codexDashboard.applyThreads((\(updatedThread)).threads)"
        )
        try await DashboardWebTestHarness.waitForJavaScript(
            "document.querySelector('[data-filter-count=\"unread\"]').textContent === '0'",
            in: webView
        )
        let notice = try await webView.evaluateJavaScript(
            "document.querySelector('[data-chat-overview-notice]').textContent"
        ) as? String
        XCTAssertEqual(notice, "")
    }

    func testMarkAllAsReadAcknowledgesEveryUnreadThreadIncludingOffSidebar() async throws {
        let webView = try await DashboardWebTestHarness.chatOverviewWebView()
        let payload = try DashboardWebTestHarness.snapshotPayload(for: [
            .fixture(id: "one", isUnread: true),
            .fixture(id: "two", isUnread: true),
        ])

        let initial = try await webView.evaluateJavaScript(
            """
            (() => {
              const threads = (\(payload)).threads;
              window.__markedReadIDs = [];
              const readIDs = new Set();
              const row = document.createElement('button');
              row.setAttribute('data-app-action-sidebar-thread-id', 'local:one');
              row.__reactFiber$test = {
                updateQueue: { memoCache: { data: [[{
                  markThreadAsRead: ({ conversationId }) => {
                    window.__markedReadIDs.push(conversationId);
                    readIDs.add(conversationId);
                    window.__codexDashboard.applyThreads(threads.map((thread) =>
                      readIDs.has(thread.id) ? { ...thread, isUnread: false } : thread));
                  },
                  markThreadAsUnread: () => {},
                }]] } },
                return: null,
              };
              document.querySelector('aside').append(row);
              window.addEventListener('message', (event) => {
                if (event.data?.type === 'navigate-to-route') window.__unexpectedNavigation = true;
              });
              window.__codexDashboard.applyThreads(threads);
              window.__codexDashboard.openChatOverview();
              document.querySelector('[data-filter="unread"]').click();
              const button = document.querySelector('[data-mark-all-read]');
              return [button.textContent, button.hidden, button.disabled];
            })()
            """
        ) as? [Any]
        XCTAssertEqual(initial?[0] as? String, "Mark all as read")
        XCTAssertEqual(initial?[1] as? Bool, false)
        XCTAssertEqual(initial?[2] as? Bool, false)

        _ = try await webView.evaluateJavaScript("document.querySelector('[data-mark-all-read]').click()")
        try await DashboardWebTestHarness.waitForJavaScript(
            "document.querySelector('[data-filter-count=\"unread\"]').textContent === '0' && document.querySelector('[data-mark-all-read]').hidden",
            in: webView
        )
        let result = try await webView.evaluateJavaScript(
            """
            [window.__markedReadIDs.join(','),
             Boolean(window.__unexpectedNavigation),
             document.querySelector('[data-navigation-count]').hidden,
             document.getElementById('codex-dashboard-chat-overview-page').classList.contains('is-open')]
            """
        ) as? [Any]
        XCTAssertEqual(result?[0] as? String, "one,two")
        XCTAssertEqual(result?[1] as? Bool, false)
        XCTAssertEqual(result?[2] as? Bool, true)
        XCTAssertEqual(result?[3] as? Bool, true)
    }

    func testMarkAllAsReadAcceptsLiveReadStateWhileSnapshotLags() async throws {
        let webView = try await DashboardWebTestHarness.chatOverviewWebView()
        let payload = try DashboardWebTestHarness.snapshotPayload(for: [
            .fixture(id: "one", isUnread: true),
        ])
        _ = try await webView.evaluateJavaScript(
            """
            (() => {
              const thread = (\(payload)).threads[0];
              const row = document.createElement('button');
              row.setAttribute('data-app-action-sidebar-thread-id', 'local:one');
              const readState = { conversationId: 'one', isUnread: true };
              row.__reactFiber$test = {
                memoizedProps: readState,
                updateQueue: { memoCache: { data: [[{
                  markThreadAsRead: () => {
                    readState.isUnread = false;
                    // The native snapshot has not refreshed yet.
                    window.__codexDashboard.applyThreads([thread]);
                  },
                  markThreadAsUnread: () => {},
                }]] } },
                return: null,
              };
              document.querySelector('aside').append(row);
              window.__codexDashboard.applyThreads([thread]);
              window.__codexDashboard.openChatOverview();
              document.querySelector('[data-filter="unread"]').click();
              document.querySelector('[data-mark-all-read]').click();
            })()
            """
        )

        try await DashboardWebTestHarness.waitForJavaScript(
            "document.querySelector('[data-filter-count=\"unread\"]').textContent === '0' && document.querySelector('[data-mark-all-read]').hidden",
            in: webView
        )
        let notice = try await webView.evaluateJavaScript(
            "document.querySelector('[data-chat-overview-notice]').textContent"
        ) as? String
        XCTAssertEqual(notice, "")
    }

    func testMarkAllAsReadClearsStaleSidebarUnreadWhenSavedStateIsRead() async throws {
        let webView = try await DashboardWebTestHarness.chatOverviewWebView()
        let payload = try DashboardWebTestHarness.snapshotPayload(for: [
            .fixture(id: "one", isUnread: false),
        ])
        _ = try await webView.evaluateJavaScript(
            """
            (() => {
              const row = document.createElement('button');
              row.setAttribute('data-app-action-sidebar-thread-id', 'local:one');
              row.__reactFiber$test = {
                memoizedProps: { conversationId: 'one', isUnread: true },
                updateQueue: { memoCache: { data: [[{
                  markThreadAsRead: () => {},
                  markThreadAsUnread: () => {},
                }]] } },
                return: null,
              };
              document.querySelector('aside').append(row);
              window.__codexDashboard.applyThreads((\(payload)).threads);
              window.__codexDashboard.openChatOverview();
              document.querySelector('[data-filter="unread"]').click();
              document.querySelector('[data-mark-all-read]').click();
            })()
            """
        )
        try await DashboardWebTestHarness.waitForJavaScript(
            "document.querySelector('[data-filter-count=\"unread\"]').textContent === '0' && document.querySelector('[data-mark-all-read]').hidden",
            in: webView
        )
        let notice = try await webView.evaluateJavaScript(
            "document.querySelector('[data-chat-overview-notice]').textContent"
        ) as? String
        XCTAssertEqual(notice, "")
    }

    func testStaleSidebarUnreadObservationExpiresWithoutNewSnapshot() async throws {
        let webView = try await DashboardWebTestHarness.chatOverviewWebView()
        let payload = try DashboardWebTestHarness.snapshotPayload(for: [
            .fixture(id: "one", isUnread: false),
        ])
        let counts = try await webView.evaluateJavaScript(
            """
            (() => {
              const row = document.createElement('button');
              row.setAttribute('data-app-action-sidebar-thread-id', 'local:one');
              row.__reactFiber$test = {
                memoizedProps: { conversationId: 'one', isUnread: true }, return: null,
              };
              document.querySelector('aside').append(row);
              window.__codexDashboard.applyThreads((\(payload)).threads);
              window.__codexDashboard.openChatOverview();
              const before = document.querySelector('[data-filter-count="unread"]').textContent;
              const realNow = Date.now;
              Date.now = () => realNow() + 10_001;
              window.__codexDashboard.openChatOverview();
              Date.now = realNow;
              return [before, document.querySelector('[data-filter-count="unread"]').textContent];
            })()
            """
        ) as? [String]
        XCTAssertEqual(counts, ["1", "0"])
    }

    func testCanonicalUnreadStateIncludesThreadMissingFromSidebar() async throws {
        let webView = try await DashboardWebTestHarness.mountedWebView(html:
            """
            <!doctype html><html><head><meta charset="utf-8"></head><body>
              <aside role="navigation"><button class="sidebar-item">New chat</button></aside>
              <main>Conversation surface</main>
            </body></html>
            """,
        )
        let thread = ThreadSummary.fixture(
            id: "off-sidebar-unread",
            title: "Off-sidebar unread",
            preview: "Not mounted in the sidebar",
            isUnread: true
        )
        let payload = try DashboardWebTestHarness.snapshotPayload(for: [thread])

        let result = try await webView.evaluateJavaScript(
            """
            (() => {
              window.__codexDashboard.applyThreads((\(payload)).threads);
              window.__codexDashboard.openChatOverview();
              document.querySelector('[data-filter="unread"]').click();
              return [
                document.querySelector('[data-filter-count="unread"]').textContent,
                document.querySelector('[data-thread-list] .dashboard-thread')?.dataset.threadId,
              ];
            })()
            """
        ) as? [String]

        XCTAssertEqual(result, ["1", "off-sidebar-unread"])
    }

    func testUnreadThreadAccessibleNameIncludesUnreadState() async throws {
        let webView = try await DashboardWebTestHarness.mountedWebView(html:
            """
            <!doctype html><html><head><meta charset="utf-8"></head><body>
              <aside role="navigation"><button class="sidebar-item">New chat</button></aside>
              <main>Conversation surface</main>
            </body></html>
            """
        )
        let payload = try DashboardWebTestHarness.snapshotPayload(for: [
            .fixture(id: "unread-thread", title: "Needs review", isUnread: true),
        ])

        let accessibleName = try await webView.evaluateJavaScript(
            """
            (() => {
              window.__codexDashboard.applyThreads((\(payload)).threads);
              window.__codexDashboard.openChatOverview();
              document.querySelector('[data-filter="unread"]').click();
              return document.querySelector('[data-thread-id="unread-thread"]').getAttribute('aria-label');
            })()
            """
        ) as? String

        XCTAssertEqual(accessibleName, "Unread. Open chat: Needs review")
    }

    func testUnreadFallbackDetectsSilentReactStateChange() async throws {
        let webView = try await DashboardWebTestHarness.mountedWebView(html:
            """
            <!doctype html><html><head><meta charset="utf-8"></head><body>
              <aside role="navigation">
                <button class="sidebar-item">New chat</button>
                <button class="sidebar-item" data-app-action-sidebar-thread-id="local:thread-one">Thread</button>
              </aside>
              <main>Conversation surface</main>
              <script>
                Object.defineProperty(document, 'visibilityState', {
                  configurable: true,
                  value: 'visible',
                });
              </script>
            </body></html>
            """,
        )
        let thread = ThreadSummary.fixture(id: "thread-one")
        let payload = try DashboardWebTestHarness.snapshotPayload(for: [thread])
        _ = try await webView.evaluateJavaScript(
            """
            (() => {
              const row = document.querySelector('[data-app-action-sidebar-thread-id]');
              row.__reactFiber$test = {
                memoizedProps: { conversationId: 'thread-one', isUnread: true },
                return: null,
              };
              window.__codexDashboard.applyThreads((\(payload)).threads);
              row.__reactFiber$test.memoizedProps = {
                conversationId: 'thread-one',
                isUnread: false,
              };
            })()
            """
        )

        try await Task.sleep(for: .milliseconds(1_700))
        let unreadCount = try await webView.evaluateJavaScript(
            #"document.querySelector('[data-filter-count="unread"]').textContent"#
        ) as? String

        XCTAssertEqual(unreadCount, "0")
    }

    func testUnreadUsesCommittedReactTreeAcrossAlternatingAndSharedCommits() async throws {
        let webView = try await DashboardWebTestHarness.mountedWebView(html:
            """
            <!doctype html><html><head></head><body>
              <aside role="navigation">
                <button class="sidebar-item">New chat</button>
                <button data-app-action-sidebar-thread-id="local:one">Thread</button>
              </aside><main>Conversation</main>
            </body></html>
            """
        )
        let payload = try DashboardWebTestHarness.snapshotPayload(for: [.fixture(id: "one", isUnread: true)])
        let counts = try await webView.evaluateJavaScript(
            """
            (() => {
              const row = document.querySelector('[data-app-action-sidebar-thread-id]');
              const rootA = {}, rootB = {};
              const state = { current: rootB };
              rootA.stateNode = rootB.stateNode = state;
              rootA.alternate = rootB; rootB.alternate = rootA;
              const parentA = { memoizedProps: { conversationId: 'one', isUnread: true }, return: rootA };
              const parentB = { memoizedProps: { conversationId: 'one', isUnread: false }, return: rootB };
              parentA.alternate = parentB; parentB.alternate = parentA;
              rootA.child = parentA; rootB.child = parentB;
              const hostA = { memoizedProps: {}, return: parentA };
              const hostB = { memoizedProps: {}, return: parentB };
              hostA.alternate = hostB; hostB.alternate = hostA;
              parentA.child = hostA; parentB.child = hostB;
              row.__reactFiber$test = hostA;
              const sample = () => {
                window.__codexDashboard.applyThreads((\(payload)).threads);
                window.__codexDashboard.openChatOverview();
                document.querySelector('[data-filter="unread"]').click();
                return document.querySelector('[data-filter-count="unread"]').textContent;
              };
              const results = [sample()];
              state.current = rootA;
              results.push(sample());
              // A bailout can reuse a child whose return still points at the old parent.
              state.current = rootB;
              parentB.child = hostA;
              results.push(sample());
              // A detached fiber must not override persisted state.
              rootB.child = null;
              results.push(sample());
              return results;
            })()
            """
        ) as? [String]
        // The detached row retains the last observed read state until acknowledgement.
        XCTAssertEqual(counts, ["0", "1", "0", "0"])
    }

    func testLiveUnreadOverridesSurviveUnmountAndReleaseOnAcknowledgementOrNewActivity() async throws {
        let webView = try await DashboardWebTestHarness.mountedWebView(html:
            """
            <!doctype html><html><head></head><body>
              <aside role="navigation"><button class="sidebar-item">New chat</button></aside>
              <main>Conversation</main>
            </body></html>
            """
        )
        let payload = try DashboardWebTestHarness.snapshotPayload(for: [.fixture(id: "one", isUnread: true)])
        let counts = try await webView.evaluateJavaScript(
            """
            (() => {
              const thread = (\(payload)).threads[0];
              const sample = (value) => {
                window.__codexDashboard.applyThreads(value ? [value] : []);
                window.__codexDashboard.openChatOverview();
                document.querySelector('[data-filter="unread"]').click();
                return document.querySelector('[data-filter-count="unread"]').textContent;
              };
              const observe = (isUnread) => {
                const row = document.createElement('button');
                row.setAttribute('data-app-action-sidebar-thread-id', 'local:one');
                row.__reactFiber$test = { memoizedProps: { conversationId: 'one', isUnread }, return: null };
                document.querySelector('aside').append(row);
                return row;
              };
              let row = observe(false);
              const results = [sample(thread)];
              row.remove();
              results.push(sample(thread));
              results.push(sample({ ...thread, isUnread: false }));
              results.push(sample(thread)); // Acknowledgement released the override.
              row = observe(false);
              results.push(sample(thread));
              row.remove();
              results.push(sample({ ...thread, recencyEpochMillis: thread.recencyEpochMillis + 1 }));
              row = observe(true);
              const readThread = { ...thread, isUnread: false };
              results.push(sample(readThread));
              row.remove();
              results.push(sample(readThread)); // Preserve a live unread observation too.
              results.push(sample(thread));
              results.push(sample(readThread));
              row = observe(false);
              sample(thread);
              row.remove();
              sample(null); // Removing a task clears its override.
              results.push(sample(thread));
              return results;
            })()
            """
        ) as? [String]
        XCTAssertEqual(counts, ["0", "0", "0", "1", "0", "1", "1", "1", "1", "0", "1"])
    }

    func testUnchangedSidebarCannotOverrideNewerPersistedUnreadTransitions() async throws {
        let webView = try await DashboardWebTestHarness.mountedWebView(html:
            """
            <!doctype html><html><head></head><body>
              <aside role="navigation"><button class="sidebar-item">New chat</button>
                <button data-app-action-sidebar-thread-id="local:one">Thread</button>
              </aside><main>Conversation</main>
            </body></html>
            """
        )
        let payload = try DashboardWebTestHarness.snapshotPayload(for: [.fixture(id: "one")])
        let counts = try await webView.evaluateJavaScript(
            """
            (() => {
              const row = document.querySelector('[data-app-action-sidebar-thread-id]');
              row.__reactFiber$test = { memoizedProps: { conversationId: 'one', isUnread: false }, return: null };
              const thread = (\(payload)).threads[0];
              const sample = (value) => {
                window.__codexDashboard.applyThreads([value]);
                window.__codexDashboard.openChatOverview();
                return document.querySelector('[data-filter-count="unread"]').textContent;
              };
              const results = [sample(thread)];
              const newTurn = { ...thread, isUnread: true, recencyEpochMillis: thread.recencyEpochMillis + 1 };
              results.push(sample(newTurn)); // Sidebar still shows the previous turn's read state.
              results.push(sample(newTurn)); // Repeated polls cannot renew that stale observation.
              row.__reactFiber$test.memoizedProps.isUnread = true;
              results.push(sample(newTurn));
              results.push(sample({ ...newTurn, isUnread: false })); // Read in another window, sidebar lags.
              row.__reactFiber$test.memoizedProps.isUnread = false;
              results.push(sample({ ...newTurn, isUnread: false }));
              row.__reactFiber$test.memoizedProps.isUnread = true; // A genuinely new live transition wins.
              results.push(sample({ ...newTurn, isUnread: false }));
              return results;
            })()
            """
        ) as? [String]
        XCTAssertEqual(counts, ["0", "1", "1", "1", "0", "0", "1"])
    }

    func testOpeningDashboardImmediatelyReconcilesSilentSidebarReadChange() async throws {
        let webView = try await DashboardWebTestHarness.mountedWebView(html:
            """
            <!doctype html><html><head></head><body>
              <aside role="navigation"><button class="sidebar-item">New chat</button>
                <button data-app-action-sidebar-thread-id="local:one">Thread</button>
              </aside><main>Conversation</main>
            </body></html>
            """
        )
        let payload = try DashboardWebTestHarness.snapshotPayload(for: [.fixture(id: "one", isUnread: true)])
        let count = try await webView.evaluateJavaScript(
            """
            (() => {
              const row = document.querySelector('[data-app-action-sidebar-thread-id]');
              row.__reactFiber$test = { memoizedProps: { conversationId: 'one', isUnread: true }, return: null };
              window.__codexDashboard.applyThreads((\(payload)).threads);
              window.__codexDashboard.openChatOverview();
              row.click();
              row.__reactFiber$test.memoizedProps.isUnread = false;
              window.__codexDashboard.openChatOverview();
              return document.querySelector('[data-filter-count="unread"]').textContent;
            })()
            """
        ) as? String
        XCTAssertEqual(count, "0")
    }

    func testRemoteSidebarRowCannotOverrideLocalUnreadState() async throws {
        let webView = try await DashboardWebTestHarness.mountedWebView(html:
            """
            <!doctype html><html><head></head><body>
              <aside role="navigation"><button class="sidebar-item">New chat</button>
                <button data-app-action-sidebar-thread-id="remote:one">Remote thread</button>
              </aside><main>Conversation</main>
            </body></html>
            """
        )
        let payload = try DashboardWebTestHarness.snapshotPayload(for: [.fixture(id: "one", isUnread: true)])
        let count = try await webView.evaluateJavaScript(
            """
            (() => {
              const row = document.querySelector('[data-app-action-sidebar-thread-id]');
              row.__reactFiber$test = { memoizedProps: { conversationId: 'one', isUnread: false }, return: null };
              window.__codexDashboard.applyThreads((\(payload)).threads);
              window.__codexDashboard.openChatOverview();
              return document.querySelector('[data-filter-count="unread"]').textContent;
            })()
            """
        ) as? String
        XCTAssertEqual(count, "1")
    }

}
