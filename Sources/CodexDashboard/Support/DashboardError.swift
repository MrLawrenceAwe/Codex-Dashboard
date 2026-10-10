import Foundation

enum DashboardError: LocalizedError {
    case missingCodexApplication
    case codexQuitTimedOut
    case rendererTimedOut
    case missingResources
    case unreadableResourceManifest(path: String, reason: String)
    case invalidResourceManifest(path: String, reason: String)
    case invalidDevToolsResponse
    case devToolsTimedOut
    case devToolsCommandFailed(String)
    case mountFailed(String)
    case synchronizationFailed(String)
    case rendererEvaluationFailed
    case disableFailed(String)
    case invalidPromptLibrary

    var errorDescription: String? {
        switch self {
        case .missingCodexApplication:
            return "The Codex app was not found in /Applications."
        case .codexQuitTimedOut:
            return "Codex could not be closed for restart. Quit it manually, then try again."
        case .rendererTimedOut:
            return "Codex reopened, but its local renderer did not become available."
        case .missingResources:
            return "The dashboard resources are missing from the application bundle."
        case .unreadableResourceManifest(let path, let reason):
            return "The dashboard resource manifest could not be read at \(path): \(reason)"
        case .invalidResourceManifest(let path, let reason):
            return "The dashboard resource manifest is invalid at \(path): \(reason)"
        case .invalidDevToolsResponse:
            return "The Codex renderer returned an invalid debugging response."
        case .devToolsTimedOut:
            return "The Codex renderer did not respond to the dashboard request."
        case .devToolsCommandFailed(let message):
            return "The Codex renderer rejected a dashboard command: \(message)"
        case .mountFailed(let message):
            return "Dashboard mounting failed: \(message)"
        case .synchronizationFailed(let message):
            return "Dashboard synchronization failed: \(message)"
        case .rendererEvaluationFailed:
            return "The dashboard command raised an exception in the Codex renderer."
        case .disableFailed(let message):
            return "Dashboard disablement failed: \(message)"
        case .invalidPromptLibrary:
            return "The prompt library file is not a valid Codex Dashboard prompt library."
        }
    }
}
