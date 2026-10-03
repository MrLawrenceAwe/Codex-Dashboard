import Foundation

public enum KeychainOperation: String, Codable, Sendable {
    case read, store, delete
}

public struct KeychainRequest: Codable, Sendable {
    public let operation: KeychainOperation
    public let accountID: UUID
    public let credential: Data?
    public let interactionAllowed: Bool
    public let probe: Bool?

    public init(operation: KeychainOperation, accountID: UUID, credential: Data? = nil,
                interactionAllowed: Bool, probe: Bool? = nil) {
        self.operation = operation
        self.accountID = accountID
        self.credential = credential
        self.interactionAllowed = interactionAllowed
        self.probe = probe
    }
}

public struct KeychainResponse: Codable, Sendable {
    public var status: Int32 = 0
    public var authorizationRequired = false
    public var credential: Data?

    public init() {}
}
