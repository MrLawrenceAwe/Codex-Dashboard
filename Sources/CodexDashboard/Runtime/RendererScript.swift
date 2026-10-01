import Foundation

enum RendererScript {
    static let destroy = """
    (() => { window.__codexDashboard?.destroy?.(); return typeof window.__codexDashboard === 'undefined'; })()
    """

    static let open = """
    (() => { window.__codexDashboard?.open?.(); return true; })()
    """

    // Current Codex renderer contracts: dictation footer and realtime orb, plus
    // speech controller props for startup/transcription before those views mount.
    // Inspect props rather than translated button labels.
    static let hasActiveSpeechInput = """
    (() => {
      if (document.querySelector('[data-dictation-view], [data-realtime-voice-orb]')) return true;
      const visited = new Set();
      for (const element of document.querySelectorAll('button, [data-composer-body]')) {
        const key = Object.keys(element).find(key => key.startsWith('__reactFiber$'));
        for (let fiber = key && element[key]; fiber && !visited.has(fiber); fiber = fiber.return) {
          visited.add(fiber);
          const props = fiber.memoizedProps;
          if (!props || typeof props !== 'object') continue;
          if (props.isDictating === true || props.isDictationStarting === true || props.isTranscribing === true) return true;
          if (typeof props.startDictation === 'function' && (props.isStarting === true || props.isPreparing === true)) return true;
          const phase = props.realtimeSession?.thread?.phase;
          if (typeof phase === 'string' && phase !== 'inactive') return true;
        }
      }
      return false;
    })()
    """

    static func openThread(_ threadID: String) -> String? {
        guard
            let data = try? JSONSerialization.data(withJSONObject: threadID, options: .fragmentsAllowed),
            let encodedThreadID = String(data: data, encoding: .utf8)
        else { return nil }
        return """
        (() => {
          if (window.__codexDashboard?.isOpen?.()) return false;
          window.dispatchEvent(new MessageEvent('message', {
            data: { type: 'navigate-to-route', path: `/local/${encodeURIComponent(\(encodedThreadID))}` },
            source: null,
          }));
          return true;
        })()
        """
    }

    static func deliverThreads(_ threads: [RendererThread]) throws -> String {
        let json = try encodeJSON(threads)
        return """
        (() => {
          const dashboard = window.__codexDashboard;
          return dashboard?.applyThreads?.(\(json)) === true;
        })()
        """
    }

    static func deliverAccountPopover(_ snapshot: AccountPopoverSnapshot?) throws -> String {
        let json = try encodeJSON(snapshot)
        return "(() => window.__codexDashboard?.applyAccountPopoverSnapshot?.(\(json)) === true)()"
    }

    static let accountPopoverUnavailable = "__codexDashboardUnavailable__"
    static let takeNextAccountPopoverAction =
        "window.__codexDashboard?.takeNextAccountPopoverAction?.() ?? '\(accountPopoverUnavailable)'"

    static let exportPromptLibrary = "window.__codexDashboard?.exportPromptLibrary?.() ?? null"

    static let exportPendingPromptLibrary =
        "window.__codexDashboard?.exportPendingPromptLibrary?.() ?? null"

    static let discardPendingPromptLibrary =
        "window.__codexDashboard?.discardPendingPromptLibrary?.() === true"

    static func deliverPromptLibrary(_ library: PromptLibraryDocument) throws -> String {
        let json = try encodeJSON(library)
        return """
        (() => window.__codexDashboard?.applyPromptLibrary?.(\(json)) === true)()
        """
    }

    static func acknowledgePendingPromptLibrary(_ library: PromptLibraryDocument) throws -> String {
        let json = try encodeJSON(library)
        return "(() => window.__codexDashboard?.acknowledgePendingPromptLibrary?.(\(json)) === true)()"
    }

    static let pendingReviewAction = "window.__codexDashboard?.pendingReviewAction?.() ?? null"

    static func deliverReviewLoop(_ snapshot: ReviewLoopSnapshot) throws -> String {
        "window.__codexDashboard?.applyReviewLoop?.(\(try encodeJSON(snapshot))) === true"
    }

    static func reviewRequest(method: String, params: [String: Any]) throws -> String {
        let request = try JSONSerialization.data(
            withJSONObject: ["method": method, "params": params],
            options: [.sortedKeys]
        )
        return "window.__codexDashboard.reviewRequest(\(String(decoding: request, as: UTF8.self)))"
    }

    private static func encodeJSON(_ value: some Encodable) throws -> String {
        String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
    }
}
