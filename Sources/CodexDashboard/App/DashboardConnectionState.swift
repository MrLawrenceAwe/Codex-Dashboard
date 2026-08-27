import Foundation

enum DashboardConnectionState: Equatable {
    case checking
    case codexClosed
    case codexRunningWithoutRenderer
    case rendererAvailable
    case dashboardMounted

    var rendererIsAvailable: Bool {
        self == .rendererAvailable || self == .dashboardMounted
    }

    var dashboardIsMounted: Bool { self == .dashboardMounted }

    func presentation(hasError: Bool, mountedSummary: String) -> (title: String, detail: String) {
        if hasError {
            return ("Task Dashboard needs attention", "Review the message below and try again.")
        }
        return switch self {
        case .checking:
            ("Checking Codex…", "Looking for the local Codex app.")
        case .codexClosed:
            ("Codex is closed", "The Task Dashboard can relaunch it with local debugging enabled.")
        case .codexRunningWithoutRenderer:
            (
                "Codex is running without the Task Dashboard connection",
                "Restart Codex from the Codex Dashboard menu once to enable the Task Dashboard."
            )
        case .rendererAvailable:
            ("Task Dashboard is ready", "The local renderer is connected and ready.")
        case .dashboardMounted:
            ("Task Dashboard is live", mountedSummary)
        }
    }
}

struct DashboardActionPresentation: Equatable {
    static let openTitle = "Open Task Dashboard"
    static let restartTitle = "Restart & Enable"
    static let disableTitle = "Disable Task Dashboard"

    let canOpen: Bool
    let canRestart: Bool
    let canDisable: Bool

    init(
        connectionState: DashboardConnectionState,
        isPerformingAction: Bool,
        isCheckingCompatibility: Bool
    ) {
        canOpen = connectionState.dashboardIsMounted
        canRestart = !isPerformingAction && !isCheckingCompatibility
        canDisable = connectionState.rendererIsAvailable && !isPerformingAction
    }
}
