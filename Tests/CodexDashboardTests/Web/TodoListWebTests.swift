import WebKit
import XCTest

@testable import CodexDashboard

@MainActor
final class TodoListWebTests: SerializedDashboardWebTestCase {
    func testPageSelectionRemainsExclusiveAcrossRemountAndReinjection() async throws {
        let webView = try await DashboardWebTestHarness.taskDashboardWebView()
        let result = try await webView.evaluateAsyncJavaScript("""
        (async () => {
          const state = () => [
            document.getElementById('codex-dashboard-page').classList.contains('is-open'),
            document.getElementById('codex-dashboard-todo-page').classList.contains('is-open'),
            document.querySelectorAll('[aria-current="page"]').length,
          ];
          window.__codexDashboard.open();
          document.getElementById('codex-dashboard-todo-navigation').click();
          await window.__waitForTodoSaves?.();
          const todos = state();
          document.getElementById('codex-dashboard-todo-navigation').remove();
          window.__codexDashboard.ensureMounted();
          const remounted = state();
          document.getElementById('codex-dashboard-navigation').click();
          await window.__waitForTodoSaves?.();
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
        let sameVersion = try await webView.evaluateAsyncJavaScript("""
        [document.querySelectorAll('#codex-dashboard-todo-navigation').length,
         document.getElementById('codex-dashboard-todo-page').classList.contains('is-open')]
        """) as? [AnyHashable]
        XCTAssertEqual(sameVersion, [1, true])

        _ = try await webView.evaluateAsyncJavaScript("window.__codexDashboard.version = 'previous-version'")
        _ = try await webView.evaluateJavaScript(injection.mountExpression)
        let replacedVersion = try await webView.evaluateAsyncJavaScript("""
        [document.querySelectorAll('#codex-dashboard-todo-navigation').length,
         window.__codexDashboard.isOpen(),
         document.documentElement.classList.contains('codex-todo-open')]
        """) as? [AnyHashable]
        XCTAssertEqual(replacedVersion, [1, false, false])
    }

    func testTodoDestinationSitsAfterTaskDashboard() async throws {
        let webView = try await DashboardWebTestHarness.todoWebView(
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
        let result = try await webView.evaluateAsyncJavaScript(
            """
            (async () => {
              const taskButton = document.getElementById('codex-dashboard-navigation');
              const todoButton = document.getElementById('codex-dashboard-todo-navigation');
              todoButton.click();
              await window.__waitForTodoSaves?.();
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
        let webView = try await DashboardWebTestHarness.todoWebView(
            html: """
            <!doctype html><html><head><meta charset="utf-8"></head><body>
              <aside role="navigation"><button class="sidebar-item">New chat</button></aside>
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
              form.querySelector('[data-todo-new-title]').value = 'Ship to-do list';
              form.requestSubmit();
              await window.__waitForTodoSaves?.();
              const title = document.querySelector('[data-todo-title]');
              title.value = 'Ship project to-dos';
              title.dispatchEvent(new Event('change', { bubbles: true }));
              await window.__waitForTodoSaves?.();
              const checkbox = document.querySelector('[data-todo-completed]');
              checkbox.checked = true;
              checkbox.dispatchEvent(new Event('change', { bubbles: true }));
              await window.__waitForTodoSaves?.();
              const hiddenFromOpen = document.querySelectorAll('[data-todo-id]').length === 0;
              document.querySelector('[data-todo-filter="completed"]').click();
              await window.__waitForTodoSaves?.();
              const completedTitle = document.querySelector('[data-todo-title]').value;
              const stored = JSON.parse(localStorage.getItem('codex-dashboard.todos')).items[0];
              const deleteButton = document.querySelector('[data-todo-delete]');
              deleteButton.click();
              await window.__waitForTodoSaves?.();
              const deletionWasConfirmed = deleteButton.dataset.todoDeleteConfirm === stored.id
                && deleteButton.textContent.trim() === 'Confirm delete';
              const remainsAfterFirstClick = document.querySelectorAll('[data-todo-id]').length === 1;
              deleteButton.click();
              await window.__waitForTodoSaves?.();
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

    func testTodoTagsCanBeCreatedPersistedAndRemoved() async throws {
        let webView = try await DashboardWebTestHarness.todoWebView(
            html: """
            <!doctype html><html><head><meta charset="utf-8"></head><body>
              <aside role="navigation"><button class="sidebar-item">New chat</button></aside>
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
              const tagPicker = form.querySelector('[data-todo-new-tag]');
              const unavailableBeforeCreation = tagPicker.options.length === 1;
              document.querySelector('[data-todo-manage-tags]').click();
              await window.__waitForTodoSaves?.();
              const tagDialog = document.querySelector('[data-todo-tag-dialog]');
              tagDialog.querySelector('[data-todo-tag-dialog-close]').click();
              await window.__waitForTodoSaves?.();
              const closesFromControl = !tagDialog.open;
              document.querySelector('[data-todo-manage-tags]').click();
              await window.__waitForTodoSaves?.();
              tagDialog.querySelector('[data-todo-tag-name]').value = 'Work';
              tagDialog.querySelector('[data-todo-tag-form]').requestSubmit();
              await window.__waitForTodoSaves?.();
              tagPicker.value = 'Work';
              tagPicker.dispatchEvent(new Event('change', { bubbles: true }));
              await window.__waitForTodoSaves?.();
              form.querySelector('[data-todo-new-title]').value = 'Send update';
              form.requestSubmit();
              await window.__waitForTodoSaves?.();
              const stored = JSON.parse(localStorage.getItem('codex-dashboard.todos')).items[0];
              const renderedTag = document.querySelector('[data-todo-id] .todo-tag').textContent.trim();
              document.querySelector('[data-todo-tag-remove]').click();
              await window.__waitForTodoSaves?.();
              return [unavailableBeforeCreation, closesFromControl, JSON.parse(localStorage.getItem('codex-dashboard.todo-tags')), stored.tags, renderedTag, JSON.parse(localStorage.getItem('codex-dashboard.todos')).items[0].tags];
            })()
            """
        ) as? [Any]

        let values = try XCTUnwrap(result)
        XCTAssertEqual(values[0] as? Bool, true)
        XCTAssertEqual(values[1] as? Bool, true)
        XCTAssertEqual(values[2] as? [String], ["Work"])
        XCTAssertEqual(values[3] as? [String], ["Work"])
        XCTAssertEqual(values[4] as? String, "Work×")
        XCTAssertEqual(values[5] as? [String], [])
    }

    func testTagCanBeAddedToAnExistingTodo() async throws {
        let webView = try await DashboardWebTestHarness.todoWebView(
            html: """
            <!doctype html><html><head><meta charset="utf-8"></head><body>
              <aside role="navigation"><button class="sidebar-item">New chat</button></aside>
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
              form.querySelector('[data-todo-new-title]').value = 'Follow up';
              form.requestSubmit();
              await window.__waitForTodoSaves?.();
              document.querySelector('[data-todo-manage-tags]').click();
              await window.__waitForTodoSaves?.();
              const dialog = document.querySelector('[data-todo-tag-dialog]');
              dialog.querySelector('[data-todo-tag-name]').value = 'Important';
              dialog.querySelector('[data-todo-tag-form]').requestSubmit();
              await window.__waitForTodoSaves?.();
              const picker = document.querySelector('[data-todo-id] [data-todo-tag]');
              picker.value = 'Important';
              picker.dispatchEvent(new Event('change', { bubbles: true }));
              await window.__waitForTodoSaves?.();
              const stored = JSON.parse(localStorage.getItem('codex-dashboard.todos')).items[0];
              return [stored.tags, document.querySelector('[data-todo-id] .todo-tag').textContent.trim()];
            })()
            """
        ) as? [Any]

        let values = try XCTUnwrap(result)
        XCTAssertEqual(values[0] as? [String], ["Important"])
        XCTAssertEqual(values[1] as? String, "Important×")
    }

    func testTodoTagsHaveNoCharacterLimit() async throws {
        let webView = try await DashboardWebTestHarness.todoWebView(
            html: """
            <!doctype html><html><head><meta charset="utf-8"></head><body>
              <aside role="navigation"><button class="sidebar-item">New chat</button></aside>
              <main>Conversation surface</main>
            </body></html>
            """,
            baseURL: URL(string: "https://\(UUID().uuidString).codex-dashboard.test"),
            clearLocalStorage: true
        )
        let result = try await webView.evaluateAsyncJavaScript(
            """
            (async () => {
              const tag = 'A'.repeat(80);
              window.__codexDashboard.openTodos();
              document.querySelector('[data-todo-manage-tags]').click();
              await window.__waitForTodoSaves?.();
              const input = document.querySelector('[data-todo-tag-name]');
              input.value = tag;
              input.form.requestSubmit();
              await window.__waitForTodoSaves?.();
              return [input.maxLength, JSON.parse(localStorage.getItem('codex-dashboard.todo-tags'))[0]];
            })()
            """
        ) as? [Any]

        let values = try XCTUnwrap(result)
        XCTAssertEqual(values[0] as? Int, -1)
        XCTAssertEqual(values[1] as? String, String(repeating: "A", count: 80))
    }

    func testManagedTagDeletionUnassignsItFromTodosAndPersists() async throws {
        let webView = try await DashboardWebTestHarness.todoWebView(
            html: """
            <!doctype html><html><head><meta charset="utf-8"></head><body>
              <aside role="navigation"><button class="sidebar-item">New chat</button></aside>
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
              document.querySelector('[data-todo-manage-tags]').click();
              await window.__waitForTodoSaves?.();
              const dialog = document.querySelector('[data-todo-tag-dialog]');
              dialog.querySelector('[data-todo-tag-name]').value = 'Work';
              dialog.querySelector('[data-todo-tag-form]').requestSubmit();
              await window.__waitForTodoSaves?.();
              form.querySelector('[data-todo-new-tag]').value = 'Work';
              form.querySelector('[data-todo-new-tag]').dispatchEvent(new Event('change', { bubbles: true }));
              await window.__waitForTodoSaves?.();
              form.querySelector('[data-todo-new-title]').value = 'Send update';
              form.requestSubmit();
              await window.__waitForTodoSaves?.();
              const deleteButton = dialog.querySelector('[data-todo-managed-tag-remove="Work"]');
              const accessible = deleteButton.getAttribute('aria-label');
              deleteButton.click();
              await window.__waitForTodoSaves?.();
              return [
                accessible,
                JSON.parse(localStorage.getItem('codex-dashboard.todo-tags')),
                JSON.parse(localStorage.getItem('codex-dashboard.todos')).items[0].tags,
                document.querySelector('[data-todo-managed-tag-remove]') === null,
              ];
            })()
            """
        ) as? [Any]

        let values = try XCTUnwrap(result)
        XCTAssertEqual(values[0] as? String, "Delete tag Work from all to-dos")
        XCTAssertEqual(values[1] as? [String], [])
        XCTAssertEqual(values[2] as? [String], [])
        XCTAssertEqual(values[3] as? Bool, true)
    }

    func testManagedTagCanBeRenamedAcrossTodos() async throws {
        let webView = try await DashboardWebTestHarness.todoWebView(
            html: """
            <!doctype html><html><head><meta charset="utf-8"></head><body>
              <aside role="navigation"><button class="sidebar-item">New chat</button></aside>
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
              document.querySelector('[data-todo-manage-tags]').click();
              await window.__waitForTodoSaves?.();
              const dialog = document.querySelector('[data-todo-tag-dialog]');
              dialog.querySelector('[data-todo-tag-name]').value = 'Work';
              dialog.querySelector('[data-todo-tag-form]').requestSubmit();
              await window.__waitForTodoSaves?.();
              form.querySelector('[data-todo-new-tag]').value = 'Work';
              form.querySelector('[data-todo-new-tag]').dispatchEvent(new Event('change', { bubbles: true }));
              await window.__waitForTodoSaves?.();
              form.querySelector('[data-todo-new-title]').value = 'Send update';
              form.requestSubmit();
              await window.__waitForTodoSaves?.();
              const renameButton = dialog.querySelector('[data-todo-managed-tag-edit="Work"]');
              const accessible = renameButton.getAttribute('aria-label');
              renameButton.click();
              await window.__waitForTodoSaves?.();
              const name = dialog.querySelector('[data-todo-tag-name]');
              const savesRename = dialog.querySelector('[data-todo-tag-form] button').textContent === 'Save tag';
              name.value = 'Client';
              dialog.querySelector('[data-todo-tag-form]').requestSubmit();
              await window.__waitForTodoSaves?.();
              return [
                accessible,
                savesRename,
                JSON.parse(localStorage.getItem('codex-dashboard.todo-tags')),
                JSON.parse(localStorage.getItem('codex-dashboard.todos')).items[0].tags,
                document.querySelector('[data-todo-id] .todo-tag').textContent.trim(),
              ];
            })()
            """
        ) as? [Any]

        let values = try XCTUnwrap(result)
        XCTAssertEqual(values[0] as? String, "Rename tag Work")
        XCTAssertEqual(values[1] as? Bool, true)
        XCTAssertEqual(values[2] as? [String], ["Client"])
        XCTAssertEqual(values[3] as? [String], ["Client"])
        XCTAssertEqual(values[4] as? String, "Client×")
    }

    func testTagDialogIsCenteredAndItsCloseControlDismissesIt() async throws {
        let webView = try await DashboardWebTestHarness.todoWebView(
            html: """
            <!doctype html><html><head><meta charset="utf-8"></head><body>
              <aside role="navigation"><button class="sidebar-item">New chat</button></aside>
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
              document.querySelector('[data-todo-manage-tags]').click();
              await window.__waitForTodoSaves?.();
              const dialog = document.querySelector('[data-todo-tag-dialog]');
              const rect = dialog.getBoundingClientRect();
              const centered = Math.abs(rect.left + rect.width / 2 - window.innerWidth / 2) < 1
                && Math.abs(rect.top + rect.height / 2 - window.innerHeight / 2) < 1;
              dialog.querySelector('[data-todo-tag-dialog-close]').click();
              await window.__waitForTodoSaves?.();
              return [dialog.parentElement.id, centered, !dialog.open];
            })()
            """
        ) as? [Any]

        let values = try XCTUnwrap(result)
        XCTAssertEqual(values[0] as? String, "codex-dashboard-todo-dialogs")
        XCTAssertEqual(values[1] as? Bool, true)
        XCTAssertEqual(values[2] as? Bool, true)
    }

    func testProjectsComeFromCodexAndCanStartANewChatWithTheTodo() async throws {
        let webView = try await DashboardWebTestHarness.todoWebView(
            html: """
            <!doctype html><html><head><meta charset="utf-8"></head><body>
              <aside role="navigation">
                <button class="sidebar-item" id="new-chat">New chat</button>
                <div data-app-action-sidebar-project-row data-app-action-sidebar-project-id="dashboard"
                  data-app-action-sidebar-project-label="Codex Dashboard"></div>
              </aside>
              <main>Conversation surface</main>
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
                const composer = document.createElement('textarea');
                composer.placeholder = 'Do anything';
                document.body.append(composer);
              });
              document.querySelector('[data-todo-new-chat]').click();
              await window.__waitForTodoSaves?.();
            })()
            """
        )
        try await DashboardWebTestHarness.waitForJavaScript(
            "document.querySelector('textarea[placeholder=\"Do anything\"]') !== null",
            in: webView
        )
        let result = try await webView.evaluateAsyncJavaScript(
            """
            [
              window.__todoProjectNames,
              window.__todoProjectID,
              document.querySelector('[data-todo-project]').selectedOptions[0].textContent,
              window.__todoNewChatOpened,
              document.querySelector('textarea[placeholder="Do anything"]').value,
              window.__todoSelectedProjects,
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
    }

    func testSelectingAProjectOffersOnlyThatProjectsChats() async throws {
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
              const chat = form.querySelector('[data-todo-new-chat-picker]');
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
                stored.chat.id,
                stored.chat.title,
                Boolean(document.querySelector('[data-todo-paste-in-chat]')),
                document.querySelector('[data-todo-new-chat]') === null,
              ];
            })()
            """
        ) as? [Any]

        let values = try XCTUnwrap(result)
        XCTAssertEqual(values[0] as? Bool, true)
        XCTAssertEqual(values[1] as? Bool, true)
        XCTAssertEqual(values[2] as? Bool, true)
        XCTAssertEqual(values[3] as? [String], ["No chat", "Newest dashboard chat", "Older dashboard chat"])
        XCTAssertEqual(values[4] as? String, "dashboard")
        XCTAssertEqual(values[5] as? String, "dashboard-old")
        XCTAssertEqual(values[6] as? String, "Older dashboard chat")
        XCTAssertEqual(values[7] as? Bool, true)
        XCTAssertEqual(values[8] as? Bool, true)
    }

    func testNewChatTransfersTheTodoImageToTheComposer() async throws {
        let webView = try await DashboardWebTestHarness.todoWebView(
            html: """
            <!doctype html><html><head><meta charset="utf-8"></head><body>
              <aside role="navigation">
                <button class="sidebar-item" id="new-chat">New chat</button>
                <div data-app-action-sidebar-project-row data-app-action-sidebar-project-id="dashboard"
                  data-app-action-sidebar-project-label="Codex Dashboard"></div>
              </aside>
              <main>Conversation surface</main>
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
              project.value = 'dashboard';
              project.dispatchEvent(new Event('change', { bubbles: true }));
              await window.__waitForTodoSaves?.();
              const title = form.querySelector('[data-todo-new-title]');
              title.value = 'Review the image';
              const image = new File([new Uint8Array([137, 80, 78, 71])], 'handoff.png', { type: 'image/png' });
              const paste = new Event('paste', { bubbles: true, cancelable: true });
              Object.defineProperty(paste, 'clipboardData', { value: { files: [image], items: [] } });
              title.dispatchEvent(paste);
            })()
            """
        )
        try await DashboardWebTestHarness.waitForJavaScript(
            "document.querySelector('[data-todo-new-image-status]').textContent.includes('ready')",
            in: webView
        )
        _ = try await webView.evaluateAsyncJavaScript(
            "document.querySelector('[data-todo-form]').requestSubmit()"
        )
        try await DashboardWebTestHarness.waitForJavaScript(
            "document.querySelector('[data-todo-new-chat]') !== null",
            in: webView
        )
        _ = try await webView.evaluateAsyncJavaScript(
            """
            (async () => {
              window.fetch = () => Promise.reject(new TypeError('Codex renderer rejects data URLs'));
              document.getElementById('new-chat').addEventListener('click', () => {
                const composer = document.createElement('textarea');
                composer.placeholder = 'Do anything';
                composer.addEventListener('paste', (event) => {
                  const file = event.clipboardData?.files?.[0];
                  window.__todoHandoffImage = file ? [file.name, file.type, file.size] : null;
                  event.preventDefault();
                });
                document.body.append(composer);
              });
              document.querySelector('[data-todo-new-chat]').click();
              await window.__waitForTodoSaves?.();
            })()
            """
        )
        try await DashboardWebTestHarness.waitForJavaScript(
            "Array.isArray(window.__todoHandoffImage)",
            in: webView
        )
        let result = try await webView.evaluateAsyncJavaScript(
            "[document.querySelector('textarea[placeholder=\"Do anything\"]').value, ...window.__todoHandoffImage]"
        ) as? [AnyHashable]
        XCTAssertEqual(result, ["Review the image", "handoff.png", "image/png", 4])
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
              const newChatVisible = Boolean(document.querySelector('[data-todo-new-chat]'));
              document.querySelector('[data-todo-project]').value = '';
              document.querySelector('[data-todo-project]').dispatchEvent(new Event('change', { bubbles: true }));
              await window.__waitForTodoSaves?.();
              const unassigned = JSON.parse(localStorage.getItem('codex-dashboard.todos')).items[0].project;
              return [options, assigned.id, assigned.name, newChatVisible, unassigned, Boolean(document.querySelector('[data-todo-new-chat]'))];
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

    func testTodosCanBeFilteredByProjectAndTag() async throws {
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
              const add = async (title, projectID = '', tag = '') => {
                form.querySelector('[data-todo-new-project]').value = projectID;
                form.querySelector('[data-todo-new-project]').dispatchEvent(new Event('change', { bubbles: true }));
                await window.__waitForTodoSaves?.();
                if (tag) {
                  form.querySelector('[data-todo-new-tag]').value = tag;
                  form.querySelector('[data-todo-new-tag]').dispatchEvent(new Event('change', { bubbles: true }));
                  await window.__waitForTodoSaves?.();
                }
                form.querySelector('[data-todo-new-title]').value = title;
                form.requestSubmit();
                await window.__waitForTodoSaves?.();
              };
              document.querySelector('[data-todo-manage-tags]').click();
              await window.__waitForTodoSaves?.();
              const dialog = document.querySelector('[data-todo-tag-dialog]');
              dialog.querySelector('[data-todo-tag-name]').value = 'Work';
              dialog.querySelector('[data-todo-tag-form]').requestSubmit();
              await window.__waitForTodoSaves?.();
              await add('Project A work', 'project-a', 'Work');
              await add('Project B task', 'project-b');
              await add('Unassigned work', '', 'Work');
              const titles = () => [...document.querySelectorAll('[data-todo-title]')].map((input) => input.value);
              const project = document.querySelector('[data-todo-project-filter]');
              const tag = document.querySelector('[data-todo-tag-filter]');
              const projectOptions = [...project.options].map((option) => [option.value, option.textContent]);
              const tagOptions = [...tag.options].map((option) => option.textContent);
              project.value = 'project-a';
              project.dispatchEvent(new Event('change', { bubbles: true }));
              await window.__waitForTodoSaves?.();
              const projectOnly = titles();
              tag.value = 'Work';
              tag.dispatchEvent(new Event('change', { bubbles: true }));
              await window.__waitForTodoSaves?.();
              const combined = titles();
              project.value = '';
              project.dispatchEvent(new Event('change', { bubbles: true }));
              await window.__waitForTodoSaves?.();
              const tagOnly = titles();
              project.value = '__none__';
              project.dispatchEvent(new Event('change', { bubbles: true }));
              await window.__waitForTodoSaves?.();
              const unassignedOnly = titles();
              return [projectOptions, tagOptions, projectOnly, combined, tagOnly, unassignedOnly];
            })()
            """
        ) as? [Any]

        let values = try XCTUnwrap(result)
        XCTAssertEqual(values[0] as? [[String]], [
            ["", "All projects"], ["__none__", "No project (1)"],
            ["project-a", "Project A (1)"], ["project-b", "Project B (1)"],
        ])
        XCTAssertEqual(values[1] as? [String], ["All tags", "Work (2)"])
        XCTAssertEqual(values[2] as? [String], ["Project A work"])
        XCTAssertEqual(values[3] as? [String], ["Project A work"])
        XCTAssertEqual(values[4] as? [String], ["Unassigned work", "Project A work"])
        XCTAssertEqual(values[5] as? [String], ["Unassigned work"])
    }

    func testExistingTodoAssignmentUsesProjectsAvailableAfterTheTodoPageMounts() async throws {
        let webView = try await DashboardWebTestHarness.todoWebView(
            html: """
            <!doctype html><html><head><meta charset="utf-8"></head><body>
              <aside role="navigation"><button class="sidebar-item">New chat</button></aside>
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
            html: """
            <!doctype html><html><head><meta charset="utf-8"></head><body>
              <aside role="navigation"><button class="sidebar-item">New chat</button></aside>
              <main>Conversation surface</main>
            </body></html>
            """,
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

    func testTagPickerOptionsRemainReadableInTheNativeMenu() async throws {
        let webView = try await DashboardWebTestHarness.todoWebView(
            html: """
            <!doctype html><html><head><meta charset="utf-8"><style>:root { --app-color-background-surface: #fff; --app-color-text-foreground: #1f1f1f; }</style></head><body>
              <aside role="navigation"><button class="sidebar-item">New chat</button></aside>
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
              const option = document.querySelector('[data-todo-new-tag] option');
              const style = getComputedStyle(option);
              return [style.backgroundColor, style.color];
            })()
            """
        ) as? [String]

        XCTAssertEqual(result, ["rgb(255, 255, 255)", "rgb(31, 31, 31)"])
    }

    func testFailedTodoSavePreservesTheDraftAndRestoresThePreviousList() async throws {
        let webView = try await DashboardWebTestHarness.todoWebView(
            html: """
            <!doctype html><html><head><meta charset="utf-8"></head><body>
              <aside role="navigation"><button class="sidebar-item">New chat</button></aside>
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

    func testTodoImageCanBePastedDuringAdditionReplacedAndPreservedWhenCompleted() async throws {
        let webView = try await DashboardWebTestHarness.todoWebView(
            html: """
            <!doctype html><html><head><meta charset="utf-8"></head><body>
              <aside role="navigation"><button class="sidebar-item">New chat</button></aside>
              <main>Conversation surface</main>
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
            "Boolean(document.querySelector('[data-todo-new-image-preview]:not([hidden]) img')?.src.startsWith('data:image/png;base64,'))",
            in: webView
        )
        let draftPreview = try await webView.evaluateAsyncJavaScript(
            "[document.querySelector('[data-todo-new-image-preview] img').alt, document.querySelector('[data-todo-new-image-status]').textContent]"
        ) as? [String]
        XCTAssertEqual(draftPreview, ["mockup.png", "Image ready to attach when you add this to-do."])
        let draftDialog = try await webView.evaluateAsyncJavaScript(
            """
            (async () => {
              document.querySelector('[data-todo-new-image-open]').click();
              await window.__waitForTodoSaves?.();
              const dialog = document.querySelector('[data-todo-image-dialog]');
              const result = [dialog.open, dialog.querySelector('img').alt];
              dialog.close();
              return result;
            })()
            """
        ) as? [AnyHashable]
        XCTAssertEqual(draftDialog, [true, "mockup.png"])
        _ = try await webView.evaluateAsyncJavaScript("document.querySelector('[data-todo-form]').requestSubmit()")
        try await DashboardWebTestHarness.waitForJavaScript(
            "document.querySelector('[data-todo-image-preview]') !== null",
            in: webView
        )
        try await DashboardWebTestHarness.waitForJavaScript(
            "document.querySelector('[data-todo-new-image-preview]').hidden",
            in: webView
        )

        _ = try await webView.evaluateAsyncJavaScript(
            """
            (async () => {
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

        let result = try await webView.evaluateAsyncJavaScript(
            """
            (async () => {
              const stored = JSON.parse(localStorage.getItem('codex-dashboard.todos')).items[0];
              const preview = document.querySelector('[data-todo-image-preview]');
              preview.click();
              await window.__waitForTodoSaves?.();
              const dialog = document.querySelector('[data-todo-image-dialog]');
              const checkbox = document.querySelector('[data-todo-completed]');
              checkbox.checked = true;
              checkbox.dispatchEvent(new Event('change', { bubbles: true }));
              await window.__waitForTodoSaves?.();
              document.querySelector('[data-todo-filter="completed"]').click();
              await window.__waitForTodoSaves?.();
              const values = [
                stored.image.name,
                stored.image.type,
                !Object.hasOwn(stored.image, 'dataURL') || stored.image.dataURL === '',
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
        let webView = try await DashboardWebTestHarness.todoWebView(
            html: """
            <!doctype html><html><head><meta charset="utf-8"></head><body>
              <aside role="navigation"><button class="sidebar-item">New chat</button></aside>
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
              form.querySelector('[data-todo-new-title]').value = 'Review notes';
              const image = new File([new Uint8Array(2 * 1024 * 1024 + 1)], 'large.png', { type: 'image/png' });
              const paste = new Event('paste', { bubbles: true, cancelable: true });
              Object.defineProperty(paste, 'clipboardData', { value: { files: [image], items: [] } });
              form.querySelector('[data-todo-new-title]').dispatchEvent(paste);
              form.requestSubmit();
              await window.__waitForTodoSaves?.();
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

    func testTodoImageDoesNotStoreItsDataURLInLocalStorage() async throws {
        let webView = try await DashboardWebTestHarness.todoWebView(
            html: """
            <!doctype html><html><head><meta charset="utf-8"></head><body>
              <aside role="navigation"><button class="sidebar-item">New chat</button></aside>
              <main>Conversation surface</main>
            </body></html>
            """,
            baseURL: URL(string: "https://\(UUID().uuidString).codex-dashboard.test"),
            clearLocalStorage: true
        )
        _ = try await webView.evaluateAsyncJavaScript(
            """
            (async () => {
              window.__codexDashboard.openTodos();
              const title = document.querySelector('[data-todo-new-title]');
              title.value = 'Keep screenshot';
              const image = new File([new Uint8Array(24 * 1024)], 'screenshot.png', { type: 'image/png' });
              const paste = new Event('paste', { bubbles: true, cancelable: true });
              Object.defineProperty(paste, 'clipboardData', { value: { files: [image], items: [] } });
              title.dispatchEvent(paste);
            })()
            """
        )
        try await DashboardWebTestHarness.waitForJavaScript(
            "document.querySelector('[data-todo-new-image-status]').textContent.includes('ready')",
            in: webView
        )
        _ = try await webView.evaluateAsyncJavaScript(
            """
            (async () => {
              const realStorage = window.localStorage;
              window.__todoTestStorage = realStorage;
              Object.defineProperty(window, 'localStorage', {
                configurable: true,
                value: {
                  getItem: realStorage.getItem.bind(realStorage),
                  setItem(key, value) {
                    if (value.length > 1024) throw new Error('Storage full');
                    return realStorage.setItem(key, value);
                  },
                },
              });
              document.querySelector('[data-todo-form]').requestSubmit();
              await window.__waitForTodoSaves?.();
            })()
            """
        )
        try await DashboardWebTestHarness.waitForJavaScript(
            "document.querySelectorAll('[data-todo-id]').length === 1",
            in: webView
        )
        try await DashboardWebTestHarness.waitForJavaScript(
            "window.localStorage.getItem('codex-dashboard.todos') !== null",
            in: webView
        )
        let result = try await webView.evaluateAsyncJavaScript(
            """
            (async () => {
              Object.defineProperty(window, 'localStorage', {
                configurable: true,
                value: window.__todoTestStorage,
              });
              delete window.__todoTestStorage;
              const stored = JSON.parse(window.localStorage.getItem('codex-dashboard.todos')).items[0];
              return [document.querySelectorAll('[data-todo-id]').length, stored.image.dataURL,
                document.querySelector('[data-todo-storage-error]').hidden];
            })()
            """
        ) as? [Any]

        let values = try XCTUnwrap(result)
        XCTAssertEqual(values[0] as? Int, 1)
        XCTAssertEqual(values[1] as? String, "")
        XCTAssertEqual(values[2] as? Bool, true)
    }

    func testPastedTodoImageCanBeRemovedFromTheAddBar() async throws {
        let webView = try await DashboardWebTestHarness.todoWebView(
            html: """
            <!doctype html><html><head><meta charset="utf-8"></head><body>
              <aside role="navigation"><button class="sidebar-item">New chat</button></aside>
              <main>Conversation surface</main>
            </body></html>
            """,
            baseURL: URL(string: "https://\(UUID().uuidString).codex-dashboard.test"),
            clearLocalStorage: true
        )
        _ = try await webView.evaluateAsyncJavaScript(
            """
            (async () => {
              window.__codexDashboard.openTodos();
              const title = document.querySelector('[data-todo-new-title]');
              const file = new File([new Uint8Array([137, 80, 78, 71])], 'draft.png', { type: 'image/png' });
              const paste = new Event('paste', { bubbles: true, cancelable: true });
              Object.defineProperty(paste, 'clipboardData', { value: { files: [], items: [
                { kind: 'file', type: 'image/png', getAsFile: () => file },
              ] } });
              title.dispatchEvent(paste);
            })()
            """
        )
        try await DashboardWebTestHarness.waitForJavaScript(
            "!document.querySelector('[data-todo-new-image-preview]').hidden",
            in: webView
        )

        let result = try await webView.evaluateAsyncJavaScript(
            """
            (async () => {
              document.querySelector('[data-todo-new-image-remove]').click();
              await window.__waitForTodoSaves?.();
              return [
                document.querySelector('[data-todo-new-image-preview]').hidden,
                document.querySelector('[data-todo-new-image-preview] img').getAttribute('src'),
                document.querySelector('[data-todo-new-image-status]').hidden,
                document.activeElement === document.querySelector('[data-todo-new-title]'),
              ];
            })()
            """
        ) as? [AnyHashable]
        XCTAssertEqual(result, [true, "", true, true])
    }

    func testOpenTodoPageIsRepairedAndClosesForCodexNavigation() async throws {
        let webView = try await DashboardWebTestHarness.taskDashboardWebView()
        _ = try await webView.evaluateAsyncJavaScript(
            """
            (async () => {
              window.__codexDashboard.openTodos();
              document.getElementById('codex-dashboard-todo-page').remove();
              return window.__codexDashboard.ensureMounted();
            })()
            """
        )
        try await Task.sleep(for: .milliseconds(250))

        let result = try await webView.evaluateAsyncJavaScript(
            """
            (async () => {
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

    func testChatCanBeAddedToTodosAndPastedBackIntoTaggedChat() async throws {
        let webView = try await DashboardWebTestHarness.todoWebView(
            html: """
            <!doctype html><html><head><meta charset="utf-8"></head><body>
              <aside role="navigation">
                <button class="sidebar-item" id="new-chat">New chat</button>
                <button class="sidebar-item" data-app-action-sidebar-thread-id="local:linked-chat">Linked chat</button>
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

        _ = try await webView.evaluateJavaScript(
            """
            (() => {
              window.__codexDashboard.applyThreads((\(payload)).threads);
              window.__codexDashboard.open();
              document.querySelector('[data-filter="running"]').click();
              document.querySelector('.dashboard-project-chat-picker').open = true;
              window.__projectChatChoiceCount = document.querySelectorAll('.dashboard-project-chat-picker [data-add-chat-to-todos]').length;
              document.querySelector('.dashboard-project-chat-picker [data-add-chat-to-todos="linked-chat"]').click();
            })()
            """
        )
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
                stored.chat.id,
                stored.chat.title,
                document.querySelector('.todo-chat').textContent.trim(),
                document.querySelector('[data-todo-paste-in-chat]').textContent.trim(),
                document.querySelector('[data-todo-new-chat]') === null,
                document.querySelector('[data-add-chat-to-todos]').disabled,
                JSON.parse(localStorage.getItem('codex-dashboard.todos')).items.length,
                window.__projectChatChoiceCount,
              ];
            })()
            """
        ) as? [AnyHashable]
        XCTAssertEqual(taggedState, ["linked-chat", "Finish linked work", "#Finish linked work", "Paste in chat", true, true, 1, 2])

        _ = try await webView.evaluateJavaScript(
            "document.querySelector('[data-todo-paste-in-chat]').click()"
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
