import Darwin
import WebKit
import XCTest

@testable import CodexDashboard

@MainActor
enum DashboardWebTestHarness {
    private static var activeWebViews: [WKWebView] = []

    static func makeWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        activeWebViews.append(webView)
        return webView
    }

    static func releaseWebViews() {
        for webView in activeWebViews {
            webView.stopLoading()
            webView.navigationDelegate = nil
            webView.uiDelegate = nil
        }
        activeWebViews.removeAll()
    }

    static func mountedWebView(
        html: String,
        baseURL: URL? = nil,
        clearLocalStorage: Bool = false
    ) async throws -> WKWebView {
        let webView = makeWebView()
        webView.loadHTMLString(html, baseURL: baseURL)
        try await waitUntilLoaded(webView)
        if clearLocalStorage {
            _ = try? await webView.evaluateJavaScript(
                "try { localStorage.clear(); true } catch (_) { false }"
            )
        }
        let injection = try InjectionBundle.load()
        _ = try await webView.evaluateJavaScript(injection.mountExpression)
        return webView
    }

    static func promptLibraryWebView(includeContentEditableComposer: Bool = false) async throws -> WKWebView {
        let contentEditableComposer = includeContentEditableComposer
            ? #"<div contenteditable="true" role="textbox"></div>"#
            : ""
        let textareaComposer = includeContentEditableComposer
            ? ""
            : #"<textarea placeholder="Do anything"></textarea>"#
        return try await mountedWebView(
            html: """
            <!doctype html>
            <html><head><meta charset="utf-8"></head><body>
              <aside role="navigation">
                <button class="sidebar-item">New chat</button>
                <button type="button" aria-label="Add new project">+</button>
              </aside>
              <main>
                <div class="composer-shell">
                  \(textareaComposer)
                  <div class="composer-toolbar">
                    <button type="button" aria-label="Add">+</button>
                  </div>
                </div>
                \(contentEditableComposer)
              </main>
            </body></html>
            """,
            baseURL: URL(string: "https://\(UUID().uuidString).codex-dashboard.test"),
            clearLocalStorage: true
        )
    }

    static func taskDashboardWebView() async throws -> WKWebView {
        try await mountedWebView(html: """
        <!doctype html><html><head><meta charset="utf-8"></head><body>
          <aside role="navigation"><button class="sidebar-item">New chat</button></aside>
          <main>Conversation surface</main>
        </body></html>
        """)
    }

    static func snapshotPayload(for threads: [ThreadSummary]) throws -> String {
        let data = try JSONEncoder().encode(DashboardSnapshot(threads: threads))
        return try XCTUnwrap(String(data: data, encoding: .utf8))
    }

    static func waitUntilLoaded(_ webView: WKWebView) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while ContinuousClock.now < deadline {
            if webView.estimatedProgress >= 1, !webView.isLoading {
                let isReady = try? await webView.evaluateJavaScript(
                    "document.readyState === 'complete' && document.body !== null"
                ) as? Bool
                if isReady == true { return }
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw DashboardError.invalidDevToolsResponse
    }

    static func waitForJavaScript(
        _ expression: String,
        in webView: WKWebView,
        timeout: Duration = .seconds(2)
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if try await webView.evaluateJavaScript(expression) as? Bool == true { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Timed out waiting for JavaScript condition: \(expression)")
    }
}

@MainActor
class SerializedDashboardWebTestCase: XCTestCase {
    // `swift test --parallel` runs test cases in worker processes. Keep the lock for the
    // lifetime of each worker so WebKit process teardown cannot overlap the next worker.
    nonisolated private static let processLockFileDescriptor: Int32 = {
        let lockURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-dashboard-web-tests.lock")
        let descriptor = Darwin.open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0, flock(descriptor, LOCK_EX) == 0 else {
            if descriptor >= 0 { Darwin.close(descriptor) }
            return -1
        }
        return descriptor
    }()

    override func setUpWithError() throws {
        try super.setUpWithError()
        guard Self.processLockFileDescriptor >= 0 else {
            throw CocoaError(.fileLocking)
        }
    }

    override func tearDown() async throws {
        DashboardWebTestHarness.releaseWebViews()
        await Task.yield()
        try await super.tearDown()
    }
}
