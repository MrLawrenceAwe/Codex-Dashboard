import Foundation

enum DashboardError: LocalizedError {
    case missingCodexApplication
    case codexQuitTimedOut
    case rendererTimedOut
    case missingResources
    case invalidDevToolsResponse
    case devToolsTimedOut
    case devToolsCommandFailed(String)
    case enableFailed(String)
    case disableFailed(String)
    case invalidPromptLibrary

    var errorDescription: String? {
        switch self {
        case .missingCodexApplication:
            return "The Codex app was not found in /Applications."
        case .codexQuitTimedOut:
            return "Codex did not close. Finish any open prompt and quit it manually, then try again."
        case .rendererTimedOut:
            return "Codex reopened, but its local renderer did not become available."
        case .missingResources:
            return "The dashboard resources are missing from the application bundle."
        case .invalidDevToolsResponse:
            return "The Codex renderer returned an invalid debugging response."
        case .devToolsTimedOut:
            return "The Codex renderer did not respond to the dashboard request."
        case .devToolsCommandFailed(let message):
            return "The Codex renderer rejected a dashboard command: \(message)"
        case .enableFailed(let message):
            return "Dashboard enablement failed: \(message)"
        case .disableFailed(let message):
            return "Dashboard disablement failed: \(message)"
        case .invalidPromptLibrary:
            return "The saved prompt library backup is invalid."
        }
    }
}
