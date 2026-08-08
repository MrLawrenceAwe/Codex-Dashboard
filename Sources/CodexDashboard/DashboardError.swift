import Foundation

enum DashboardError: LocalizedError {
    case missingHostApplication
    case hostQuitTimedOut
    case rendererTimedOut
    case missingResources
    case invalidDevToolsResponse
    case devToolsTimedOut
    case devToolsCommandFailed(String)
    case enableFailed(String)
    case disableFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingHostApplication:
            return "The Codex host application was not found in /Applications."
        case .hostQuitTimedOut:
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
        }
    }
}

func withDevToolsTimeout<T: Sendable>(
    _ duration: Duration,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask(operation: operation)
        group.addTask {
            try await Task.sleep(for: duration)
            throw DashboardError.devToolsTimedOut
        }

        guard let result = try await group.next() else {
            throw DashboardError.invalidDevToolsResponse
        }
        group.cancelAll()
        return result
    }
}
