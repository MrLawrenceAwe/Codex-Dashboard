import WebKit
import XCTest

@testable import CodexDashboard

@MainActor
final class SidebarThreadTodoWebTests: SerializedDashboardWebTestCase {
    private func webView() async throws -> WKWebView {
        try await DashboardWebTestHarness.todoWebView(
            html: """
            <!doctype html><html><head><meta charset="utf-8"></head><body>
              <aside role="navigation">
                <button class="sidebar-item">New chat</button>
                <div data-app-action-sidebar-project-row data-app-action-sidebar-project-id="project"
                  data-app-action-sidebar-project-label="Project">
                  <div data-app-action-sidebar-thread-id="local:linked">
                    <span data-thread-title-trigger>Sidebar title</span>
                    <button aria-label="More actions">…</button>
                  </div>
                </div>
                <button data-app-action-sidebar-thread-id="local:uncatalogued">Uncatalogued chat</button>
              </aside>
              <main>Conversation surface</main>
            </body></html>
            """,
            baseURL: URL(string: "https://\(UUID().uuidString).codex-dashboard.test"),
            clearLocalStorage: true
        )
    }

    func testSidebarAddsLinkedTodoWithoutNavigatingAndPreventsDuplicates() async throws {
        let view = try await webView()
        let payload = try DashboardWebTestHarness.snapshotPayload(for: [
            .fixture(id: "linked", title: "Finish linked work"),
        ])
        let result = try await view.evaluateAsyncJavaScript("""
        (async () => {
          window.__codexDashboard.applyThreads((\(payload)).threads);
          const row = document.querySelector('[data-app-action-sidebar-thread-id="local:linked"]');
          window.__rowClicks = 0;
          row.addEventListener('click', () => window.__rowClicks++);
          const button = row.querySelector('[data-codex-thread-todo]');
          button.dispatchEvent(new KeyboardEvent('keydown', {key: 'Enter', bubbles: true}));
          button.click();
          await window.__waitForTodoSaves();
          const items = window.__todoStoreForTests.load();
          return [items.length, items[0].title, items[0].thread.id, items[0].thread.title,
            items[0].project.id, window.__rowClicks, button.disabled, button.title,
            window.__codexDashboard.isOpen()];
        })()
        """) as? [AnyHashable]
        XCTAssertEqual(result, [1, "Finish linked work", "linked", "Finish linked work", "project",
                                0, true, "Already in To-dos", false])

        let completed = try await view.evaluateAsyncJavaScript("""
        (async () => {
          window.__codexDashboard.openTodos();
          document.querySelector('[data-todo-completed]').click();
          await window.__waitForTodoSaves();
          return document.querySelector('[data-codex-thread-todo]').disabled;
        })()
        """) as? Bool
        XCTAssertEqual(completed, false)
    }

    func testUncataloguedChatAndReplacedSidebarAreSupportedAndCleanedUp() async throws {
        let view = try await webView()
        let result = try await view.evaluateAsyncJavaScript("""
        (async () => {
          document.querySelector('[data-app-action-sidebar-thread-id="local:uncatalogued"] [data-codex-thread-todo]').click();
          await window.__waitForTodoSaves();
          const item = window.__todoStoreForTests.load()[0];
          const replacement = document.createElement('aside');
          replacement.setAttribute('role', 'navigation');
          replacement.innerHTML = '<button class="sidebar-item">New chat</button><div data-app-action-sidebar-thread-id="local:later"><span data-thread-title-trigger>Later chat</span></div>';
          document.querySelector('aside').replaceWith(replacement);
          window.__codexDashboard.ensureMounted();
          window.__codexDashboard.ensureMounted();
          const count = replacement.querySelectorAll('[data-codex-thread-todo]').length;
          replacement.querySelector('[data-codex-thread-todo]').click();
          await window.__waitForTodoSaves();
          const titles = window.__todoStoreForTests.load().map(item => item.title);
          window.__codexDashboard.destroy();
          return [item.title, item.thread.id, item.project === null, count, titles,
            document.querySelectorAll('[data-codex-thread-todo], [data-codex-thread-todo-notice]').length];
        })()
        """) as? [Any]
        let values = try XCTUnwrap(result)
        XCTAssertEqual(values[0] as? String, "Uncatalogued chat")
        XCTAssertEqual(values[1] as? String, "uncatalogued")
        XCTAssertEqual(values[2] as? Bool, true)
        XCTAssertEqual(values[3] as? Int, 1)
        XCTAssertEqual(values[4] as? [String], ["Later chat", "Uncatalogued chat"])
        XCTAssertEqual(values[5] as? Int, 0)
    }

    func testFailedSaveCanBeRetried() async throws {
        let view = try await webView()
        let result = try await view.evaluateAsyncJavaScript("""
        (async () => {
          const original = Storage.prototype.setItem;
          Storage.prototype.setItem = function(key, value) {
            if (key === 'codex-dashboard.todos') throw new Error('Storage full');
            return original.call(this, key, value);
          };
          const button = document.querySelector('[data-codex-thread-todo]');
          button.click();
          await window.__waitForTodoSaves();
          await new Promise(resolve => setTimeout(resolve, 20));
          const failed = [button.disabled, document.querySelector('[data-codex-thread-todo-notice]').getAttribute('role'),
            window.__todoStoreForTests.load().length];
          Storage.prototype.setItem = original;
          button.click();
          await window.__waitForTodoSaves();
          return [...failed, window.__todoStoreForTests.load().length, button.disabled];
        })()
        """) as? [AnyHashable]
        XCTAssertEqual(result, [false, "alert", 0, 1, true])
    }
}
