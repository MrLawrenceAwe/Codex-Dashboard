import WebKit
import XCTest

@testable import CodexDashboard

@MainActor
final class TodoStorageFailureWebTests: SerializedDashboardWebTestCase {
    func testFailedTodoSavePreservesTheDraftAndRestoresThePreviousList() async throws {
        let webView = try await DashboardWebTestHarness.todoWebView(
            html: DashboardWebTestHarness.basicTodoHTML,
            baseURL: URL(string: "https://\(UUID().uuidString).codex-dashboard.test"),
            clearLocalStorage: true
        )
        let result = try await webView.evaluateAsyncJavaScript(
            """
            (async () => {
              window.__codexDashboard.openTodos();
              const form = document.querySelector('[data-todo-form]');
              const title = form.querySelector('[data-todo-new-title]');
              const realStorage = window.localStorage;
              window.__todoTestStorage = realStorage;
              Object.defineProperty(window, 'localStorage', {
                configurable: true,
                value: {
                  getItem: realStorage.getItem.bind(realStorage),
                  setItem() { throw new Error('Storage full'); },
                },
              });
              title.value = 'Keep this draft';
              form.requestSubmit();
              await window.__waitForTodoSaves?.();
              Object.defineProperty(window, 'localStorage', {
                configurable: true,
                value: realStorage,
              });
              return [
                title.value,
                document.querySelectorAll('[data-todo-id]').length,
                document.querySelector('[data-todo-storage-error]').hidden,
                localStorage.getItem('codex-dashboard.todos'),
              ];
            })()
            """
        ) as? [Any]

        let values = try XCTUnwrap(result)
        XCTAssertEqual(values[0] as? String, "Keep this draft")
        XCTAssertEqual(values[1] as? Int, 0)
        XCTAssertEqual(values[2] as? Bool, false)
        XCTAssertTrue(values[3] is NSNull)
    }

    func testFailedEditsDeletionAndClearCompletedRestoreSavedItems() async throws {
        let webView = try await DashboardWebTestHarness.todoWebView(
            html: """
            <!doctype html><html><body>
              <aside role="navigation"><button class="sidebar-item">New chat</button></aside>
              <main>Conversation surface</main>
            </body></html>
            """,
            baseURL: URL(string: "https://\(UUID().uuidString).codex-dashboard.test"),
            clearLocalStorage: true
        )
        let result = try await webView.evaluateAsyncJavaScript("""
        (async () => {
          window.__codexDashboard.openTodos();
          const form = document.querySelector('[data-todo-form]');
          form.querySelector('[data-todo-new-title]').value = 'Saved item';
          form.requestSubmit();
          await window.__waitForTodoSaves?.();
          const checkbox = document.querySelector('[data-todo-completed]');
          checkbox.checked = true;
          checkbox.dispatchEvent(new Event('change', { bubbles: true }));
          await window.__waitForTodoSaves?.();
          document.querySelector('[data-todo-filter="completed"]').click();
          await window.__waitForTodoSaves?.();
          const original = localStorage.getItem('codex-dashboard.todos');
          const realStorage = window.localStorage;
          Object.defineProperty(window, 'localStorage', {
            configurable: true,
            value: { getItem: realStorage.getItem.bind(realStorage), setItem() { throw new Error('Storage full'); } },
          });
          const title = document.querySelector('[data-todo-title]');
          title.value = 'Unsaved edit';
          title.dispatchEvent(new Event('change', { bubbles: true }));
          await window.__waitForTodoSaves?.();
          const restoredTitle = document.querySelector('[data-todo-title]').value;
          const deletion = document.querySelector('[data-todo-delete]');
          deletion.click();
          await window.__waitForTodoSaves?.();
          deletion.click();
          await window.__waitForTodoSaves?.();
          const countAfterDelete = document.querySelectorAll('[data-todo-id]').length;
          document.querySelector('[data-todo-clear-completed]').click();
          await window.__waitForTodoSaves?.();
          const countAfterClear = document.querySelectorAll('[data-todo-id]').length;
          Object.defineProperty(window, 'localStorage', { configurable: true, value: realStorage });
          return [restoredTitle, countAfterDelete, countAfterClear,
            realStorage.getItem('codex-dashboard.todos') === original,
            document.querySelector('[data-todo-storage-error]').hidden];
        })()
        """) as? [AnyHashable]
        XCTAssertEqual(result, ["Saved item", 1, 1, true, false])
    }
}
