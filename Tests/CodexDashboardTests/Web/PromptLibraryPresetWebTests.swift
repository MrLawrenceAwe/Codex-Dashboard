import Foundation
import XCTest

@testable import CodexDashboard

@MainActor
extension PromptLibraryWebTests {
    func testUnknownModelIdentifierIsEscapedInThePresetSelector() async throws {
        let webView = try await DashboardWebTestHarness.promptLibraryWebView()
        let modelIdentifier = #"\"></option></select><img src=x onerror=\"window.__modelOptionXSS = true\">"#
        let library = PromptLibraryDocument(
            version: 3,
            prompts: [SavedPrompt(
                id: "unknown-model",
                name: "Unknown model",
                content: "Prompt",
                section: nil,
                scope: SavedPromptScope(type: "global", projectPath: nil),
                preset: SavedPromptPreset(
                    model: modelIdentifier,
                    reasoningEffort: nil,
                    speed: nil
                ),
                usePreset: true
            )],
            sections: []
        )
        let data = try JSONEncoder().encode(library)
        let payload = try XCTUnwrap(String(data: data, encoding: .utf8))

        let result = try await webView.evaluateJavaScript(
            """
            (() => {
              window.__codexDashboard.applyPromptLibrary(\(payload));
              document.querySelector('[data-codex-prompt-launcher]').click();
              document.querySelector('[data-prompt-edit="unknown-model"]').click();
              const option = document.querySelector('[name="presetModel"] option:checked');
              return JSON.stringify({
                value: option.value,
                label: option.textContent,
                injected: window.__modelOptionXSS === true,
                imageCount: document.querySelectorAll('img[src="x"]').length,
              });
            })()
            """
        ) as? String
        let values = try decodeJSONObject(try XCTUnwrap(result))

        XCTAssertEqual(values["value"] as? String, modelIdentifier)
        XCTAssertEqual(values["label"] as? String, "Saved model · \(modelIdentifier)")
        XCTAssertEqual(values["injected"] as? Bool, false)
        XCTAssertEqual(values["imageCount"] as? Int, 0)
    }

    func testPromptPresetIsStoredDisplayedAndAppliedBeforeInsertion() async throws {
        try await checkPresetApplication(speedFlyout: false)
    }

    func testPromptPresetUsesAssociatedSpeedFlyout() async throws {
        try await checkPresetApplication(speedFlyout: true, model: "gpt-6-sol", label: "GPT-6 Sol")
    }

    func testLockedModelDoesNotOpenAccessOptionsOrInsertPrompt() async throws {
        try await checkPresetApplication(speedFlyout: false, locked: true)
    }

    private func checkPresetApplication(
        speedFlyout: Bool,
        locked: Bool = false,
        model: String = "gpt-6-luna",
        label: String = "GPT-6 Luna"
    ) async throws {
        let webView = try await DashboardWebTestHarness.promptLibraryWebView()
        _ = try await webView.evaluateJavaScript(
            """
            void (async () => {
              const shell = document.querySelector('.composer-shell');
              const trigger = document.createElement('button');
              trigger.dataset.codexIntelligenceTrigger = 'true';
              trigger.setAttribute('aria-expanded', 'false');
              trigger.dataset.selectedReasoningEffort = 'medium';
              trigger.textContent = 'Current model';
              shell.append(trigger);
              const applied = [];
              const promptDialogStates = [];
              const triggerDialogStates = [];
              const removeMenus = () => {
                document.querySelectorAll('[role="menu"]').forEach((menu) => menu.remove());
                trigger.setAttribute('aria-expanded', 'false');
              };
              document.body.addEventListener('click', (event) => {
                if (event.target === document.body) removeMenus();
              });
              trigger.addEventListener('click', () => {
                triggerDialogStates.push(Boolean(document.getElementById(
                  'codex-dashboard-prompt-library-dialog'
                )));
                if (document.getElementById('codex-dashboard-prompt-library-dialog')) return;
                if (trigger.getAttribute('aria-expanded') === 'true') return;
                trigger.setAttribute('aria-expanded', 'true');
                const menu = document.createElement('div');
                menu.setAttribute('role', 'menu');
                menu.dataset.modelPickerView = 'simple';
                const compact = document.createElement('div');
                const models = document.createElement('div');
                models.inert = true;
                models.setAttribute('aria-hidden', 'true');
                const showView = (view) => {
                  menu.dataset.modelPickerView = view;
                  compact.inert = view !== 'simple';
                  models.inert = view !== 'advanced';
                  compact.setAttribute('aria-hidden', String(compact.inert));
                  models.setAttribute('aria-hidden', String(models.inert));
                };
                const record = (value) => {
                  applied.push(value);
                  promptDialogStates.push(Boolean(document.getElementById(
                    'codex-dashboard-prompt-library-dialog'
                  )));
                };
                const viewToggle = document.createElement('div');
                viewToggle.dataset.modelPickerViewToggle = 'true';
                viewToggle.setAttribute('role', 'menuitem');
                viewToggle.textContent = 'Select model';
                viewToggle.addEventListener('click', () => showView('advanced'));
                compact.append(viewToggle);
                ['GPT-6 Astra', 'GPT-6 Sol', 'GPT-6 Luna', 'GPT-5.6 Sol', 'GPT-5.6 Terra', 'GPT-5.6 Luna'].forEach((label) => {
                  const option = document.createElement('div');
                  option.setAttribute('role', 'menuitemradio');
                  const name = document.createElement('span');
                  name.textContent = label;
                  option.append(name, ' Model description');
                  if (\(locked) && label === 'GPT-6 Luna') {
                    const description = document.createElement('span');
                    description.id = 'locked-model-description';
                    description.textContent = 'Locked, opens access options';
                    menu.append(description);
                    option.setAttribute('aria-describedby', description.id);
                  }
                  option.addEventListener('click', () => {
                    record(`Model:${label}`);
                    showView('simple');
                  });
                  models.append(option);
                });
                const slider = document.createElement('div');
                slider.dataset.reasoningSlider = 'true';
                slider.setAttribute('role', 'menuitem');
                slider.textContent = 'Power';
                slider.addEventListener('keydown', (event) => {
                  if (event.key !== 'ArrowLeft') return;
                  setTimeout(() => {
                    trigger.dataset.selectedReasoningEffort = 'low';
                    record('Effort:Light');
                  }, 50);
                });
                const speed = document.createElement('div');
                speed.setAttribute('role', 'menuitemcheckbox');
                speed.setAttribute('aria-label', 'Enable fast mode');
                speed.setAttribute('aria-checked', 'false');
                speed.textContent = 'Fast mode';
                speed.addEventListener('click', () => {
                  speed.setAttribute('aria-checked', 'true');
                  speed.setAttribute('aria-label', 'Enable standard mode');
                  record('Speed:Fast');
                });
                compact.append(slider, speed);
                if (\(speedFlyout)) {
                  speed.remove();
                  const flyout = document.createElement('div');
                  flyout.setAttribute('role', 'menuitem');
                  flyout.setAttribute('aria-label', 'Speed Standard');
                  flyout.setAttribute('aria-controls', 'speed-options');
                  flyout.textContent = 'Speed';
                  flyout.addEventListener('pointermove', () => {
                    const submenu = document.createElement('div');
                    submenu.id = 'speed-options';
                    submenu.setAttribute('role', 'menu');
                    ['Fastest', 'Fast'].forEach((label) => {
                      const option = document.createElement('div');
                      option.setAttribute('role', 'menuitem');
                      const name = document.createElement('div');
                      name.textContent = label;
                      option.append(name, ' More usage');
                      option.addEventListener('click', () => record(`Speed:${label}`));
                      submenu.append(option);
                    });
                    document.body.append(submenu);
                    // An unrelated portal must not be mistaken for the speed flyout.
                    const unrelated = document.createElement('div');
                    unrelated.setAttribute('role', 'menu');
                    unrelated.textContent = 'Unrelated menu';
                    document.body.append(unrelated);
                    flyout.setAttribute('aria-expanded', 'true');
                  });
                  compact.append(flyout);
                }
                menu.append(compact, models);
                document.body.append(menu);
              });

              document.querySelector('[data-codex-prompt-launcher]').click();
              document.querySelector('[data-prompt-new]').click();
              const presetDefaults = {
                modelValue: document.querySelector('[name="presetModel"]').value,
                effortValue: document.querySelector('[name="presetReasoningEffort"]').value,
                speedValue: document.querySelector('[name="presetSpeed"]').value,
                hasPresetChecked: document.querySelector('[name="hasPreset"]').checked,
                presetFieldsDisabled: document.querySelector('[data-prompt-preset-fields]').disabled,
              };
              document.querySelector('[name="name"]').value = 'Fast review';
              document.querySelector('[name="content"]').value = 'Review this change';
              document.querySelector('[name="hasPreset"]').click();
              document.querySelector('[name="presetModel"]').value = '\(model)';
              document.querySelector('[name="presetReasoningEffort"]').value = 'light';
              document.querySelector('[name="presetSpeed"]').value = 'fast';
              document.querySelector('[data-prompt-form] button[type="submit"]').click();
              const summary = [...document.querySelectorAll('.dashboard-prompt-preset-summary em')]
                .map((item) => item.textContent);
              const stored = JSON.parse(window.__codexDashboard.exportPromptLibrary());
              const usePresetCheckbox = document.querySelector('[data-prompt-use-preset]');
              const usesPresetByDefault = usePresetCheckbox.checked;
              usePresetCheckbox.click();
              const storedWithPresetEnabled = JSON.parse(window.__codexDashboard.exportPromptLibrary());
              document.querySelector('[data-prompt-use]').click();
              const deadline = performance.now() + 4000;
              while (document.querySelector('textarea').value !== 'Review this change'
                && performance.now() < deadline) {
                if (document.querySelector('[data-prompt-storage-error]:not([hidden])')) break;
                await new Promise((resolve) => setTimeout(resolve, 20));
              }
              window.__promptPresetTestResult = {
                version: stored.version,
                presetDefaults,
                preset: stored.prompts[0].preset,
                usesPresetByDefault,
                usesPresetAfterToggle: storedWithPresetEnabled.prompts[0].usePreset,
                summary,
                applied,
                promptDialogStates,
                triggerDialogStates,
                content: document.querySelector('textarea').value,
                dialogClosed: !document.getElementById('codex-dashboard-prompt-library-dialog'),
              };
            })();
            true
            """
        )
        try await DashboardWebTestHarness.waitForJavaScript(
            "Boolean(window.__promptPresetTestResult)",
            in: webView,
            timeout: .seconds(3)
        )
        let result = try await webView.evaluateJavaScript(
            "JSON.stringify(window.__promptPresetTestResult)"
        ) as? String
        let values = try decodeJSONObject(try XCTUnwrap(result))
        let presetDefaults = try XCTUnwrap(values["presetDefaults"] as? [String: Any])

        if locked {
            XCTAssertEqual(values["applied"] as? [String], [])
            XCTAssertEqual(values["content"] as? String, "")
            XCTAssertEqual(values["dialogClosed"] as? Bool, false)
            return
        }

        XCTAssertEqual(values["version"] as? Int, 3)
        XCTAssertEqual(presetDefaults["modelValue"] as? String, "gpt-6-astra")
        XCTAssertEqual(presetDefaults["effortValue"] as? String, "medium")
        XCTAssertEqual(presetDefaults["speedValue"] as? String, "standard")
        XCTAssertEqual(presetDefaults["hasPresetChecked"] as? Bool, false)
        XCTAssertEqual(presetDefaults["presetFieldsDisabled"] as? Bool, true)
        XCTAssertEqual(
            values["preset"] as? [String: String],
            ["model": model, "reasoningEffort": "light", "speed": "fast"]
        )
        XCTAssertEqual(values["summary"] as? [String], [label, "Light", "Fast"])
        XCTAssertEqual(values["usesPresetByDefault"] as? Bool, false)
        XCTAssertEqual(values["usesPresetAfterToggle"] as? Bool, true)
        XCTAssertEqual(
            values["applied"] as? [String],
            ["Model:\(label)", "Effort:Light", "Speed:Fast"]
        )
        XCTAssertEqual(values["promptDialogStates"] as? [Bool], [false, false, false])
        XCTAssertEqual(values["triggerDialogStates"] as? [Bool], [false])
        XCTAssertEqual(values["content"] as? String, "Review this change")
        XCTAssertEqual(values["dialogClosed"] as? Bool, true)
    }

    func testUnknownSavedModelRemainsVisibleAndRoundTrips() async throws {
        let webView = try await DashboardWebTestHarness.promptLibraryWebView()
        let result = try await webView.evaluateJavaScript(
            """
            (() => {
              window.__codexDashboard.applyPromptLibrary({
                version: 3,
                sections: ['General'],
                prompts: [{
                  id: 'future-model',
                  name: 'Future model prompt',
                  content: 'Keep the model identifier',
                  section: 'General',
                  scope: { type: 'global' },
                  preset: { model: 'gpt-7-preview', reasoningEffort: 'high', speed: 'fast' },
                  usePreset: true,
                }],
              });
              document.querySelector('[data-codex-prompt-launcher]').click();
              const summary = [...document.querySelectorAll('.dashboard-prompt-preset-summary em')]
                .map((item) => item.textContent);
              document.querySelector('[data-prompt-edit]').click();
              const selectedLabel = document.querySelector('[name="presetModel"]')
                .selectedOptions[0].textContent;
              document.querySelector('[data-prompt-form] button[type="submit"]').click();
              const stored = JSON.parse(window.__codexDashboard.exportPromptLibrary());
              return [summary, selectedLabel, stored.prompts[0].preset.model];
            })()
            """
        ) as? [Any]

        let values = try XCTUnwrap(result)
        XCTAssertEqual(values[0] as? [String], ["Saved model · gpt-7-preview", "High", "Fast"])
        XCTAssertEqual(values[1] as? String, "Saved model · gpt-7-preview")
        XCTAssertEqual(values[2] as? String, "gpt-7-preview")
    }

    func testNewPromptCanBeSavedWithoutModelPreset() async throws {
        let webView = try await DashboardWebTestHarness.promptLibraryWebView()
        let result = try await webView.evaluateJavaScript(
            """
            (() => {
              document.querySelector('[data-codex-prompt-launcher]').click();
              document.querySelector('[data-prompt-new]').click();
              const fields = document.querySelector('[data-prompt-preset-fields]');
              const defaults = {
                hasPreset: document.querySelector('[name="hasPreset"]').checked,
                fieldsDisabled: fields.disabled,
              };
              document.querySelector('[name="name"]').value = 'Plain prompt';
              document.querySelector('[name="content"]').value = 'Insert without changing my model';
              document.querySelector('[data-prompt-form] button[type="submit"]').click();
              const stored = JSON.parse(window.__codexDashboard.exportPromptLibrary());
              const row = document.querySelector('[data-prompt-use]');
              return JSON.stringify({
                defaults,
                storedPrompt: stored.prompts[0],
                hasPresetSummary: Boolean(document.querySelector('.dashboard-prompt-preset-summary')),
                usePresetDisabled: row.parentElement.querySelector('[data-prompt-use-preset]').disabled,
              });
            })()
            """
        ) as? String
        let values = try decodeJSONObject(try XCTUnwrap(result))
        let defaults = try XCTUnwrap(values["defaults"] as? [String: Any])
        let storedPrompt = try XCTUnwrap(values["storedPrompt"] as? [String: Any])

        XCTAssertEqual(defaults["hasPreset"] as? Bool, false)
        XCTAssertEqual(defaults["fieldsDisabled"] as? Bool, true)
        XCTAssertNil(storedPrompt["preset"])
        XCTAssertNil(storedPrompt["usePreset"])
        XCTAssertEqual(values["hasPresetSummary"] as? Bool, false)
        XCTAssertEqual(values["usePresetDisabled"] as? Bool, true)
    }

    func testFailedPromptPresetRestoresLibraryWithoutInsertingPrompt() async throws {
        let webView = try await DashboardWebTestHarness.promptLibraryWebView()
        _ = try await webView.evaluateJavaScript(
            """
            void (async () => {
              const trigger = document.createElement('button');
              trigger.dataset.codexIntelligenceTrigger = 'true';
              trigger.setAttribute('aria-expanded', 'false');
              trigger.textContent = 'Current model';
              document.querySelector('.composer-shell').append(trigger);

              document.querySelector('[data-codex-prompt-launcher]').click();
              document.querySelector('[data-prompt-new]').click();
              document.querySelector('[name="name"]').value = 'Unavailable preset';
              document.querySelector('[name="content"]').value = 'Do not insert this';
              document.querySelector('[name="hasPreset"]').click();
              document.querySelector('[data-prompt-form] button[type="submit"]').click();
              document.querySelector('[data-prompt-use-preset]').click();
              document.querySelector('[data-prompt-use]').click();

              const deadline = performance.now() + 4000;
              while (performance.now() < deadline) {
                const error = document.querySelector('[data-prompt-storage-error]');
                if (error && !error.hidden) break;
                await new Promise((resolve) => setTimeout(resolve, 20));
              }
              const error = document.querySelector('[data-prompt-storage-error]');
              window.__failedPromptPresetResult = {
                dialogOpen: Boolean(document.getElementById(
                  'codex-dashboard-prompt-library-dialog'
                )),
                error: error && !error.hidden ? error.textContent : null,
                content: document.querySelector('textarea').value,
              };
            })();
            true
            """
        )
        try await DashboardWebTestHarness.waitForJavaScript(
            "Boolean(window.__failedPromptPresetResult)",
            in: webView,
            timeout: .seconds(5)
        )
        let result = try await webView.evaluateJavaScript(
            "JSON.stringify(window.__failedPromptPresetResult)"
        ) as? String
        let values = try decodeJSONObject(try XCTUnwrap(result))

        XCTAssertEqual(values["dialogOpen"] as? Bool, true)
        XCTAssertEqual(
            values["error"] as? String,
            "Could not apply this prompt’s composer preset. The prompt was not inserted."
        )
        XCTAssertEqual(values["content"] as? String, "")
    }

}
