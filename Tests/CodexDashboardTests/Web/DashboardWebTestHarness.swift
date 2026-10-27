import Darwin
import WebKit
import XCTest

@testable import CodexDashboard

@MainActor
enum DashboardWebTestHarness {
    private static var activeWebViews: [WKWebView] = []
    static let basicHostHTML = """
        <!doctype html><html><head><meta charset="utf-8"></head><body>
          <aside role="navigation"><button class="sidebar-item">New chat</button></aside>
          <main>Conversation surface</main>
        </body></html>
        """

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
        clearLocalStorage: Bool = false,
        trackTodoSaves: Bool = false
    ) async throws -> WKWebView {
        let webView = makeWebView()
        webView.loadHTMLString(html, baseURL: baseURL)
        try await waitUntilLoaded(webView)
        if clearLocalStorage {
            _ = try? await webView.evaluateJavaScript(
                "try { localStorage.clear(); true } catch (_) { false }"
            )
        }
        let injection = trackTodoSaves
            ? try InjectionBundle.load(bootstrap: todoBootstrap())
            : try InjectionBundle.load()
        _ = try await webView.evaluateJavaScript(injection.mountExpression)
        return webView
    }

    static func todoBootstrap() throws -> String {
        let url = try XCTUnwrap(Bundle.module.url(
            forResource: "todo-bootstrap", withExtension: "js", subdirectory: "Fixtures"
        ))
        return try String(contentsOf: url, encoding: .utf8)
    }

    static func instrumentSource(_ source: String, anchor: String, replacement: String) throws -> String {
        let matches = source.components(separatedBy: anchor).count - 1
        guard matches == 1 else {
            throw NSError(domain: "DashboardWebTestInstrumentation", code: 1,
                          userInfo: [NSLocalizedDescriptionKey:
                            "Expected one instrumentation anchor, found \(matches): \(anchor)"])
        }
        return source.replacingOccurrences(of: anchor, with: replacement)
    }

    static func todoWebView(
        html: String,
        baseURL: URL? = nil,
        clearLocalStorage: Bool = false
    ) async throws -> WKWebView {
        try await mountedWebView(
            html: html, baseURL: baseURL, clearLocalStorage: clearLocalStorage, trackTodoSaves: true
        )
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

    static func chatOverviewWebView() async throws -> WKWebView {
        try await mountedWebView(html: basicHostHTML)
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
        throw NSError(domain: "DashboardWebTestLoading", code: 1,
                      userInfo: [NSLocalizedDescriptionKey:
                        "WKWebView did not finish loading within 3 seconds. Expected loading to stop, progress to reach 1, document.readyState to be complete, and document.body to exist."])
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

@MainActor
extension WKWebView {
    func evaluateAsyncJavaScript(_ expression: String) async throws -> Any? {
        try await callAsyncJavaScript(
            "return await (\(expression));", arguments: [:], in: nil, contentWorld: .page
        )
    }
}
