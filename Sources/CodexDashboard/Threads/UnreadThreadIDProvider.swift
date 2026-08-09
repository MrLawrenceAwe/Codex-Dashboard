import Foundation

protocol UnreadThreadIDProviding: Sendable {
    func loadUnreadThreadIDs() async throws -> Set<String>
}

enum UnreadThreadIDError: LocalizedError {
    case missingState(URL)
    case invalidState(URL)

    var errorDescription: String? {
        switch self {
        case .missingState(let stateURL):
            "The Codex global state is missing: \(stateURL.path)"
        case .invalidState(let stateURL):
            "Codex returned unreadable global state from \(stateURL.path)."
        }
    }
}

actor CodexUnreadThreadIDProvider: UnreadThreadIDProviding {
    private struct GlobalState: Decodable {
        let persistedAtoms: PersistedAtoms

        private enum CodingKeys: String, CodingKey {
            case persistedAtoms = "electron-persisted-atom-state"
        }
    }

    private struct PersistedAtoms: Decodable {
        let unreadThreadIDsByHost: [String: [String]]

        private enum CodingKeys: String, CodingKey {
            case unreadThreadIDsByHost = "unread-thread-ids-by-host-v1"
        }
    }

    private let stateURL: URL

    init(stateURL: URL = CodexConfiguration.globalStateURL) {
        self.stateURL = stateURL
    }

    func loadUnreadThreadIDs() throws -> Set<String> {
        guard FileManager.default.fileExists(atPath: stateURL.path) else {
            throw UnreadThreadIDError.missingState(stateURL)
        }
        do {
            let data = try Data(contentsOf: stateURL, options: .mappedIfSafe)
            let state = try JSONDecoder().decode(GlobalState.self, from: data)
            return Set(state.persistedAtoms.unreadThreadIDsByHost["local"] ?? [])
        } catch {
            if error is UnreadThreadIDError { throw error }
            throw UnreadThreadIDError.invalidState(stateURL)
        }
    }
}
