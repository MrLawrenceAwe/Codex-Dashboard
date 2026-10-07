import WebKit
import XCTest

@testable import CodexDashboard

@MainActor
final class TodoDestinationWebTests: SerializedDashboardWebTestCase {
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
