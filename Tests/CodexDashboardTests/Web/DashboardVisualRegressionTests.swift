import AppKit
import WebKit
import XCTest

@testable import CodexDashboard

@MainActor
final class DashboardVisualRegressionTests: SerializedDashboardWebTestCase {
    private struct Scenario {
        let name: String
        let size: CGSize
        let lightMode: Bool
    }

    func testDashboardVisualBaselines() async throws {
        let scenarios = [
            Scenario(name: "wide-dark", size: CGSize(width: 1280, height: 720), lightMode: false),
            Scenario(name: "medium-light", size: CGSize(width: 960, height: 720), lightMode: true),
            Scenario(name: "narrow-dark", size: CGSize(width: 720, height: 720), lightMode: false),
        ]

        for scenario in scenarios {
            let png = try await render(scenario)
            try assertMatchesBaseline(png, named: scenario.name)
        }
    }

    private func render(_ scenario: Scenario) async throws -> Data {
        let scheme = scenario.lightMode ? "light" : "dark"
        let background = scenario.lightMode ? "#f5f5f3" : "#171817"
        let text = scenario.lightMode ? "#222422" : "#eeeeec"
        let webView = DashboardWebTestHarness.makeWebView()
        webView.frame = NSRect(origin: .zero, size: scenario.size)
        webView.loadHTMLString(
            """
            <!doctype html><html><head><meta charset="utf-8"><style>
              :root { color-scheme: \(scheme); --app-color-background-surface: \(background); --app-color-text-foreground: \(text); }
              * { box-sizing: border-box; }
              body { margin: 0; background: \(background); color: \(text); font-family: -apple-system, sans-serif; }
              .host { display: grid; grid-template-columns: 240px 1fr; min-height: 100vh; }
              aside { padding: 24px 16px; border-right: 1px solid rgba(127,127,127,.2); }
              aside button { display: block; width: 100%; margin: 8px 0; padding: 9px; border: 0; border-radius: 8px; background: transparent; color: inherit; text-align: left; }
              main { min-width: 0; }
            </style></head><body><div class="host">
              <aside role="navigation"><strong>Codex</strong><button class="sidebar-item">New chat</button></aside>
              <main>Conversation surface</main>
            </div></body></html>
            """,
            baseURL: nil
        )
        try await DashboardWebTestHarness.waitUntilLoaded(webView)
        let now: Int64 = 1_735_819_200
        _ = try await webView.evaluateJavaScript("""
        (() => {
          const fixedNow = \(now * 1_000);
          const NativeDate = Date;
          window.Date = class FixedDate extends NativeDate {
            constructor(...arguments_) {
              super(...(arguments_.length ? arguments_ : [fixedNow]));
            }
            static now() { return fixedNow; }
          };
        })()
        """)
        let injection = try InjectionBundle.load()
        _ = try await webView.evaluateJavaScript(injection.mountExpression)
        let payload = try DashboardWebTestHarness.snapshotPayload(for: [
            .fixture(
                id: "running",
                title: "Build the dashboard",
                preview: "Finish the current dashboard improvements and verify the result.",
                projectName: "Codex Dashboard",
                projectPath: "/Users/example/Codex Dashboard",
                recencyEpochMillis: now * 1_000,
                isPinned: true,
                model: "gpt-5.6-sol",
                runState: .running,
                workingTreeStatus: .hasChanges
            ),
            .fixture(
                id: "unread",
                title: "Review the release",
                preview: "Check the finished release notes and packaging.",
                projectName: "Codex Dashboard",
                projectPath: "/Users/example/Codex Dashboard",
                recencyEpochMillis: (now - 900) * 1_000,
                isUnread: true,
                model: "gpt-5.6-terra"
            ),
            .fixture(
                id: "other",
                title: "Improve keyboard navigation",
                preview: "Add predictable focus and activation behavior.",
                projectName: "Voice Tools",
                projectPath: "/Users/example/Voice Tools",
                recencyEpochMillis: (now - 7_200) * 1_000,
                model: "gpt-5.5"
            ),
        ])
        _ = try await webView.evaluateJavaScript(
            """
            (() => {
              window.__codexDashboard.applyThreads((\(payload)).threads);
              window.__codexDashboard.open();
              const testStyle = document.createElement('style');
              testStyle.textContent = '#codex-dashboard-page { transition: none !important; opacity: 1 !important; visibility: visible !important; transform: none !important; }';
              document.head.append(testStyle);
              return document.getElementById('codex-dashboard-page').classList.contains('is-open');
            })()
            """
        )
        try await Task.sleep(for: .milliseconds(150))
        let configuration = WKSnapshotConfiguration()
        configuration.rect = CGRect(origin: .zero, size: scenario.size)
        // Baselines use two pixels per point, regardless of the runner's display.
        let displayScale = NSScreen.main?.backingScaleFactor ?? 1
        configuration.snapshotWidth = NSNumber(value: scenario.size.width * 2 / displayScale)
        let image = try await webView.takeSnapshot(configuration: configuration)
        return try XCTUnwrap(image.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0) }?.representation(using: .png, properties: [:]))
    }

    private func assertMatchesBaseline(_ actual: Data, named name: String) throws {
        let sourceDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let baselineURL = sourceDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("VisualBaselines", isDirectory: true)
            .appendingPathComponent("\(name).png")
        if ProcessInfo.processInfo.environment["UPDATE_VISUAL_BASELINES"] == "1" {
            try actual.write(to: baselineURL, options: .atomic)
            return
        }
        let expected = try Data(contentsOf: baselineURL)
        let actualBitmap = try XCTUnwrap(NSBitmapImageRep(data: actual))
        let expectedBitmap = try XCTUnwrap(NSBitmapImageRep(data: expected))
        XCTAssertEqual(actualBitmap.pixelsWide, expectedBitmap.pixelsWide, name)
        XCTAssertEqual(actualBitmap.pixelsHigh, expectedBitmap.pixelsHigh, name)
        guard actualBitmap.pixelsWide == expectedBitmap.pixelsWide,
              actualBitmap.pixelsHigh == expectedBitmap.pixelsHigh else { return }

        guard let actualBytes = actualBitmap.bitmapData,
              let expectedBytes = expectedBitmap.bitmapData,
              actualBitmap.bitsPerSample == 8,
              expectedBitmap.bitsPerSample == 8,
              actualBitmap.samplesPerPixel >= 3,
              actualBitmap.samplesPerPixel == expectedBitmap.samplesPerPixel
        else {
            XCTFail("\(name) did not use a comparable bitmap format")
            return
        }
        var changedPixels = 0
        var totalDifference = 0
        let pixelCount = actualBitmap.pixelsWide * actualBitmap.pixelsHigh
        for y in 0..<actualBitmap.pixelsHigh {
            for x in 0..<actualBitmap.pixelsWide {
                let actualOffset = y * actualBitmap.bytesPerRow + x * actualBitmap.samplesPerPixel
                let expectedOffset = y * expectedBitmap.bytesPerRow + x * expectedBitmap.samplesPerPixel
                let difference = (0..<3).reduce(into: 0) { total, channel in
                    total += abs(Int(actualBytes[actualOffset + channel]) - Int(expectedBytes[expectedOffset + channel]))
                }
                totalDifference += difference
                if difference > 24 { changedPixels += 1 }
            }
        }
        let changedRatio = Double(changedPixels) / Double(pixelCount)
        let averageDifference = Double(totalDifference) / Double(pixelCount * 3)
        XCTAssertLessThan(changedRatio, 0.01, "\(name) changed \(changedRatio * 100)% of pixels")
        XCTAssertLessThan(averageDifference, 1.5, "\(name) average channel difference was \(averageDifference)")
    }
}
