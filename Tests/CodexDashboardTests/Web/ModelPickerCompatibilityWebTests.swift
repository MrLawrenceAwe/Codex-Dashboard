import Foundation
import WebKit
import XCTest

@testable import CodexDashboard

@MainActor
final class ModelPickerCompatibilityWebTests: SerializedDashboardWebTestCase {
    func testModelPickerProbeVerifiesControlsAndRestoresTheClosedMenu() async throws {
        let webView = try await DashboardWebTestHarness.promptLibraryWebView()
        let contractSource = try InjectionBundle.loadRendererContractSource()
        _ = try await webView.evaluateJavaScript(
            """
            (() => {
              \(contractSource)
              const shell = document.querySelector('.composer-shell');
              const trigger = document.createElement('button');
              trigger.dataset.codexIntelligenceTrigger = 'true';
              trigger.dataset.selectedReasoningEffort = 'medium';
              trigger.setAttribute('aria-expanded', 'false');
              trigger.addEventListener('click', () => {
                if (trigger.getAttribute('aria-expanded') === 'true') return;
                trigger.setAttribute('aria-expanded', 'true');
                const menu = document.createElement('div');
                menu.dataset.modelPickerView = 'simple';
                const viewToggle = document.createElement('button');
                viewToggle.dataset.modelPickerViewToggle = 'true';
                const slider = document.createElement('div');
                slider.dataset.reasoningSlider = 'true';
                menu.append(viewToggle, slider);
                document.body.append(menu);
              });
              shell.append(trigger);
              document.body.addEventListener('click', (event) => {
                if (event.target === document.body) {
                  trigger.setAttribute('aria-expanded', 'false');
                  document.querySelector('[data-model-picker-view]')?.remove();
                }
              });
              codexUIContracts.probeModelPickerControls(300).then((isCompatible) => {
                window.__modelPickerProbeResult = JSON.stringify([
                  isCompatible,
                  trigger.getAttribute('aria-expanded'),
                  document.querySelector('[data-model-picker-view]') === null,
                ]);
              });
              return true;
            })()
            """
        )
        try await DashboardWebTestHarness.waitForJavaScript(
            "typeof window.__modelPickerProbeResult === 'string'",
            in: webView
        )
        let serialized = try await webView.evaluateJavaScript(
            "window.__modelPickerProbeResult"
        ) as? String
        let result = try JSONSerialization.jsonObject(
            with: Data(try XCTUnwrap(serialized).utf8)
        ) as? [Any]

        XCTAssertEqual(result?[0] as? Bool, true)
        XCTAssertEqual(result?[1] as? String, "false")
        XCTAssertEqual(result?[2] as? Bool, true)
    }
}
