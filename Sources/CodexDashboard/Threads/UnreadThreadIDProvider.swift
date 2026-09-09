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
    private struct FileSignature: Equatable {
        let size: UInt64
        let modifiedAt: Date
    }

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
    private var cachedSignature: FileSignature?
    private var cachedUnreadThreadIDs: Set<String> = []

    init(
        stateURL: URL = CodexConfiguration.globalStateURL,
        dataLoader: @escaping @Sendable (URL) throws -> Data = {
            try Data(contentsOf: $0, options: .mappedIfSafe)
        }
    ) {
        self.stateURL = stateURL
        self.dataLoader = dataLoader
    }

    func loadUnreadThreadIDs() throws -> Set<String> {
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: stateURL.path)
        } catch CocoaError.fileReadNoSuchFile {
            throw UnreadThreadIDError.missingState(stateURL)
        } catch {
            throw UnreadThreadIDError.invalidState(stateURL)
        }
        guard
            let size = (attributes[.size] as? NSNumber)?.uint64Value,
            let modifiedAt = attributes[.modificationDate] as? Date
        else { throw UnreadThreadIDError.invalidState(stateURL) }
        let signature = FileSignature(size: size, modifiedAt: modifiedAt)
        if signature == cachedSignature { return cachedUnreadThreadIDs }

        do {
            let data = try dataLoader(stateURL)
            let unreadThreadIDs = try Self.decodeUnreadThreadIDs(from: data)
            cachedSignature = signature
            cachedUnreadThreadIDs = unreadThreadIDs
            return unreadThreadIDs
        } catch {
            if error is UnreadThreadIDError { throw error }
            throw UnreadThreadIDError.invalidState(stateURL)
        }
    }

    static func decodeUnreadThreadIDs(from data: Data) throws -> Set<String> {
        let state = try JSONDecoder().decode(GlobalState.self, from: data)
        return Set(
            state.threadReadState.unreadByIdentity.values
                .flatMap(\.self)
                .filter { hostID, _ in hostID == "local" || hostID.hasPrefix("local:") }
                .flatMap(\.value)
        )
    }
}
