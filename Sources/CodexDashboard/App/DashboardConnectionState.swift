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

    func statusIconIsFilled(dashboardMaintenanceIsEnabled: Bool) -> Bool {
        dashboardIsMounted || (rendererIsAvailable && dashboardMaintenanceIsEnabled)
    }

    func presentation(hasError: Bool, mountedSummary: String) -> (title: String, detail: String) {
        if hasError {
            return ("Dashboard integration needs attention", "Review the message below and try again.")
        }
        return switch self {
        case .checking:
            ("Checking Codex…", "Looking for the local Codex app.")
        case .codexClosed:
            ("Codex is closed", "Codex Dashboard can relaunch it with local debugging enabled.")
        case .codexRunningWithoutRenderer:
            (
                "Codex is running without the dashboard connection",
                "Restart Codex from the Codex Dashboard menu once to enable dashboard integration."
            )
        case .rendererAvailable:
            ("Dashboard connection is ready", "The local renderer is connected and ready.")
        case .dashboardMounted:
            ("Dashboard integration is live", mountedSummary)
        }
    }
}

struct DashboardActionPresentation: Equatable {
    static let openTitle = "Open chat overview"
    static let restartTitle = "Restart & Enable"
    static let disableTitle = "Disable dashboard integration"

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
