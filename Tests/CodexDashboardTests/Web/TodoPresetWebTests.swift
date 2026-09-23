import WebKit
import XCTest

@testable import CodexDashboard

@MainActor
final class TodoPresetWebTests: SerializedDashboardWebTestCase {
    func testTodoModelPresetCanBeCreatedEditedAndRemoved() async throws {
        let webView = try await DashboardWebTestHarness.todoWebView(
            html: DashboardWebTestHarness.basicTodoHTML,
            baseURL: URL(string: "https://\(UUID().uuidString).codex-dashboard.test"),
            clearLocalStorage: true
        )
        let result = try await webView.evaluateAsyncJavaScript("""
        (async () => {
          window.__codexDashboard.openTodos();
          const form = document.querySelector('[data-todo-form]');
          const enabled = form.querySelector('[data-todo-new-preset-enabled]');
          enabled.click();
          form.querySelector('[data-todo-new-preset-model]').value = 'gpt-6-sol';
          form.querySelector('[data-todo-new-preset-effort]').value = 'high';
          form.querySelector('[data-todo-new-preset-speed]').value = 'fast';
          form.querySelector('[data-todo-new-title]').value = 'Review release';
          form.requestSubmit();
          await window.__waitForTodoSaves();
          const read = () => JSON.parse(localStorage.getItem('codex-dashboard.todos')).items[0];
          const created = read().preset;
          const summary = document.querySelector('[data-todo-preset-details] summary').textContent;
          document.querySelector('[data-todo-preset-details] summary').click();
          const effort = document.querySelector('[data-todo-item-preset-effort]');
          effort.value = 'max';
          effort.dispatchEvent(new Event('change', { bubbles: true }));
          await window.__waitForTodoSaves();
          const edited = read().preset;
          const stillOpen = document.querySelector('[data-todo-preset-details]').open;
          document.querySelector('[data-todo-preset-enabled]').click();
          await window.__waitForTodoSaves();
          return [created.model, created.reasoningEffort, created.speed,
            summary, edited.reasoningEffort, stillOpen, read().preset,
            form.querySelector('[data-todo-new-preset-enabled]').checked];
        })()
        """) as? [Any]
        let values = try XCTUnwrap(result)
        XCTAssertEqual(values[0] as? String, "gpt-6-sol")
        XCTAssertEqual(values[1] as? String, "high")
        XCTAssertEqual(values[2] as? String, "fast")
        XCTAssertEqual(values[3] as? String, "GPT-6 Sol · High · Fast")
        XCTAssertEqual(values[4] as? String, "max")
        XCTAssertEqual(values[5] as? Bool, true)
        XCTAssertTrue(values[6] is NSNull)
        XCTAssertEqual(values[7] as? Bool, false)
    }

    func testTodoIsNotInsertedWhenItsModelPresetCannotBeApplied() async throws {
        let webView = try await DashboardWebTestHarness.todoWebView(
            html: """
            <!doctype html><html><body>
              <aside role="navigation">
                <button class="sidebar-item" id="new-chat">New chat</button>
                <div data-app-action-sidebar-project-row data-app-action-sidebar-project-id="dashboard"
                  data-app-action-sidebar-project-label="Codex Dashboard"></div>
              </aside><main></main>
            </body></html>
            """,
            baseURL: URL(string: "https://\(UUID().uuidString).codex-dashboard.test"),
            clearLocalStorage: true
        )
        let result = try await webView.evaluateAsyncJavaScript("""
        (async () => {
          window.__codexDashboard.openTodos();
          const form = document.querySelector('[data-todo-form]');
          const project = form.querySelector('[data-todo-new-project]');
          project.value = 'dashboard';
          project.dispatchEvent(new Event('change', { bubbles: true }));
          form.querySelector('[data-todo-new-preset-enabled]').click();
          form.querySelector('[data-todo-new-title]').value = 'Keep this draft';
          form.requestSubmit();
          await window.__waitForTodoSaves();
          document.getElementById('new-chat').addEventListener('click', () => {
            const composer = document.createElement('textarea');
            composer.placeholder = 'Do anything';
            document.body.append(composer);
          });
          document.querySelector('[data-todo-new-thread]').click();
          await new Promise((resolve) => setTimeout(resolve, 1600));
          return [document.querySelector('textarea[placeholder="Do anything"]').value,
            !document.querySelector('[data-todo-composer-error]').hidden,
            document.documentElement.classList.contains('codex-todo-open')];
        })()
        """) as? [AnyHashable]
        XCTAssertEqual(result, ["", true, true])
    }
}
