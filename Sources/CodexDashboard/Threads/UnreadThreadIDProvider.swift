import CryptoKit
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
        let threadReadState: ThreadReadState

        private enum CodingKeys: String, CodingKey {
            case threadReadState = "electron-thread-read-state-v1"
        }
    }

    private struct ThreadReadState: Decodable {
        let unreadByIdentity: [String: [String: [String]]]

        private enum CodingKeys: String, CodingKey {
            case unreadByIdentity = "unreadByIdentity"
        }
    }

    private let stateURL: URL
    private let dataLoader: @Sendable (URL) throws -> Data
    private let identityKeyLoader: @Sendable () throws -> String?
    private var cachedIdentityKey: String?
    private var cachedSignature: FileSignature?
    private var cachedUnreadThreadIDs: Set<String> = []

    init(
        stateURL: URL = CodexConfiguration.globalStateURL,
        identityKeyLoader: @escaping @Sendable () throws -> String? = {
            guard FileManager.default.fileExists(atPath: CodexConfiguration.authenticationURL.path)
            else { return nil }
            return try CodexUnreadThreadIDProvider.identityKey(from: Data(contentsOf: CodexConfiguration.authenticationURL))
        },
        dataLoader: @escaping @Sendable (URL) throws -> Data = {
            try Data(contentsOf: $0, options: .mappedIfSafe)
        }
    ) {
        self.stateURL = stateURL
        self.identityKeyLoader = identityKeyLoader
        self.dataLoader = dataLoader
    }

    func loadUnreadThreadIDs() throws -> Set<String> {
        let signature: FileSignature
        do {
            signature = try FileSignature.read(at: stateURL)
        } catch CocoaError.fileReadNoSuchFile {
            throw UnreadThreadIDError.missingState(stateURL)
        } catch {
            throw UnreadThreadIDError.invalidState(stateURL)
        }
        let identityKey = try identityKeyLoader()
        if signature == cachedSignature && identityKey == cachedIdentityKey {
            return cachedUnreadThreadIDs
        }

        do {
            let data = try dataLoader(stateURL)
            let unreadThreadIDs = try Self.decodeUnreadThreadIDs(from: data, identityKey: identityKey)
            cachedSignature = signature
            cachedIdentityKey = identityKey
            cachedUnreadThreadIDs = unreadThreadIDs
            return unreadThreadIDs
        } catch {
            if error is UnreadThreadIDError { throw error }
            throw UnreadThreadIDError.invalidState(stateURL)
        }
    }

    static func decodeUnreadThreadIDs(from data: Data, identityKey: String?) throws -> Set<String> {
        let state = try JSONDecoder().decode(GlobalState.self, from: data)
        guard let identityKey else { return [] }
        return Set(
            (state.threadReadState.unreadByIdentity[identityKey] ?? [:])
                .filter { hostID, _ in hostID == "local" || hostID.hasPrefix("local:") }
                .flatMap(\.value)
        )
    }

    // Codex keys read state by SHA-256 of JSON [kind, accountId, userId].
    // Decode only the claims needed for that key; credentials never leave this process.
    static func identityKey(from credential: Data) throws -> String? {
        guard let root = try JSONSerialization.jsonObject(with: credential) as? [String: Any],
              let tokens = root["tokens"] as? [String: Any],
              let token = tokens["access_token"] as? String
        else { return nil }
        guard let claims = try JWTClaimsDecoder.decodeUnverifiedClaims(token),
              let auth = claims["https://api.openai.com/auth"] as? [String: Any],
              let accountID = auth["chatgpt_account_id"] as? String,
              let userID = auth["chatgpt_user_id"] as? String,
              !accountID.isEmpty, !userID.isEmpty
        else { return nil }
        let identity = try JSONSerialization.data(
            withJSONObject: ["chatgpt", accountID, userID], options: [.withoutEscapingSlashes]
        )
        return SHA256.hash(data: identity).map { String(format: "%02x", $0) }.joined()
    }
}
