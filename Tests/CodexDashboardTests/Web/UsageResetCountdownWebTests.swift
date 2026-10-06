import AppKit
import WebKit
import XCTest

@testable import CodexDashboard

@MainActor
extension ChatOverviewWebTests {
    func testUsageResetNoticeFitsNarrowAndWideLightAndDarkWindows() async throws {
        for (width, background, theme) in [(360, "#171817", "dark"), (900, "#f5f5f3", "light")] {
            let webView = try await DashboardWebTestHarness.mountedWebView(html: """
            <!doctype html><html><head><style>
              body { margin:0; background:\(background); font-family:system-ui; }
              main { padding:20px; color:#888; }
            </style></head><body><main>Codex</main></body></html>
            """)
            webView.frame = NSRect(x: 0, y: 0, width: width, height: 600)
            let result = try await webView.evaluateJavaScript("""
            (() => {
              window.__codexDashboard.applyAccountPopoverSnapshot({
                accounts: [], activeAccountID: null, statusMessage: null, isBusy: false,
                usageBlockage: { windows: [
                  { label: '5-hour', resetsAtMilliseconds: Date.now() + 7200000 },
                  { label: 'Weekly', resetsAtMilliseconds: Date.now() + 180000000 },
                ], isStale: false },
              });
              const notice = document.querySelector('#codex-usage-blockage');
              const rect = notice.getBoundingClientRect();
              return [rect.left >= 0 && rect.right <= innerWidth && rect.bottom <= innerHeight,
                notice.scrollWidth <= notice.clientWidth, notice.classList.contains('is-light')];
            })()
            """) as? [Bool]
            XCTAssertEqual(result, [true, true, theme == "light"])
            if ProcessInfo.processInfo.environment["CODEX_RESET_PREVIEW"] == "1" {
                let image = try await webView.takeSnapshot(configuration: nil)
                let png = try XCTUnwrap(image.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0) }?
                    .representation(using: .png, properties: [:]))
                try png.write(to: URL(fileURLWithPath: "/tmp/codex-usage-reset-\(theme).png"))
            }
        }
    }

    func testUsageNoticeCollapseAndDragSurviveRefreshAndStayWithinWindow() async throws {
        let webView = try await DashboardWebTestHarness.mountedWebView(html: DashboardWebTestHarness.basicHostHTML)
        webView.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        let result = try await webView.evaluateJavaScript("""
        (() => {
          const snapshot = {
            accounts: [], activeAccountID: null, statusMessage: null, isBusy: false,
            usageBlockage: { windows: [{ label: '5-hour', resetsAtMilliseconds: Date.now() + 7200000 }], isStale: false },
          };
          const apply = () => window.__codexDashboard.applyAccountPopoverSnapshot(snapshot);
          apply();
          const notice = document.querySelector('#codex-usage-blockage');
          const toggle = notice.querySelector('[data-reset-toggle]');
          const details = notice.querySelector('#codex-usage-reset-details');
          const expandedHeight = notice.getBoundingClientRect().height;
          toggle.focus();
          toggle.click();
          apply();
          const collapsed = details.hidden && toggle.getAttribute('aria-expanded') === 'false'
            && notice.getBoundingClientRect().height < expandedHeight
            && document.activeElement === toggle
            && notice.querySelector('[data-reset-countdown]').textContent.includes('Available in');
          snapshot.isBusy = true;
          apply();
          const busyControls = notice.querySelector('[data-reset-refresh]').disabled && !toggle.disabled;
          toggle.click();
          const expanded = !details.hidden && toggle.getAttribute('aria-expanded') === 'true';
          const header = notice.querySelector('header');
          // Synthetic pointer events have no native active pointer to capture.
          header.setPointerCapture = () => {};
          const start = notice.getBoundingClientRect();
          header.dispatchEvent(new PointerEvent('pointerdown', {
            pointerId: 1, button: 0, clientX: start.left + 10, clientY: start.top + 10,
          }));
          header.dispatchEvent(new PointerEvent('pointermove', { pointerId: 1, clientX: 110, clientY: 130 }));
          header.dispatchEvent(new PointerEvent('pointerup', { pointerId: 1 }));
          apply();
          const moved = notice.getBoundingClientRect();
          const retained = moved.left === 100 && moved.top === 120;
          header.dispatchEvent(new PointerEvent('pointerdown', {
            pointerId: 2, button: 0, clientX: moved.left + 10, clientY: moved.top + 10,
          }));
          header.dispatchEvent(new PointerEvent('pointermove', { pointerId: 2, clientX: 10000, clientY: 10000 }));
          header.dispatchEvent(new PointerEvent('pointercancel', { pointerId: 2 }));
          const clamped = notice.getBoundingClientRect();
          const inside = clamped.right <= innerWidth - 12 && clamped.bottom <= innerHeight - 12
            && !notice.classList.contains('is-dragging');
          // Expanding at the bottom repositions the larger card above the edge.
          toggle.click();
          const compact = notice.getBoundingClientRect();
          header.dispatchEvent(new PointerEvent('pointerdown', {
            pointerId: 3, button: 0, clientX: compact.left + 10, clientY: compact.top + 10,
          }));
          header.dispatchEvent(new PointerEvent('pointermove', { pointerId: 3, clientX: 10000, clientY: 10000 }));
          header.dispatchEvent(new PointerEvent('pointerup', { pointerId: 3 }));
          toggle.click();
          const expandedInside = notice.getBoundingClientRect().bottom <= innerHeight - 12;
          window.__codexDashboard.destroy();
          window.dispatchEvent(new Event('resize'));
          return [collapsed, busyControls, expanded, retained, inside, expandedInside,
            !document.querySelector('#codex-usage-blockage')];
        })()
        """) as? [Bool]
        XCTAssertEqual(result, Array(repeating: true, count: 7))
    }

    func testUsageResetNoticeSelectsBlockingDeadlineAndClearsOnRecovery() async throws {
        let webView = try await DashboardWebTestHarness.mountedWebView(html: DashboardWebTestHarness.basicHostHTML)
        let result = try await webView.evaluateJavaScript("""
        (() => {
          const now = Date.now();
          const apply = (windows, isStale = false) => window.__codexDashboard.applyAccountPopoverSnapshot({
            accounts: [], activeAccountID: null, statusMessage: null, isBusy: false,
            usageBlockage: windows ? { windows, isStale } : null,
          });
          const windowFor = (label, offset) => ({ label, resetsAtMilliseconds: offset === null ? null : now + offset });
          const text = () => document.querySelector('#codex-usage-blockage').textContent;
          apply([windowFor('5-hour', 7200000)]);
          const fiveHour = text().includes('Available in 2h') && text().includes('5-hour: 0%');
          const fontSize = parseFloat(getComputedStyle(document.querySelector('[data-reset-countdown]')).fontSize);
          apply([windowFor('Weekly', 172800000)]);
          const weekly = text().includes('Available in 2d') && text().includes('Weekly: 0%');
          apply([windowFor('5-hour', 7200000), windowFor('Weekly', 172800000)]);
          const both = text().includes('Available in 2d') && text().includes('5-hour: 0%');
          apply([windowFor('5-hour', 172800000), windowFor('Weekly', 7200000)]);
          const laterFiveHour = text().includes('Available in 2d');
          apply([windowFor('Weekly', null)]);
          const unknown = text().includes('Reset time unavailable') && !text().includes('Available in');
          apply([windowFor('5-hour', -1000)]);
          const due = text().includes('awaiting usage update') && !text().includes('Available in');
          apply([windowFor('Weekly', 172800000)], true);
          const stale = text().includes('Last known') && text().includes('Usage may be stale');
          document.querySelector('#codex-usage-blockage [data-reset-refresh]').click();
          const queued = JSON.parse(window.__codexDashboard.takeQueuedAccountPopoverAction());
          apply(null);
          const recovered = !document.querySelector('#codex-usage-blockage');
          apply([windowFor('Weekly', 172800000)]);
          window.__codexDashboard.destroy();
          return [fiveHour, fontSize >= 24, weekly, both, laterFiveHour, unknown, due, stale,
            queued.kind === 'updateUsage' && queued.accountID === null, recovered,
            !document.querySelector('#codex-usage-blockage')];
        })()
        """) as? [Bool]
        XCTAssertEqual(result, Array(repeating: true, count: 11))
    }

    func testUsageResetCountdownTicksWithoutReplacingFocusedRefreshButton() async throws {
        let webView = try await DashboardWebTestHarness.mountedWebView(html: DashboardWebTestHarness.basicHostHTML)
        let result = try await webView.callAsyncJavaScript("""
        const originalNow = Date.now;
        let now = 2000000000000;
        Date.now = () => now;
        try {
          window.__codexDashboard.applyAccountPopoverSnapshot({
            accounts: [], activeAccountID: null, statusMessage: null, isBusy: false,
            usageBlockage: { windows: [{ label: '5-hour', resetsAtMilliseconds: now + 65000 }], isStale: false },
          });
          const button = document.querySelector('#codex-usage-blockage [data-reset-refresh]');
          button.focus();
          const before = document.querySelector('[data-reset-countdown]').textContent;
          now += 10000;
          await new Promise(resolve => setTimeout(resolve, 1100));
          const after = document.querySelector('[data-reset-countdown]').textContent;
          return [before, after, document.activeElement === button];
        } finally { Date.now = originalNow; }
        """, contentWorld: .page) as? [Any]
        let values = try XCTUnwrap(result)
        XCTAssertEqual(values[0] as? String, "Available in 1m 5s")
        XCTAssertEqual(values[1] as? String, "Available in 55s")
        XCTAssertEqual(values[2] as? Bool, true)
    }
}
