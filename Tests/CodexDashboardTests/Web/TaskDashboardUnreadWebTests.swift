import Foundation
import XCTest

@testable import CodexDashboard

@MainActor
extension TaskDashboardWebTests {
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
              window.__codexDashboard.open();
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
              window.__codexDashboard.open();
              document.querySelector('[data-filter="unread"]').click();
              return document.querySelector('[data-thread-id="unread-thread"]').getAttribute('aria-label');
            })()
            """
        ) as? String

        XCTAssertEqual(accessibleName, "Unread. Open thread: Needs review")
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
                window.__codexDashboard.open();
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
                window.__codexDashboard.open();
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

}
