import WebKit
import XCTest

@testable import CodexDashboard

@MainActor
final class TodoProjectsWebTests: SerializedDashboardWebTestCase {
    func testProjectsComeFromCodexAndCanStartANewTaskWithTheTodo() async throws {
        let webView = try await DashboardWebTestHarness.todoWebView(
            html: """
            <!doctype html><html><head><meta charset="utf-8"></head><body>
              <aside role="navigation">
                <button class="sidebar-item" id="new-chat">New chat</button>
                <div data-app-action-sidebar-project-row data-app-action-sidebar-project-id="dashboard"
                  data-app-action-sidebar-project-label="Codex Dashboard"></div>
              </aside>
              <main>Conversation surface<textarea id="old-composer" placeholder="Do anything"></textarea></main>
            </body></html>
            """,
            baseURL: URL(string: "https://\(UUID().uuidString).codex-dashboard.test"),
            clearLocalStorage: true
        )
        _ = try await webView.evaluateAsyncJavaScript(
            """
            (async () => {
              window.__codexDashboard.openTodos();
              const form = document.querySelector('[data-todo-form]');
              const project = form.querySelector('[data-todo-new-project]');
              const projectNames = [...project.options].map((option) => option.textContent);
              project.value = 'dashboard';
              project.dispatchEvent(new Event('change', { bubbles: true }));
              await window.__waitForTodoSaves?.();
              form.querySelector('[data-todo-new-title]').value = 'Ship project tags';
              form.querySelector('[data-todo-new-body]').value = 'Include the new chat action.';
              form.requestSubmit();
              await window.__waitForTodoSaves?.();
              const stored = JSON.parse(localStorage.getItem('codex-dashboard.todos')).items[0];
              window.__todoProjectNames = projectNames;
              window.__todoProjectID = stored.project.id;
              window.__todoSelectedProjects = [];
              document.querySelector('[data-app-action-sidebar-project-id="dashboard"]').addEventListener('click', () => {
                window.__todoSelectedProjects.push('dashboard');
              });
              document.getElementById('new-chat').addEventListener('click', () => {
                window.__todoNewChatOpened = (window.__todoNewChatOpened || 0) + 1;
                window.__oldTodoComposer = document.getElementById('old-composer');
                setTimeout(() => {
                  window.__oldTodoComposer.remove();
                  const composer = document.createElement('textarea');
                  composer.id = 'new-composer';
                  composer.placeholder = 'Do anything';
                  document.body.append(composer);
                }, 200);
              });
              document.querySelector('[data-todo-new-thread]').click();
              await window.__waitForTodoSaves?.();
            })()
            """
        )
        try await DashboardWebTestHarness.waitForJavaScript(
            "document.getElementById('new-composer')?.value === 'Ship project tags\\n\\nInclude the new chat action.'",
            in: webView
        )
        let result = try await webView.evaluateAsyncJavaScript(
            """
            [
              window.__todoProjectNames,
              window.__todoProjectID,
              document.querySelector('[data-todo-project]').selectedOptions[0].textContent,
              window.__todoNewChatOpened,
              document.getElementById('new-composer').value,
              window.__todoSelectedProjects,
              window.__oldTodoComposer.value,
            ]
            """
        ) as? [Any]

        let values = try XCTUnwrap(result)
        XCTAssertEqual(values[0] as? [String], ["No project", "Codex Dashboard"])
        XCTAssertEqual(values[1] as? String, "dashboard")
        XCTAssertEqual(values[2] as? String, "Codex Dashboard")
        XCTAssertEqual(values[3] as? Int, 1)
        XCTAssertEqual(values[4] as? String, "Ship project tags\n\nInclude the new chat action.")
        XCTAssertEqual(values[5] as? [String], ["dashboard"])
        XCTAssertEqual(values[6] as? String, "")
    }

    func testAddingTodoClearsProjectPickerBeforeNextTodo() async throws {
        let webView = try await DashboardWebTestHarness.todoWebView(
            html: """
            <!doctype html><html><head><meta charset="utf-8"></head><body>
              <aside role="navigation">
                <button class="sidebar-item">New chat</button>
                <div data-app-action-sidebar-project-row data-app-action-sidebar-project-id="project-a"
                  data-app-action-sidebar-project-label="Project A"></div>
              </aside>
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
          const project = form.querySelector('[data-todo-new-project]');
          const title = form.querySelector('[data-todo-new-title]');
          const submit = form.querySelector('button[type="submit"]');
          project.value = 'project-a';
          project.dispatchEvent(new Event('change', { bubbles: true }));
          title.value = 'First item';
          form.requestSubmit();
          await window.__waitForTodoSaves();
          for (let attempt = 0; submit.disabled && attempt < 100; attempt += 1) {
            await new Promise(resolve => setTimeout(resolve, 10));
          }
          const projectAfterFirstAdd = project.value;
          title.value = 'Second item';
          form.requestSubmit();
          await window.__waitForTodoSaves();
          const items = window.__todoStoreForTests.load();
          return [projectAfterFirstAdd, items.map(item => item.title),
            items.map(item => item.project?.id || '')];
        })()
        """) as? [Any]
        let values = try XCTUnwrap(result)
        XCTAssertEqual(values[0] as? String, "")
        XCTAssertEqual(values[1] as? [String], ["Second item", "First item"])
        XCTAssertEqual(values[2] as? [String], ["", "project-a"])
    }

    func testSelectingAProjectOffersOnlyThatProjectsTasks() async throws {
        let webView = try await DashboardWebTestHarness.todoWebView(
            html: """
            <!doctype html><html><head><meta charset="utf-8"></head><body>
              <aside role="navigation">
                <button class="sidebar-item">New chat</button>
                <div data-app-action-sidebar-project-row data-app-action-sidebar-project-id="dashboard"
                  data-app-action-sidebar-project-label="Codex Dashboard"></div>
                <div data-app-action-sidebar-project-row data-app-action-sidebar-project-id="other"
                  data-app-action-sidebar-project-label="Other Project"></div>
              </aside>
              <main>Conversation surface</main>
            </body></html>
            """,
            baseURL: URL(string: "https://\(UUID().uuidString).codex-dashboard.test"),
            clearLocalStorage: true
        )
        let payload = try DashboardWebTestHarness.snapshotPayload(for: [
            .fixture(id: "dashboard-new", title: "Newest dashboard chat", projectName: "Codex Dashboard", projectPath: "/tmp/dashboard", recencyEpochMillis: 3),
            .fixture(id: "dashboard-old", title: "Older dashboard chat", projectName: "Codex Dashboard", projectPath: "/tmp/dashboard", recencyEpochMillis: 2),
            .fixture(id: "other-chat", title: "Other project chat", projectName: "Other Project", projectPath: "/tmp/other", recencyEpochMillis: 1),
        ])

        let result = try await webView.evaluateAsyncJavaScript(
            """
            (async () => {
              window.__codexDashboard.applyThreads((\(payload)).threads);
              window.__codexDashboard.openTodos();
              const form = document.querySelector('[data-todo-form]');
              const project = form.querySelector('[data-todo-new-project]');
              const chat = form.querySelector('[data-todo-new-thread-picker]');
              const initiallyHidden = chat.hidden;
              project.value = 'dashboard';
              project.dispatchEvent(new Event('change', { bubbles: true }));
              const shownAfterProjectSelection = !chat.hidden;
              const enabledAfterProjectSelection = !chat.disabled;
              const choices = [...chat.options].map((option) => option.textContent);
              chat.value = 'dashboard-old';
              chat.dispatchEvent(new Event('change', { bubbles: true }));
              form.querySelector('[data-todo-new-title]').value = 'Continue this work';
              form.requestSubmit();
              await window.__waitForTodoSaves?.();
              const stored = JSON.parse(localStorage.getItem('codex-dashboard.todos')).items[0];
              return [
                initiallyHidden,
                shownAfterProjectSelection,
                enabledAfterProjectSelection,
                choices,
                stored.project.id,
                stored.thread.id,
                stored.thread.title,
                Boolean(document.querySelector('[data-todo-paste-in-thread]')),
                document.querySelector('[data-todo-new-thread]') === null,
              ];
            })()
            """
        ) as? [Any]

        let values = try XCTUnwrap(result)
        XCTAssertEqual(values[0] as? Bool, true)
        XCTAssertEqual(values[1] as? Bool, true)
        XCTAssertEqual(values[2] as? Bool, true)
        XCTAssertEqual(values[3] as? [String], ["No linked task", "Newest dashboard chat", "Older dashboard chat"])
        XCTAssertEqual(values[4] as? String, "dashboard")
        XCTAssertEqual(values[5] as? String, "dashboard-old")
        XCTAssertEqual(values[6] as? String, "Older dashboard chat")
        XCTAssertEqual(values[7] as? Bool, true)
        XCTAssertEqual(values[8] as? Bool, true)
    }

    func testChangingTodoProjectClearsItsPreviousTask() async throws {
        let webView = try await DashboardWebTestHarness.todoWebView(
            html: """
            <!doctype html><html><head><meta charset="utf-8"></head><body>
              <aside role="navigation">
                <button class="sidebar-item">New chat</button>
                <div data-app-action-sidebar-project-row data-app-action-sidebar-project-id="dashboard"
                  data-app-action-sidebar-project-label="Codex Dashboard"></div>
                <div data-app-action-sidebar-project-row data-app-action-sidebar-project-id="other"
                  data-app-action-sidebar-project-label="Other Project"></div>
              </aside>
              <main>Conversation surface</main>
            </body></html>
            """,
            baseURL: URL(string: "https://\(UUID().uuidString).codex-dashboard.test"),
            clearLocalStorage: true
        )
        let payload = try DashboardWebTestHarness.snapshotPayload(for: [
            .fixture(id: "dashboard-chat", title: "Dashboard chat", projectName: "Codex Dashboard", projectPath: "/tmp/dashboard", recencyEpochMillis: 1),
        ])

        let result = try await webView.evaluateAsyncJavaScript(
            """
            (async () => {
              window.__codexDashboard.applyThreads((\(payload)).threads);
              window.__codexDashboard.openTodos();
              const form = document.querySelector('[data-todo-form]');
              const newProject = form.querySelector('[data-todo-new-project]');
              newProject.value = 'dashboard';
              newProject.dispatchEvent(new Event('change', { bubbles: true }));
              const chat = form.querySelector('[data-todo-new-thread-picker]');
              chat.value = 'dashboard-chat';
              chat.dispatchEvent(new Event('change', { bubbles: true }));
              form.querySelector('[data-todo-new-title]').value = 'Move me';
              form.requestSubmit();
              await window.__waitForTodoSaves?.();
              document.querySelector('[data-todo-project]').dispatchEvent(new Event('change', { bubbles: true }));
              await window.__waitForTodoSaves?.();
              const originalChat = JSON.parse(localStorage.getItem('codex-dashboard.todos')).items[0].thread.id;
              const project = document.querySelector('[data-todo-project]');
              project.value = 'other';
              project.dispatchEvent(new Event('change', { bubbles: true }));
              await window.__waitForTodoSaves?.();
              const stored = JSON.parse(localStorage.getItem('codex-dashboard.todos')).items[0];
              return [originalChat, stored.project.id, stored.thread, Boolean(document.querySelector('[data-todo-paste-in-thread]')), Boolean(document.querySelector('[data-todo-new-thread]'))];
            })()
            """
        ) as? [Any]

        let values = try XCTUnwrap(result)
        XCTAssertEqual(values[0] as? String, "dashboard-chat")
        XCTAssertEqual(values[1] as? String, "other")
        XCTAssertTrue(values[2] is NSNull)
        XCTAssertEqual(values[3] as? Bool, false)
        XCTAssertEqual(values[4] as? Bool, true)
    }

    func testTaskPickerDoesNotMixProjectsWithTheSameName() async throws {
        let webView = try await DashboardWebTestHarness.todoWebView(
            html: """
            <!doctype html><html><head><meta charset="utf-8"></head><body>
              <aside role="navigation">
                <button class="sidebar-item">New chat</button>
                <div data-app-action-sidebar-project-row data-app-action-sidebar-project-id="/tmp/one/shared"
                  data-app-action-sidebar-project-label="shared"></div>
                <div data-app-action-sidebar-project-row data-app-action-sidebar-project-id="opaque-project"
                  data-app-action-sidebar-project-label="shared"></div>
              </aside>
              <main>Conversation surface</main>
            </body></html>
            """
        )
        let payload = try DashboardWebTestHarness.snapshotPayload(for: [
            .fixture(id: "one", title: "First project", projectName: "shared", projectPath: "/tmp/one/shared"),
            .fixture(id: "two", title: "Second project", projectName: "shared", projectPath: "/tmp/two/shared"),
        ])
        let choices = try await webView.evaluateJavaScript(
            """
            (() => {
              window.__codexDashboard.applyThreads((\(payload)).threads);
              window.__codexDashboard.openTodos();
              const project = document.querySelector('[data-todo-new-project]');
              const chat = document.querySelector('[data-todo-new-thread-picker]');
              project.value = '/tmp/one/shared';
              project.dispatchEvent(new Event('change', { bubbles: true }));
              const exact = [...chat.options].map((option) => option.value);
              project.value = 'opaque-project';
              project.dispatchEvent(new Event('change', { bubbles: true }));
              return [exact, [...chat.options].map((option) => option.value), chat.disabled];
            })()
            """
        ) as? [Any]
        let values = try XCTUnwrap(choices)
        XCTAssertEqual(values[0] as? [String], ["", "one"])
        XCTAssertEqual(values[1] as? [String], [""])
        XCTAssertEqual(values[2] as? Bool, true)
    }

    func testExistingTodoCanBeAssignedAndUnassignedFromAProject() async throws {
        let webView = try await DashboardWebTestHarness.todoWebView(
            html: """
            <!doctype html><html><head><meta charset="utf-8"></head><body>
              <aside role="navigation">
                <button class="sidebar-item">New chat</button>
                <div data-app-action-sidebar-project-row data-app-action-sidebar-project-id="project-a"
                  data-app-action-sidebar-project-label="Project A"></div>
                <div data-app-action-sidebar-project-row data-app-action-sidebar-project-id="project-b"
                  data-app-action-sidebar-project-label="Project B"></div>
              </aside>
              <main>Conversation surface</main>
            </body></html>
            """,
            baseURL: URL(string: "https://\(UUID().uuidString).codex-dashboard.test"),
            clearLocalStorage: true
        )
        let result = try await webView.evaluateAsyncJavaScript(
            """
            (async () => {
              window.__codexDashboard.openTodos();
              const form = document.querySelector('[data-todo-form]');
              form.querySelector('[data-todo-new-title]').value = 'Assign me later';
              form.requestSubmit();
              await window.__waitForTodoSaves?.();
              const project = document.querySelector('[data-todo-project]');
              const options = [...project.options].map((option) => option.textContent);
              project.value = 'project-b';
              project.dispatchEvent(new Event('change', { bubbles: true }));
              await window.__waitForTodoSaves?.();
              const assigned = JSON.parse(localStorage.getItem('codex-dashboard.todos')).items[0].project;
              const newChatVisible = Boolean(document.querySelector('[data-todo-new-thread]'));
              document.querySelector('[data-todo-project]').value = '';
              document.querySelector('[data-todo-project]').dispatchEvent(new Event('change', { bubbles: true }));
              await window.__waitForTodoSaves?.();
              const unassigned = JSON.parse(localStorage.getItem('codex-dashboard.todos')).items[0].project;
              return [options, assigned.id, assigned.name, newChatVisible, unassigned, Boolean(document.querySelector('[data-todo-new-thread]'))];
            })()
            """
        ) as? [Any]

        let values = try XCTUnwrap(result)
        XCTAssertEqual(values[0] as? [String], ["No project", "Project A", "Project B"])
        XCTAssertEqual(values[1] as? String, "project-b")
        XCTAssertEqual(values[2] as? String, "Project B")
        XCTAssertEqual(values[3] as? Bool, true)
        XCTAssertTrue(values[4] is NSNull)
        XCTAssertEqual(values[5] as? Bool, false)
    }

    func testExistingTodoAssignmentUsesProjectsAvailableAfterTheTodoPageMounts() async throws {
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
              form.querySelector('[data-todo-new-title]').value = 'Assign after refresh';
              form.requestSubmit();
              await window.__waitForTodoSaves?.();
              const row = document.querySelector('[data-todo-id]');
              const project = row.querySelector('[data-todo-project]');
              const sidebarProject = document.createElement('div');
              sidebarProject.dataset.appActionSidebarProjectRow = '';
              sidebarProject.dataset.appActionSidebarProjectId = 'late-project';
              sidebarProject.dataset.appActionSidebarProjectLabel = 'Late Project';
              document.querySelector('aside').append(sidebarProject);
              project.innerHTML = '<option value="">No project</option><option value="late-project">Late Project</option>';
              project.value = 'late-project';
              project.dispatchEvent(new Event('change', { bubbles: true }));
              await window.__waitForTodoSaves?.();
              const stored = JSON.parse(localStorage.getItem('codex-dashboard.todos')).items[0];
              return [stored.project.id, stored.project.name];
            })()
            """
        ) as? [Any]

        let values = try XCTUnwrap(result)
        XCTAssertEqual(values[0] as? String, "late-project")
        XCTAssertEqual(values[1] as? String, "Late Project")
    }

    func testOpeningTodosRefreshesProjectsAfterTheSidebarIsReplaced() async throws {
        let webView = try await DashboardWebTestHarness.todoWebView(
            html: DashboardWebTestHarness.basicTodoHTML,
            baseURL: URL(string: "https://\(UUID().uuidString).codex-dashboard.test"),
            clearLocalStorage: true
        )
        let result = try await webView.evaluateAsyncJavaScript(
            """
            (async () => {
              const replacement = document.createElement('aside');
              replacement.setAttribute('role', 'navigation');
              replacement.innerHTML = `
                <button class="sidebar-item">New chat</button>
                <div data-app-action-sidebar-project-row
                  data-app-action-sidebar-project-id="replacement-project"
                  data-app-action-sidebar-project-label="Replacement Project"></div>`;
              document.querySelector('aside').replaceWith(replacement);
              window.__codexDashboard.openTodos();
              return [...document.querySelector('[data-todo-new-project]').options]
                .map((option) => [option.value, option.textContent]);
            })()
            """
        ) as? [[String]]

        XCTAssertEqual(result, [["", "No project"], ["replacement-project", "Replacement Project"]])
    }

    func testTaskCanBeAddedToTodosAndPastedBackIntoLinkedTask() async throws {
        let webView = try await DashboardWebTestHarness.todoWebView(
            html: """
            <!doctype html><html><head><meta charset="utf-8"></head><body>
              <aside role="navigation">
                <button class="sidebar-item" id="new-chat">New chat</button>
                <button class="sidebar-item" data-app-action-sidebar-thread-id="local:linked-chat">Linked chat</button>
                <div data-app-action-sidebar-project-row data-app-action-sidebar-project-id="/tmp/project"
                  data-app-action-sidebar-project-label="Project"></div>
              </aside>
              <main>Conversation surface</main>
              <script>
                document.getElementById('new-chat').addEventListener('click', () => {
                  window.__newChatCount = (window.__newChatCount || 0) + 1;
                });
                document.querySelector('[data-app-action-sidebar-thread-id]').addEventListener('click', (event) => {
                  event.currentTarget.setAttribute('aria-current', 'page');
                  if (!document.querySelector('textarea[placeholder="Do anything"]')) {
                    const composer = document.createElement('textarea');
                    composer.placeholder = 'Do anything';
                    document.querySelector('main').append(composer);
                  }
                });
              </script>
            </body></html>
            """,
            baseURL: URL(string: "https://\(UUID().uuidString).codex-dashboard.test"),
            clearLocalStorage: true
        )
        let payload = try DashboardWebTestHarness.snapshotPayload(for: [
            .fixture(id: "linked-chat", title: "Finish linked work", runState: .running),
            .fixture(id: "older-project-chat", title: "Older project chat", recencyEpochMillis: 1),
        ])

        let chatChoices = try await webView.evaluateJavaScript(
            """
            (() => {
              window.__codexDashboard.applyThreads((\(payload)).threads);
              window.__codexDashboard.openTodos();
              const form = document.querySelector('[data-todo-form]');
              const project = form.querySelector('[data-todo-new-project]');
              project.value = '/tmp/project';
              project.dispatchEvent(new Event('change', { bubbles: true }));
              const chat = form.querySelector('[data-todo-new-thread-picker]');
              const choices = [...chat.options].map((option) => option.value);
              chat.value = 'linked-chat';
              chat.dispatchEvent(new Event('change', { bubbles: true }));
              form.querySelector('[data-todo-new-title]').value = 'Finish linked work';
              form.requestSubmit();
              return choices;
            })()
            """
        ) as? [String]
        XCTAssertEqual(chatChoices, ["", "linked-chat", "older-project-chat"])
        try await DashboardWebTestHarness.waitForJavaScript(
            "JSON.parse(localStorage.getItem('codex-dashboard.todos') || '{\"items\":[]}').items.length === 1",
            in: webView
        )

        let taggedState = try await webView.evaluateAsyncJavaScript(
            """
            (async () => {
              await window.__waitForTodoSaves?.();
              window.__codexDashboard.openTodos();
              const stored = JSON.parse(localStorage.getItem('codex-dashboard.todos')).items[0];
              return [
                stored.thread.id,
                stored.thread.title,
                document.querySelector('.todo-thread').textContent.trim(),
                document.querySelector('[data-todo-paste-in-thread]').textContent.trim(),
                document.querySelector('[data-todo-new-thread]') === null,
                JSON.parse(localStorage.getItem('codex-dashboard.todos')).items.length,
              ];
            })()
            """
        ) as? [AnyHashable]
        XCTAssertEqual(taggedState, ["linked-chat", "Finish linked work", "#Finish linked work", "Paste into task", true, 1])

        _ = try await webView.evaluateJavaScript(
            "document.querySelector('[data-todo-paste-in-thread]').click()"
        )
        try await DashboardWebTestHarness.waitForJavaScript(
            "document.querySelector('textarea[placeholder=\"Do anything\"]')?.value === 'Finish linked work'",
            in: webView
        )
        let pasteState = try await webView.evaluateJavaScript(
            """
            [
              document.querySelector('[data-app-action-sidebar-thread-id]').getAttribute('aria-current'),
              document.querySelector('textarea[placeholder="Do anything"]').value,
              window.__newChatCount || 0,
              document.documentElement.classList.contains('codex-todo-open'),
            ]
            """
        ) as? [AnyHashable]
        XCTAssertEqual(pasteState, ["page", "Finish linked work", 0, false])
    }
}
