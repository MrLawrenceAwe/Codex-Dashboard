import Foundation

enum DashboardRendererScript {
    static let destroy = """
    (() => { window.__codexDashboard?.destroy?.(); return typeof window.__codexDashboard === 'undefined'; })()
    """

    static let open = """
    (() => { window.__codexDashboard?.open?.(); return true; })()
    """

    static func openThread(_ threadID: String) -> String? {
        guard
            let data = try? JSONSerialization.data(withJSONObject: threadID, options: .fragmentsAllowed),
            let encodedThreadID = String(data: data, encoding: .utf8)
        else { return nil }
        return """
        (() => {
          window.dispatchEvent(new MessageEvent('message', {
            data: { type: 'navigate-to-route', path: `/local/${encodeURIComponent(\(encodedThreadID))}` },
            source: null,
          }));
          return true;
        })()
        """
    }

    static func deliver(_ snapshot: DashboardSnapshotPayload) throws -> String {
        let data = try JSONEncoder().encode(snapshot)
        guard let json = String(data: data, encoding: .utf8) else {
            throw DashboardError.enableFailed("Thread data could not be encoded for the renderer.")
        }
        return """
        (() => {
          const dashboard = window.__codexDashboard;
          if (typeof dashboard?.applySnapshot !== 'function') return false;
          dashboard.applySnapshot(\(json));
          return true;
        })()
        """
    }

    static let exportPromptLibrary = "window.__codexDashboard?.exportPromptLibrary?.() ?? null"

    static func deliverPromptLibrary(_ library: PromptLibraryDocument) throws -> String {
        let data = try JSONEncoder().encode(library)
        guard let json = String(data: data, encoding: .utf8) else {
            throw DashboardError.enableFailed("The prompt library could not be encoded for the renderer.")
        }
        return """
        (() => window.__codexDashboard?.applyPromptLibrary?.(\(json)) === true)()
        """
    }
}
