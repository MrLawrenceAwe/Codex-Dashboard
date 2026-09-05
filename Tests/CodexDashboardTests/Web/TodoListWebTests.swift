import WebKit
import XCTest

@testable import CodexDashboard

@MainActor
final class TodoListWebTests: SerializedDashboardWebTestCase {
    func testPageSelectionRemainsExclusiveAcrossRemountAndReinjection() async throws {
        let webView = try await DashboardWebTestHarness.taskDashboardWebView()
        let result = try await webView.evaluateJavaScript("""
        (() => {
          const state = () => [
            document.getElementById('codex-dashboard-page').classList.contains('is-open'),
            document.getElementById('codex-dashboard-todo-page').classList.contains('is-open'),
            document.querySelectorAll('[aria-current="page"]').length,
          ];
          window.__codexDashboard.open();
          document.getElementById('codex-dashboard-todo-navigation').click();
          const todos = state();
          document.getElementById('codex-dashboard-todo-navigation').remove();
          window.__codexDashboard.ensureMounted();
          const remounted = state();
          document.getElementById('codex-dashboard-navigation').click();
          const tasks = state();
          window.__codexDashboard.openTodos();
          return [todos, remounted, tasks, state()];
        })()
        """) as? [[AnyHashable]]
        XCTAssertEqual(result, [
            [false, true, 1], [false, true, 1], [true, false, 1], [false, true, 1],
        ])

        let injection = try InjectionBundle.load()
        _ = try await webView.evaluateJavaScript(injection.mountExpression)
        let sameVersion = try await webView.evaluateJavaScript("""
        [document.querySelectorAll('#codex-dashboard-todo-navigation').length,
         document.getElementById('codex-dashboard-todo-page').classList.contains('is-open')]
        """) as? [AnyHashable]
        XCTAssertEqual(sameVersion, [1, true])

        _ = try await webView.evaluateJavaScript("window.__codexDashboard.version = 'previous-version'")
        _ = try await webView.evaluateJavaScript(injection.mountExpression)
        let replacedVersion = try await webView.evaluateJavaScript("""
        [document.querySelectorAll('#codex-dashboard-todo-navigation').length,
         window.__codexDashboard.isOpen(),
         document.documentElement.classList.contains('codex-todo-open')]
        """) as? [AnyHashable]
        XCTAssertEqual(replacedVersion, [1, false, false])
    }

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

    func testTodoImageCanBePastedDuringAdditionReplacedAndPreservedWhenCompleted() async throws {
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
              const title = form.querySelector('[data-todo-new-title]');
              title.value = 'Review design';
              const file = new File(
                [new Uint8Array([137, 80, 78, 71])],
                'mockup.png',
                { type: 'image/png' }
              );
              const paste = new Event('paste', { bubbles: true, cancelable: true });
              Object.defineProperty(paste, 'clipboardData', { value: { files: [file], items: [] } });
              title.dispatchEvent(paste);
            })()
            """
        )
        try await DashboardWebTestHarness.waitForJavaScript(
            "!document.querySelector('[data-todo-new-image-status]').hidden",
            in: webView
        )
        _ = try await webView.evaluateJavaScript("document.querySelector('[data-todo-form]').requestSubmit()")
        try await DashboardWebTestHarness.waitForJavaScript(
            "document.querySelector('[data-todo-image-preview]') !== null",
            in: webView
        )

        _ = try await webView.evaluateJavaScript(
            """
            (() => {
              const title = document.querySelector('[data-todo-title]');
              const replacement = new File(
                [new Uint8Array([137, 80, 78, 71])],
                'updated-mockup.png',
                { type: 'image/png' }
              );
              const paste = new Event('paste', { bubbles: true, cancelable: true });
              Object.defineProperty(paste, 'clipboardData', { value: { files: [replacement], items: [] } });
              title.dispatchEvent(paste);
            })()
            """
        )
        try await DashboardWebTestHarness.waitForJavaScript(
            "JSON.parse(localStorage.getItem('codex-dashboard.todos')).items[0].image.name === 'updated-mockup.png'",
            in: webView
        )

        let result = try await webView.evaluateJavaScript(
            """
            (() => {
              const stored = JSON.parse(localStorage.getItem('codex-dashboard.todos')).items[0];
              const preview = document.querySelector('[data-todo-image-preview]');
              preview.click();
              const dialog = document.querySelector('[data-todo-image-dialog]');
              const checkbox = document.querySelector('[data-todo-completed]');
              checkbox.checked = true;
              checkbox.dispatchEvent(new Event('change', { bubbles: true }));
              document.querySelector('[data-todo-filter="completed"]').click();
              const values = [
                stored.image.name,
                stored.image.type,
                stored.image.dataURL.startsWith('data:image/png;base64,'),
                dialog.open,
                dialog.querySelector('img').alt,
                document.querySelector('[data-todo-image-preview]') !== null,
                document.querySelector('[data-todo-image-actions]') === null,
                document.querySelectorAll('input[type="file"]').length === 0,
              ];
              dialog.close();
              return values;
            })()
            """
        ) as? [Any]

        let values = try XCTUnwrap(result)
        XCTAssertEqual(values[0] as? String, "updated-mockup.png")
        XCTAssertEqual(values[1] as? String, "image/png")
        XCTAssertEqual(values[2] as? Bool, true)
        XCTAssertEqual(values[3] as? Bool, true)
        XCTAssertEqual(values[4] as? String, "updated-mockup.png")
        XCTAssertEqual(values[5] as? Bool, true)
        XCTAssertEqual(values[6] as? Bool, true)
        XCTAssertEqual(values[7] as? Bool, true)
    }

    func testTodoImagePasteShowsAnErrorForOversizedImages() async throws {
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
              const image = new File([new Uint8Array(2 * 1024 * 1024 + 1)], 'large.png', { type: 'image/png' });
              const paste = new Event('paste', { bubbles: true, cancelable: true });
              Object.defineProperty(paste, 'clipboardData', { value: { files: [image], items: [] } });
              form.querySelector('[data-todo-new-title]').dispatchEvent(paste);
              form.requestSubmit();
              return [
                document.querySelector('[data-todo-image-error]').textContent,
                document.querySelectorAll('[data-todo-id]').length === 0,
              ];
            })()
            """
        ) as? [Any]

        let values = try XCTUnwrap(result)
        XCTAssertEqual(values[0] as? String, "Images must be 2 MB or smaller.")
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
