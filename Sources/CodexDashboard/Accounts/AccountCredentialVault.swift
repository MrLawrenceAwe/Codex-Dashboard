import DashboardKeychainProtocol
import Foundation
import Security

protocol AccountCredentialVault: Sendable {
    func credential(for accountID: UUID) throws -> Data?
    func credentialWithoutUserInteraction(for accountID: UUID) throws -> Data?
    func store(_ credential: Data, for accountID: UUID) throws
    func storeWithoutUserInteraction(_ credential: Data, for accountID: UUID) throws
    func deleteCredential(for accountID: UUID) throws
}

struct KeychainAccountCredentialVault: AccountCredentialVault {
    func credential(for accountID: UUID) throws -> Data? {
        try request(.read, accountID, interactionAllowed: true)
    }

    func credentialWithoutUserInteraction(for accountID: UUID) throws -> Data? {
        try request(.read, accountID, interactionAllowed: false)
    }

    func store(_ credential: Data, for accountID: UUID) throws {
        _ = try request(.store, accountID, credential: credential, interactionAllowed: true)
    }

    func storeWithoutUserInteraction(_ credential: Data, for accountID: UUID) throws {
        _ = try request(.store, accountID, credential: credential, interactionAllowed: false)
    }

    func deleteCredential(for accountID: UUID) throws {
        _ = try request(.delete, accountID, interactionAllowed: true)
    }

    private func request(
        _ operation: KeychainOperation,
        _ accountID: UUID,
        credential: Data? = nil,
        interactionAllowed: Bool
    ) throws -> Data? {
        let executable: URL
        if Bundle.main.bundleURL.pathExtension == "app" {
            executable = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/CodexDashboardKeychainHelper")
        } else {
            executable = URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0])
                .deletingLastPathComponent().appendingPathComponent("CodexDashboardKeychainHelper")
        }
        let input = Pipe()
        let output = Pipe()
        let process = Process()
        process.executableURL = executable
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let request = KeychainRequest(operation: operation, accountID: accountID,
            credential: credential, interactionAllowed: interactionAllowed)
        do { try process.run() }
        catch { throw CodexAccountError.keychain(errSecNotAvailable) }
        try output.fileHandleForWriting.close()
        try input.fileHandleForReading.close()
        let timeout = DispatchWorkItem {
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + (interactionAllowed ? 180 : 10), execute: timeout)
        defer {
            timeout.cancel()
            if process.isRunning { process.terminate() }
            try? input.fileHandleForWriting.close()
            try? output.fileHandleForReading.close()
        }
        try input.fileHandleForWriting.write(contentsOf: JSONEncoder().encode(request))
        try input.fileHandleForWriting.close()
        let data = try output.fileHandleForReading.readToEnd() ?? Data()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
            let response = try? JSONDecoder().decode(KeychainResponse.self, from: data) else {
            throw CodexAccountError.keychain(errSecNotAvailable)
        }
        if response.authorizationRequired { throw CodexAccountError.keychainAuthorizationRequired }
        if response.status != errSecSuccess { throw CodexAccountError.keychain(response.status) }
        return response.credential
    }

}
