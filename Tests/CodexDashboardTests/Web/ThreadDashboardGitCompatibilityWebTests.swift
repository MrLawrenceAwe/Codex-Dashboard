import Foundation
import XCTest

@testable import CodexDashboard

@MainActor
extension ThreadDashboardWebTests {
    func testCommitCompatibilityProbeVerifiesFullControlPathAndRestoresUI() async throws {
        let webView = try await DashboardWebTestHarness.mountedWebView(html:
            """
            <!doctype html><html><head><meta charset="utf-8"></head><body>
              <button type="button" aria-label="Toggle side panel">Panel</button>
              <script>
                document.documentElement.dataset.panelClicks = '0';
                document.documentElement.dataset.environmentClicks = '0';
                document.documentElement.dataset.commitClicks = '0';
                const panel = document.querySelector('[aria-label="Toggle side panel"]');
                panel.addEventListener('click', () => {
                  document.documentElement.dataset.panelClicks = String(
                    Number(document.documentElement.dataset.panelClicks) + 1
                  );
                  const existing = document.querySelector('[data-test-environment]');
                  if (existing) {
                    existing.remove();
                    document.querySelector('[data-test-native-commit]')?.remove();
                    return;
                  }
                  const environment = document.createElement('button');
                  environment.type = 'button';
                  environment.dataset.testEnvironment = '';
                  environment.textContent = 'Environment';
                  environment.setAttribute('aria-expanded', 'false');
                  environment.addEventListener('click', () => {
                    document.documentElement.dataset.environmentClicks = String(
                      Number(document.documentElement.dataset.environmentClicks) + 1
                    );
                    const expanded = environment.getAttribute('aria-expanded') === 'true';
                    environment.setAttribute('aria-expanded', String(!expanded));
                    if (expanded) {
                      document.querySelector('[data-test-native-commit]')?.remove();
                      return;
                    }
                    const commit = document.createElement('button');
                    commit.type = 'button';
                    commit.dataset.slot = 'thread-summary-panel-item-button';
                    commit.dataset.testNativeCommit = '';
                    commit.textContent = 'Commit or push';
                    commit.addEventListener('click', () => {
                      document.documentElement.dataset.commitClicks = String(
                        Number(document.documentElement.dataset.commitClicks) + 1
                      );
                    });
                    document.body.append(commit);
                  });
                  document.body.append(environment);
                });
              </script>
            </body></html>
            """
        )
        let contractSource = try InjectionBundle.loadRendererContractSource()

        _ = try await webView.evaluateJavaScript(
            """
            (() => {
              \(contractSource)
              codexUIContracts.probeCommitOrPushControls(500).then((result) => {
                document.documentElement.dataset.probeResult = String(result);
              });
            })()
            """
        )
        try await DashboardWebTestHarness.waitForJavaScript(
            "document.documentElement.dataset.probeResult !== undefined",
            in: webView
        )
        let state = try await webView.evaluateJavaScript(
            """
            [
              document.documentElement.dataset.probeResult,
              document.documentElement.dataset.panelClicks,
              document.documentElement.dataset.environmentClicks,
              document.documentElement.dataset.commitClicks,
              Boolean(document.querySelector('[data-test-environment]')),
              Boolean(document.querySelector('[data-test-native-commit]')),
            ]
            """
        ) as? [Any]

        XCTAssertEqual(try XCTUnwrap(state) as? [AnyHashable], ["true", "2", "2", "0", false, false])
    }

    func testCommitCompatibilityProbeRejectsIncompleteControlPathAndRestoresUI() async throws {
        let webView = try await DashboardWebTestHarness.mountedWebView(html:
            """
            <!doctype html><html><head><meta charset="utf-8"></head><body>
              <button type="button" aria-label="Toggle side panel">Panel</button>
              <script>
                document.documentElement.dataset.panelClicks = '0';
                const panel = document.querySelector('[aria-label="Toggle side panel"]');
                panel.addEventListener('click', () => {
                  document.documentElement.dataset.panelClicks = String(
                    Number(document.documentElement.dataset.panelClicks) + 1
                  );
                });
              </script>
            </body></html>
            """
        )
        let contractSource = try InjectionBundle.loadRendererContractSource()

        _ = try await webView.evaluateJavaScript(
            """
            (() => {
              \(contractSource)
              codexUIContracts.probeCommitOrPushControls(100).then((result) => {
                document.documentElement.dataset.probeResult = String(result);
              });
            })()
            """
        )
        try await DashboardWebTestHarness.waitForJavaScript(
            "document.documentElement.dataset.probeResult !== undefined",
            in: webView
        )
        let state = try await webView.evaluateJavaScript(
            """
            [
              document.documentElement.dataset.probeResult,
              document.documentElement.dataset.panelClicks,
            ]
            """
        ) as? [Any]

        XCTAssertEqual(try XCTUnwrap(state) as? [AnyHashable], ["false", "2"])
    }

}
