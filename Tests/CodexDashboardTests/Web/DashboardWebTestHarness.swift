import Darwin
import WebKit
import XCTest

@testable import CodexDashboard

@MainActor
enum DashboardWebTestHarness {
    static func mountedWebView(
        html: String,
        baseURL: URL? = nil,
        clearLocalStorage: Bool = false
    ) async throws -> WKWebView {
        let webView = WKWebView()
        webView.loadHTMLString(html, baseURL: baseURL)
        try await waitUntilLoaded(webView)
        if clearLocalStorage {
            _ = try? await webView.evaluateJavaScript(
                "try { localStorage.clear(); true } catch (_) { false }"
            )
        }
        let injection = try DashboardInjectionPayload.load()
        _ = try await webView.evaluateJavaScript(injection.mountExpression)
        return webView
    }

    static func snapshotPayload(for threads: [ThreadSummary]) throws -> String {
        let data = try JSONEncoder().encode(DashboardSnapshot(threads: threads))
        return try XCTUnwrap(String(data: data, encoding: .utf8))
    }

    static func waitUntilLoaded(_ webView: WKWebView) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while webView.isLoading {
            guard ContinuousClock.now < deadline else {
                throw DashboardError.invalidDevToolsResponse
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}

class SerializedDashboardWebTestCase: XCTestCase {
    private var lockFileDescriptor: Int32 = -1

    override func setUpWithError() throws {
        try super.setUpWithError()
        let lockURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-dashboard-web-tests.lock")
        lockFileDescriptor = Darwin.open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard lockFileDescriptor >= 0, flock(lockFileDescriptor, LOCK_EX) == 0 else {
            if lockFileDescriptor >= 0 { Darwin.close(lockFileDescriptor) }
            lockFileDescriptor = -1
            throw CocoaError(.fileLocking)
        }
    }

    override func tearDownWithError() throws {
        if lockFileDescriptor >= 0 {
            flock(lockFileDescriptor, LOCK_UN)
            Darwin.close(lockFileDescriptor)
            lockFileDescriptor = -1
        }
        try super.tearDownWithError()
    }
}
