import WebKit
import XCTest

@testable import CodexDashboard

@MainActor
final class TodoListWebTests: SerializedDashboardWebTestCase {
    func testTodoDestinationSitsAfterTaskDashboardAndUsesOpenProjects() async throws {
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
        let payload = try DashboardWebTestHarness.snapshotPayload(for: [
            .fixture(
                id: "dashboard",
                projectName: "Codex Dashboard",
                projectPath: "/Users/example/Codex Dashboard"
            ),
            .fixture(
                id: "voice",
                projectName: "Voice Tools",
                projectPath: "/Users/example/Voice Tools"
            ),
        ])

        let result = try await webView.evaluateJavaScript(
            """
            (() => {
              window.__codexDashboard.applyThreads((\(payload)).threads);
              const taskButton = document.getElementById('codex-dashboard-navigation');
              const todoButton = document.getElementById('codex-dashboard-todo-navigation');
              todoButton.click();
              return [
                taskButton.nextElementSibling === todoButton,
                todoButton.nextElementSibling?.textContent.trim(),
                [...document.querySelector('[data-todo-project]').options].map((option) => option.textContent.trim()),
                document.getElementById('codex-dashboard-todo-page').classList.contains('is-open'),
              ];
            })()
            """
        ) as? [Any]

        let values = try XCTUnwrap(result)
        XCTAssertEqual(values[0] as? Bool, true)
        XCTAssertEqual(values[1] as? String, "Scheduled")
        XCTAssertEqual(values[2] as? [String], ["No project", "Codex Dashboard", "Voice Tools"])
        XCTAssertEqual(values[3] as? Bool, true)
    }

    func testTodoCanBeAssignedEditedCompletedFilteredAndDeleted() async throws {
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
        let payload = try DashboardWebTestHarness.snapshotPayload(for: [
            .fixture(projectName: "Codex Dashboard", projectPath: "/projects/dashboard"),
            .fixture(id: "other", projectName: "Voice Tools", projectPath: "/projects/voice"),
        ])

        let result = try await webView.evaluateJavaScript(
            """
            (() => {
              window.__codexDashboard.applyThreads((\(payload)).threads);
              window.__codexDashboard.openTodos();
              const form = document.querySelector('[data-todo-form]');
              form.querySelector('[data-todo-new-title]').value = 'Ship to-do list';
              form.querySelector('[data-todo-project]').value = '/projects/dashboard';
              form.requestSubmit();

              const title = document.querySelector('[data-todo-title]');
              title.value = 'Ship project to-dos';
              title.dispatchEvent(new Event('change', { bubbles: true }));
              const assignment = document.querySelector('[data-todo-project-assignment]');
              assignment.value = '/projects/voice';
              assignment.dispatchEvent(new Event('change', { bubbles: true }));
              const checkbox = document.querySelector('[data-todo-completed]');
              checkbox.checked = true;
              checkbox.dispatchEvent(new Event('change', { bubbles: true }));

              const hiddenFromOpen = document.querySelectorAll('[data-todo-id]').length === 0;
              document.querySelector('[data-todo-filter="completed"]').click();
              const completedTitle = document.querySelector('[data-todo-title]').value;
              const completedProject = document.querySelector('[data-todo-project-assignment]').value;
              const stored = JSON.parse(localStorage.getItem('codex-dashboard.todos')).items[0];
              document.querySelector('[data-todo-delete]').click();
              return [
                hiddenFromOpen,
                completedTitle,
                completedProject,
                stored.completed,
                stored.projectName,
                document.querySelectorAll('[data-todo-id]').length,
              ];
            })()
            """
        ) as? [Any]

        let values = try XCTUnwrap(result)
        XCTAssertEqual(values[0] as? Bool, true)
        XCTAssertEqual(values[1] as? String, "Ship project to-dos")
        XCTAssertEqual(values[2] as? String, "/projects/voice")
        XCTAssertEqual(values[3] as? Bool, true)
        XCTAssertEqual(values[4] as? String, "Voice Tools")
        XCTAssertEqual(values[5] as? Int, 0)
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
