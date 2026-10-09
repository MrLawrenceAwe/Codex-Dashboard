import WebKit
import XCTest

@testable import CodexDashboard

@MainActor
final class TodoDestinationWebTests: SerializedDashboardWebTestCase {
    func testTodoWithoutProjectStartsProjectlessChatWithoutSending() async throws {
        let result = try await transferProjectlessTodo()
        XCTAssertEqual(result, ["Personal task\n\nPersonal details", "Existing draft", 1, 0, 0, true, true, false])
    }

    func testProjectlessTransferDoesNotWriteIntoProjectDraft() async throws {
        let result = try await transferProjectlessTodo(destinationChange: "props.selectedProject = { type: 'local', projectId: 'project-b' };")
        XCTAssertEqual(result, ["", "Existing draft", 1, 0, 0, true, true, false])
    }

    func testProjectlessTransferDoesNotWriteIntoAnotherChat() async throws {
        let result = try await transferProjectlessTodo(destinationChange: "props.conversationId = 'unrelated-chat';")
        XCTAssertEqual(result, ["", "Existing draft", 1, 0, 0, true, true, false])
    }

    func testProjectlessTransferDoesNotWriteIntoRemoteProjectDraft() async throws {
        let result = try await transferProjectlessTodo(destinationChange: "props.selectedProject = { type: 'remote', projectId: 'remote-project' };")
        XCTAssertEqual(result, ["", "Existing draft", 1, 0, 0, true, true, false])
    }

    func testProjectlessTransferWaitsForExplicitProjectlessSelection() async throws {
        let result = try await transferProjectlessTodo(destinationChange: "delete props.selectedProject;")
        XCTAssertEqual(result, ["", "Existing draft", 1, 0, 0, true, true, false])
    }

    private func transferProjectlessTodo(destinationChange: String = "") async throws -> [AnyHashable]? {
        let view = try await DashboardWebTestHarness.todoWebView(
            html: """
            <!doctype html><html><body>
              <aside role="navigation"><button class="sidebar-item" id="new-chat">New chat</button></aside>
              <main id="composer-host"><textarea placeholder="Do anything">Existing draft</textarea></main>
            </body></html>
            """,
            baseURL: URL(string: "https://\(UUID().uuidString).codex-dashboard.test"),
            clearLocalStorage: true
        )
        return try await view.evaluateAsyncJavaScript("""
        (async () => {
          const host = document.getElementById('composer-host');
          const oldComposer = host.querySelector('textarea');
          host['__reactFiber$test'] = { memoizedProps: {
            conversationId: 'existing-chat', selectedProject: { type: 'local', projectId: 'project-a' },
          } };
          window.__codexDashboard.openTodos();
          const form = document.querySelector('[data-todo-form]');
          form.querySelector('[data-todo-new-title]').value = 'Personal task';
          form.querySelector('[data-todo-new-body]').value = 'Personal details';
          form.requestSubmit();
          await window.__waitForTodoSaves();
          let projectlessCount = 0;
          let sidebarCount = 0;
          let submitCount = 0;
          document.getElementById('new-chat').addEventListener('click', () => sidebarCount++);
          document.addEventListener('submit', () => submitCount++);
          window.addEventListener('message', (event) => {
            if (event.data?.type !== 'new-projectless-task') return;
            projectlessCount++;
            setTimeout(() => {
              const composer = document.createElement('textarea');
              composer.placeholder = 'Do anything';
              host.replaceChildren(composer);
              const props = { selectedProject: null };
              host['__reactFiber$test'] = { memoizedProps: props };
              setTimeout(() => { \(destinationChange) }, 100);
            }, 100);
          });
          const button = document.querySelector('[data-todo-new-thread]');
          const projectlessLabel = button?.getAttribute('aria-label') === 'Start a new chat with no project';
          button.click();
          button.click();
          await window.__waitForTodoTransfers();
          const stored = JSON.parse(localStorage.getItem('codex-dashboard.todos')).items[0];
          return [host.querySelector('textarea').value, oldComposer.value, projectlessCount,
            sidebarCount, submitCount, stored.project === null && stored.thread === null,
            projectlessLabel, document.documentElement.classList.contains('codex-todo-open')];
        })()
        """) as? [AnyHashable]
    }

    func testNewChatTransferDoesNotWriteIntoAnotherChat() async throws {
        try await assertNewChatTransferDoesNotWrite(destinationChange: "props.conversationId = 'unrelated-chat';")
    }

    func testNewChatTransferDoesNotWriteIntoAnotherProjectDraft() async throws {
        try await assertNewChatTransferDoesNotWrite(destinationChange: "props.selectedProject.projectId = 'project-b';")
    }

    private func assertNewChatTransferDoesNotWrite(destinationChange: String) async throws {
        let view = try await DashboardWebTestHarness.todoWebView(
            html: """
            <!doctype html><html><body>
              <aside role="navigation">
                <button class="sidebar-item" id="new-chat">New chat</button>
                <div data-app-action-sidebar-project-row data-app-action-sidebar-project-id="project-a"
                  data-app-action-sidebar-project-label="Project A"></div>
              </aside>
              <main id="composer-host"><textarea placeholder="Do anything"></textarea></main>
            </body></html>
            """,
            baseURL: URL(string: "https://\(UUID().uuidString).codex-dashboard.test"),
            clearLocalStorage: true
        )
        let result = try await view.evaluateAsyncJavaScript("""
        (async () => {
          const host = document.getElementById('composer-host');
          const props = { selectedProject: { type: 'local', projectId: 'project-a' } };
          host['__reactFiber$test'] = { memoizedProps: props };
          window.__codexDashboard.openTodos();
          const form = document.querySelector('[data-todo-form]');
          const project = form.querySelector('[data-todo-new-project]');
          project.value = 'project-a';
          project.dispatchEvent(new Event('change', { bubbles: true }));
          form.querySelector('[data-todo-new-title]').value = 'Project A task';
          form.requestSubmit();
          await window.__waitForTodoSaves();
          document.getElementById('new-chat').addEventListener('click', () => {
            setTimeout(() => { \(destinationChange) }, 100);
          });
          document.querySelector('[data-todo-new-thread]').click();
          await window.__waitForTodoTransfers();
          return host.querySelector('textarea').value;
        })()
        """) as? String
        XCTAssertEqual(result, "")
    }

    func testSymlinkProjectCanListItsCataloguedChats() async throws {
        let view = try await DashboardWebTestHarness.todoWebView(
            html: """
            <!doctype html><html><body>
              <aside role="navigation"><button class="sidebar-item">New chat</button>
                <div data-app-action-sidebar-project-row data-app-action-sidebar-project-id="project-a"
                  data-app-action-sidebar-project-label="Project A"></div>
              </aside><main>Conversation surface</main>
            </body></html>
            """
        )
        let payload = try DashboardWebTestHarness.snapshotPayload(for: [
            .fixture(id: "chat-a", title: "Project A chat", checkoutPath: "/private/tmp/project-a", projectID: "project-a"),
        ])
        let result = try await view.evaluateAsyncJavaScript("""
        (() => {
          const row = document.querySelector('[data-app-action-sidebar-project-id="project-a"]');
          row['__reactFiber$test'] = { memoizedProps: {
            group: { projectId: 'project-a', projectKind: 'local', path: '/tmp/project-a' },
          } };
          const threads = (\(payload)).threads;
          window.__codexDashboard.applyThreads(threads);
          window.__codexDashboard.openTodos();
          const project = document.querySelector('[data-todo-new-project]');
          project.value = 'project-a';
          project.dispatchEvent(new Event('change', { bubbles: true }));
          return [...document.querySelector('[data-todo-new-thread-picker]').options].map(option => option.value);
        })()
        """) as? [String]
        XCTAssertEqual(result, ["", "chat-a"])
    }
}
