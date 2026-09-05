import WebKit
import XCTest

@testable import CodexDashboard

@MainActor
final class TodoListWebTests: SerializedDashboardWebTestCase {
    func testTodoDestinationSitsAfterTaskDashboard() async throws {
        let webView = try await DashboardWebTestHarness.mountedWebView(
            html: """
            <!doctype html><html><head><meta charset="utf-8"></head><body>
              <aside role="navigation">
                <button class="sidebar-item">New chat</button>
                <button class="sidebar-item">Scheduled</button>
              </aside>
              <main>Conversation surface</main>
            </body></html>
            """,
            baseURL: URL(string: "https://\(UUID().uuidString).codex-dashboard.test"),
            clearLocalStorage: true
        )
        let result = try await webView.evaluateJavaScript(
            """
            (() => {
              const taskButton = document.getElementById('codex-dashboard-navigation');
              const todoButton = document.getElementById('codex-dashboard-todo-navigation');
              todoButton.click();
              return [
                taskButton.nextElementSibling === todoButton,
                todoButton.nextElementSibling?.textContent.trim(),
                document.querySelector('[data-todo-project]') === null,
                document.getElementById('codex-dashboard-todo-page').classList.contains('is-open'),
                document.querySelector('[data-todo-progress]') === null,
              ];
            })()
            """
        ) as? [Any]

        let values = try XCTUnwrap(result)
        XCTAssertEqual(values[0] as? Bool, true)
        XCTAssertEqual(values[1] as? String, "Scheduled")
        XCTAssertEqual(values[2] as? Bool, true)
        XCTAssertEqual(values[3] as? Bool, true)
        XCTAssertEqual(values[4] as? Bool, true)
    }

    func testTodoCanBeEditedCompletedFilteredAndDeleted() async throws {
        let webView = try await DashboardWebTestHarness.mountedWebView(
            html: """
            <!doctype html><html><head><meta charset="utf-8"></head><body>
              <aside role="navigation"><button class="sidebar-item">New chat</button></aside>
              <main>Conversation surface</main>
            </body></html>
            """,
            baseURL: URL(string: "https://\(UUID().uuidString).codex-dashboard.test"),
            clearLocalStorage: true
        )
        let result = try await webView.evaluateJavaScript(
            """
            (() => {
              window.__codexDashboard.openTodos();
              const form = document.querySelector('[data-todo-form]');
              form.querySelector('[data-todo-new-title]').value = 'Ship to-do list';
              form.requestSubmit();

              const title = document.querySelector('[data-todo-title]');
              title.value = 'Ship project to-dos';
              title.dispatchEvent(new Event('change', { bubbles: true }));
              const checkbox = document.querySelector('[data-todo-completed]');
              checkbox.checked = true;
              checkbox.dispatchEvent(new Event('change', { bubbles: true }));

              const hiddenFromOpen = document.querySelectorAll('[data-todo-id]').length === 0;
              document.querySelector('[data-todo-filter="completed"]').click();
              const completedTitle = document.querySelector('[data-todo-title]').value;
              const stored = JSON.parse(localStorage.getItem('codex-dashboard.todos')).items[0];
              const deleteButton = document.querySelector('[data-todo-delete]');
              deleteButton.click();
              const deletionWasConfirmed = deleteButton.dataset.todoDeleteConfirm === stored.id
                && deleteButton.textContent.trim() === 'Confirm delete';
              const remainsAfterFirstClick = document.querySelectorAll('[data-todo-id]').length === 1;
              deleteButton.click();
              return [
                hiddenFromOpen,
                completedTitle,
                stored.completed,
                Object.hasOwn(stored, 'projectName'),
                deletionWasConfirmed,
                remainsAfterFirstClick,
                document.querySelectorAll('[data-todo-id]').length,
              ];
            })()
            """
        ) as? [Any]

        let values = try XCTUnwrap(result)
        XCTAssertEqual(values[0] as? Bool, true)
        XCTAssertEqual(values[1] as? String, "Ship project to-dos")
        XCTAssertEqual(values[2] as? Bool, true)
        XCTAssertEqual(values[3] as? Bool, false)
        XCTAssertEqual(values[4] as? Bool, true)
        XCTAssertEqual(values[5] as? Bool, true)
        XCTAssertEqual(values[6] as? Int, 0)
    }

    func testTodoImageCanBeUploadedPreviewedPersistedAndRemoved() async throws {
        let webView = try await DashboardWebTestHarness.mountedWebView(
            html: """
            <!doctype html><html><head><meta charset="utf-8"></head><body>
              <aside role="navigation"><button class="sidebar-item">New chat</button></aside>
              <main>Conversation surface</main>
            </body></html>
            """,
            baseURL: URL(string: "https://\(UUID().uuidString).codex-dashboard.test"),
            clearLocalStorage: true
        )
        _ = try await webView.evaluateJavaScript(
            """
            (() => {
              window.__codexDashboard.openTodos();
              const form = document.querySelector('[data-todo-form]');
              form.querySelector('[data-todo-new-title]').value = 'Review design';
              form.requestSubmit();
              const input = document.querySelector('[data-todo-image-input]');
              const file = new File(
                [new Uint8Array([137, 80, 78, 71])],
                'mockup.png',
                { type: 'image/png' }
              );
              Object.defineProperty(input, 'files', { value: [file] });
              input.dispatchEvent(new Event('change', { bubbles: true }));
            })()
            """
        )
        try await DashboardWebTestHarness.waitForJavaScript(
            "document.querySelector('[data-todo-image-preview]') !== null",
            in: webView
        )

        let result = try await webView.evaluateJavaScript(
            """
            (() => {
              const stored = JSON.parse(localStorage.getItem('codex-dashboard.todos')).items[0];
              const preview = document.querySelector('[data-todo-image-preview]');
              preview.click();
              const dialog = document.querySelector('[data-todo-image-dialog]');
              const values = [
                stored.image.name,
                stored.image.type,
                stored.image.dataURL.startsWith('data:image/png;base64,'),
                dialog.open,
                dialog.querySelector('img').alt,
              ];
              dialog.close();
              document.querySelector('[data-todo-image-remove]').click();
              const updated = JSON.parse(localStorage.getItem('codex-dashboard.todos')).items[0];
              values.push(updated.image === null);
              values.push(document.querySelector('[data-todo-image-preview]') === null);
              return values;
            })()
            """
        ) as? [Any]

        let values = try XCTUnwrap(result)
        XCTAssertEqual(values[0] as? String, "mockup.png")
        XCTAssertEqual(values[1] as? String, "image/png")
        XCTAssertEqual(values[2] as? Bool, true)
        XCTAssertEqual(values[3] as? Bool, true)
        XCTAssertEqual(values[4] as? String, "mockup.png")
        XCTAssertEqual(values[5] as? Bool, true)
        XCTAssertEqual(values[6] as? Bool, true)
    }

    func testTodoImageRejectsUnsupportedFiles() async throws {
        let webView = try await DashboardWebTestHarness.mountedWebView(
            html: """
            <!doctype html><html><head><meta charset="utf-8"></head><body>
              <aside role="navigation"><button class="sidebar-item">New chat</button></aside>
              <main>Conversation surface</main>
            </body></html>
            """,
            baseURL: URL(string: "https://\(UUID().uuidString).codex-dashboard.test"),
            clearLocalStorage: true
        )
        let result = try await webView.evaluateJavaScript(
            """
            (() => {
              window.__codexDashboard.openTodos();
              const form = document.querySelector('[data-todo-form]');
              form.querySelector('[data-todo-new-title]').value = 'Review notes';
              form.requestSubmit();
              const input = document.querySelector('[data-todo-image-input]');
              Object.defineProperty(input, 'files', {
                value: [new File(['notes'], 'notes.txt', { type: 'text/plain' })],
              });
              input.dispatchEvent(new Event('change', { bubbles: true }));
              return [
                document.querySelector('[data-todo-image-error]').textContent,
                JSON.parse(localStorage.getItem('codex-dashboard.todos')).items[0].image === null,
              ];
            })()
            """
        ) as? [Any]

        let values = try XCTUnwrap(result)
        XCTAssertEqual(values[0] as? String, "Choose a JPEG, PNG, GIF, or WebP image.")
        XCTAssertEqual(values[1] as? Bool, true)
    }

    func testOpenTodoPageIsRepairedAndClosesForCodexNavigation() async throws {
        let webView = try await DashboardWebTestHarness.taskDashboardWebView()
        _ = try await webView.evaluateJavaScript(
            """
            (() => {
              window.__codexDashboard.openTodos();
              document.getElementById('codex-dashboard-todo-page').remove();
              return window.__codexDashboard.ensureMounted();
            })()
            """
        )
        try await Task.sleep(for: .milliseconds(250))

        let result = try await webView.evaluateJavaScript(
            """
            (() => {
              const restoredOpen = window.__codexDashboard.isOpen()
                && document.documentElement.classList.contains('codex-todo-open');
              const restoredPage = Boolean(document.getElementById('codex-dashboard-todo-page'));
              const restoredPageIsOpen = document.getElementById('codex-dashboard-todo-page')
                ?.classList.contains('is-open') || false;
              window.dispatchEvent(new MessageEvent('message', {
                data: { type: 'navigate-to-route', path: '/local/thread' },
                source: null,
              }));
              return [
                restoredOpen,
                restoredPage,
                restoredPageIsOpen,
                window.__codexDashboard.isOpen(),
                document.documentElement.classList.contains('codex-todo-open'),
              ];
            })()
            """
        ) as? [Bool]

        XCTAssertEqual(result, [true, true, true, false, false])
    }
}
