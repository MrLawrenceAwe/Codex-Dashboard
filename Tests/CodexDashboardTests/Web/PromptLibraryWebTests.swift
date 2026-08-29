import WebKit
import XCTest

@testable import CodexDashboard

@MainActor
final class PromptLibraryWebTests: SerializedDashboardWebTestCase {
    func testRendererPromptValidationMatchesNativeRequiredFields() async throws {
        let webView = try await DashboardWebTestHarness.promptLibraryWebView()
        let result = try await webView.evaluateJavaScript(
            """
            JSON.stringify([
              window.__codexDashboard.applyPromptLibrary({
                version: \(PromptLibrarySchema.currentVersion),
                prompts: [{ id: '', name: 'Name', content: 'Content', scope: { type: 'global' } }],
                sections: [],
              }),
              window.__codexDashboard.applyPromptLibrary({
                version: \(PromptLibrarySchema.currentVersion),
                prompts: [{ id: 'id', name: '', content: 'Content', scope: { type: 'global' } }],
                sections: [],
              }),
              window.__codexDashboard.applyPromptLibrary({
                version: \(PromptLibrarySchema.currentVersion),
                prompts: [{ id: 'id', name: 'Name', content: '', scope: { type: 'global' } }],
                sections: [],
              }),
              window.__codexDashboard.applyPromptLibrary({
                version: \(PromptLibrarySchema.currentVersion),
                prompts: [{ id: 'id', name: 'Name', content: 'Content', scope: { type: 'global' } }],
                sections: [],
              }),
            ])
            """
        ) as? String

        XCTAssertEqual(result, "[false,false,false,true]")
    }

    func testProjectPromptCanBeCreatedFromProjectNewChatBeforeThreadExists() async throws {
        let webView = try await DashboardWebTestHarness.promptLibraryWebView()
        let result = try await webView.evaluateJavaScript(
            """
            (() => {
              const projectID = 'project-a-id';
              const projectRow = document.createElement('div');
              projectRow.dataset.appActionSidebarProjectId = projectID;
              projectRow.__reactFiber$test = {
                memoizedProps: {},
                return: {
                  memoizedProps: {
                    group: {
                      projectId: projectID,
                      projectKind: 'local',
                      label: 'Project A',
                      path: '/tmp/project-a',
                    },
                  },
                  return: null,
                },
              };
              document.querySelector('aside').append(projectRow);

              const composerShell = document.querySelector('.composer-shell');
              composerShell.__reactFiber$test = {
                memoizedProps: {
                  selectedProject: { projectId: projectID, type: 'local' },
                },
                return: null,
              };

              document.querySelector('[data-codex-prompt-launcher]').click();
              document.querySelector('[data-prompt-new]').click();
              const scopeOptions = [...document.querySelector('[name="scope"]').options]
                .map((option) => option.textContent);
              document.querySelector('[name="name"]').value = 'New chat project prompt';
              document.querySelector('[name="content"]').value = 'Project-only content';
              document.querySelector('[data-prompt-form] button[type="submit"]').click();
              const stored = JSON.parse(window.__codexDashboard.exportPromptLibrary());
              return {
                headings: [...document.querySelectorAll('.dashboard-prompt-scope > h3')]
                  .map((heading) => heading.textContent),
                scopeOptions,
                scope: stored.prompts[0].scope,
              };
            })()
            """
        ) as? [String: Any]
        let values = try XCTUnwrap(result)

        XCTAssertEqual(values["headings"] as? [String], ["This project · Project A", "Global"])
        XCTAssertEqual(values["scopeOptions"] as? [String], ["All projects", "This project · Project A"])
        XCTAssertEqual(
            values["scope"] as? [String: String],
            ["type": "project", "projectPath": "/tmp/project-a"]
        )
    }

    func decodeJSONObject(_ json: String) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: Data(json.utf8))
        return try XCTUnwrap(object as? [String: Any])
    }

    func testPromptDialogKeyboardBehaviorAndInMemorySave() async throws {
        let webView = try await DashboardWebTestHarness.promptLibraryWebView()

        let result = try await webView.evaluateJavaScript(
            """
            (() => {
              const launcher = document.querySelector('[data-codex-prompt-launcher]');
              launcher.focus();
              launcher.click();
              const lastButton = document.querySelector('[data-prompt-new-section]');
              lastButton.focus();
              lastButton.dispatchEvent(new KeyboardEvent('keydown', {
                key: 'Tab', bubbles: true, cancelable: true,
              }));
              const tabWrapped = document.activeElement.matches('[data-prompt-close]');

              document.querySelector('textarea[placeholder="Do anything"]').focus();
              document.activeElement.dispatchEvent(new KeyboardEvent('keydown', {
                key: 'Escape', bubbles: true, cancelable: true,
              }));
              const escapeClosedFromOutside = !document.getElementById('codex-dashboard-prompt-library-dialog');

              launcher.click();
              document.querySelector('[data-prompt-new]').click();
              document.querySelector('[name="name"]').value = 'Unsaved prompt';
              document.querySelector('[name="content"]').value = 'This must not appear as saved.';
              document.querySelector('[data-prompt-form] button[type="submit"]').click();
              return [
                tabWrapped,
                escapeClosedFromOutside,
                !document.querySelector('[data-prompt-form]'),
                document.querySelector('[data-prompt-storage-error]').hidden,
                Boolean(document.querySelector('[data-prompt-use]')),
              ];
            })()
            """
        ) as? [Any]
        let values = try XCTUnwrap(result)
        XCTAssertEqual(values[0] as? Bool, true)
        XCTAssertEqual(values[1] as? Bool, true)
        XCTAssertEqual(values[2] as? Bool, true)
        XCTAssertEqual(values[3] as? Bool, true)
        XCTAssertEqual(values[4] as? Bool, true)
    }

    func testPromptStoreIgnoresObsoleteStorageKeys() async throws {
        let webView = try await DashboardWebTestHarness.promptLibraryWebView()
        _ = try await webView.evaluateJavaScript(
            """
            (() => {
              window.__codexDashboard.destroy();
              localStorage.removeItem('codex-dashboard.prompt-library');
              localStorage.setItem('codex-dashboard.saved-prompts', JSON.stringify([{
                id: 'obsolete-prompt', name: 'Obsolete prompt', content: 'Ignore me', section: 'Old',
              }]));
              localStorage.setItem('codex-dashboard.prompt-sections', JSON.stringify(['Old']));
            })()
            """
        )

        let injection = try InjectionBundle.load()
        _ = try await webView.evaluateJavaScript(injection.mountExpression)
        let result = try await webView.evaluateJavaScript(
            """
            (() => {
              document.querySelector('[data-codex-prompt-launcher]').click();
              return [
                document.querySelectorAll('[data-prompt-use]').length,
                Boolean(document.querySelector('[data-prompt-section="Old"]')),
                localStorage.getItem('codex-dashboard.prompt-library'),
              ];
            })()
            """
        ) as? [Any]
        let values = try XCTUnwrap(result)
        XCTAssertEqual(values[0] as? Int, 0)
        XCTAssertEqual(values[1] as? Bool, false)
        XCTAssertNil(values[2] as? String)
    }

    func testSelectionPlaceholderUsesTextareaSelectionCapturedBeforeDialogOpens() async throws {
        let webView = try await DashboardWebTestHarness.promptLibraryWebView()
        let result = try await webView.evaluateJavaScript(
            """
            (() => {
              const composer = document.querySelector('textarea[placeholder="Do anything"]');
              composer.value = 'alpha beta gamma';
              composer.focus();
              composer.setSelectionRange(6, 10);
              document.querySelector('[data-codex-prompt-launcher]').click();
              document.querySelector('[data-prompt-new]').click();
              document.querySelector('[name="name"]').value = 'Use selection';
              document.querySelector('[name="content"]').value = 'Selected: {{selection}}';
              document.querySelector('[data-prompt-form] button[type="submit"]').click();
              document.querySelector('[data-prompt-use]').click();
              return composer.value;
            })()
            """
        ) as? String

        XCTAssertEqual(result, "alpha Selected: beta gamma")
    }

    func testLibraryRefreshDoesNotReplaceAnActivePromptEdit() async throws {
        let webView = try await DashboardWebTestHarness.promptLibraryWebView()
        let result = try await webView.evaluateJavaScript(
            """
            (() => {
              const library = {
                version: \(PromptLibrarySchema.currentVersion),
                prompts: [{
                  id: 'prompt-1',
                  name: 'Original name',
                  content: 'Original content',
                  scope: { type: 'global' },
                }],
                sections: [],
              };
              window.__codexDashboard.applyPromptLibrary(library);
              document.querySelector('[data-codex-prompt-launcher]').click();
              document.querySelector('[data-prompt-edit="prompt-1"]').click();

              const name = document.querySelector('[name="name"]');
              const content = document.querySelector('[name="content"]');
              name.value = 'Draft name';
              content.value = 'Draft content being edited';
              content.focus();
              content.setSelectionRange(6, 13);

              window.__codexDashboard.applyPromptLibrary({
                ...library,
                sections: ['New external section'],
              });

              return {
                sameNameElement: name === document.querySelector('[name="name"]'),
                sameContentElement: content === document.querySelector('[name="content"]'),
                name: name.value,
                content: content.value,
                selection: [content.selectionStart, content.selectionEnd],
                contentFocused: document.activeElement === content,
              };
            })()
            """
        ) as? [String: Any]
        let values = try XCTUnwrap(result)

        XCTAssertEqual(values["sameNameElement"] as? Bool, true)
        XCTAssertEqual(values["sameContentElement"] as? Bool, true)
        XCTAssertEqual(values["name"] as? String, "Draft name")
        XCTAssertEqual(values["content"] as? String, "Draft content being edited")
        XCTAssertEqual(values["selection"] as? [Int], [6, 13])
        XCTAssertEqual(values["contentFocused"] as? Bool, true)
    }

}
