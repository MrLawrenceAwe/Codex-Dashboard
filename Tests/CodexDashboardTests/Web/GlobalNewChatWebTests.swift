import WebKit
import XCTest

@testable import CodexDashboard

@MainActor
final class GlobalNewChatWebTests: SerializedDashboardWebTestCase {
    func testPointerActivationNeverStartsNativeProjectNavigation() async throws {
        let view = try await makeView()
        let result = try await view.evaluateJavaScript("""
        (() => {
          const button = document.getElementById('global-new-chat');
          const target = button.querySelector('span');
          const nativeEvents = [];
          for (const type of ['pointerdown', 'mousedown', 'click']) {
            button.addEventListener(type, () => nativeEvents.push(type));
          }
          window.__codexDashboard.openTodos();
          const dispatch = (type, EventClass) => target.dispatchEvent(new EventClass(type, {
            bubbles: true, cancelable: true, button: 0,
          }));
          dispatch('pointerdown', PointerEvent);
          dispatch('mousedown', MouseEvent);
          const beforeClick = [window.projectlessChats, nativeEvents.length,
            window.__codexDashboard.isOpen()];
          dispatch('click', MouseEvent);
          return [...beforeClick, window.projectlessChats, nativeEvents.length,
            window.nativeChats, !window.__codexDashboard.isOpen()];
        })()
        """) as? [AnyHashable]
        XCTAssertEqual(result, [0, 0, true, 1, 0, 0, true])
    }

    func testGlobalNewChatClearsProjectAndPreservesOtherActions() async throws {
        let view = try await makeView()
        let result = try await view.evaluateJavaScript("""
        (() => {
          window.__codexDashboard.openTodos();
          document.querySelector('#global-new-chat span').click();
          document.getElementById('project-new-chat').click();
          document.getElementById('quick-chat').click();
          return [window.projectlessChats, window.nativeChats, window.projectChats,
            window.quickChats, !window.__codexDashboard.isOpen(),
            document.querySelector('textarea').value];
        })()
        """) as? [AnyHashable]
        XCTAssertEqual(result, [1, 0, 1, 1, true, "Existing draft"])
    }

    func testRedirectSurvivesReplacementAndIsRemovedOnDestroy() async throws {
        let view = try await makeView()
        let result = try await view.evaluateJavaScript("""
        (() => {
          const original = document.getElementById('global-new-chat');
          const replacement = original.cloneNode(true);
          original.replaceWith(replacement);
          replacement.addEventListener('click', () => window.nativeChats++);
          window.__codexDashboard.ensureMounted();
          window.__codexDashboard.ensureMounted();
          replacement.click();
          replacement.disabled = true;
          replacement.click();
          replacement.disabled = false;
          window.__codexDashboard.destroy();
          replacement.click();
          return [window.projectlessChats, window.nativeChats];
        })()
        """) as? [Int]
        XCTAssertEqual(result, [1, 1])

        let injection = try InjectionBundle.load()
        _ = try await view.evaluateJavaScript(injection.mountExpression)
        let remounted = try await view.evaluateJavaScript("""
        (() => {
          document.getElementById('global-new-chat').click();
          return [window.projectlessChats, window.nativeChats];
        })()
        """) as? [Int]
        XCTAssertEqual(remounted, [2, 1])
    }

    private func makeView() async throws -> WKWebView {
        let view = try await DashboardWebTestHarness.mountedWebView(html: """
        <!doctype html><html><body>
          <aside role="navigation">
            <button class="sidebar-item" id="global-new-chat"><span>New chat</span></button>
            <button id="quick-chat">Quick chat</button>
            <div data-app-action-sidebar-project-row data-app-action-sidebar-project-id="project-a"
              data-app-action-sidebar-project-label="Project A">
              <button id="project-new-chat">New chat</button>
            </div>
          </aside>
          <main id="composer-host"><textarea placeholder="Do anything">Existing draft</textarea></main>
        </body></html>
        """)
        _ = try await view.evaluateJavaScript("""
        (() => {
          window.projectlessChats = window.nativeChats = window.projectChats = window.quickChats = 0;
          const host = document.getElementById('composer-host');
          host.__reactFiber$test = { memoizedProps: {
            selectedProject: { type: 'local', projectId: 'project-a' },
          } };
          window.addEventListener('message', event => {
            if (event.data?.type !== 'new-projectless-task') return;
            window.projectlessChats++;
            host.__reactFiber$test.memoizedProps.selectedProject = null;
          });
          document.getElementById('global-new-chat').addEventListener('click', () => window.nativeChats++);
          document.getElementById('project-new-chat').addEventListener('click', () => window.projectChats++);
          document.getElementById('quick-chat').addEventListener('click', () => window.quickChats++);
        })()
        """)
        return view
    }
}
