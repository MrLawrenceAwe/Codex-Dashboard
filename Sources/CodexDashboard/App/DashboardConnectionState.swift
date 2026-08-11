import Foundation

enum DashboardConnectionState: Equatable {
    case checking
    case codexClosed
    case codexRunningWithoutRenderer
    case rendererReady
    case dashboardMounted

    var rendererIsAvailable: Bool {
        self == .rendererReady || self == .dashboardMounted
    }

    var dashboardIsMounted: Bool { self == .dashboardMounted }

    func presentation(hasError: Bool, mountedSummary: String) -> (title: String, detail: String) {
        if hasError {
            return ("Thread Dashboard needs attention", "Review the message below and try again.")
        }
        return switch self {
        case .checking:
            ("Checking Codex…", "Looking for the local Codex app.")
        case .codexClosed:
            ("Codex is closed", "The Thread Dashboard can relaunch it with local debugging enabled.")
        case .codexRunningWithoutRenderer:
            (
                "Codex is running without the Thread Dashboard connection",
                "Restart it through this controller once to enable the Thread Dashboard."
            )
        case .rendererReady:
            ("Thread Dashboard is ready", "The local renderer is connected and ready.")
        case .dashboardMounted:
            ("Thread Dashboard is live", mountedSummary)
        }
    }
}
