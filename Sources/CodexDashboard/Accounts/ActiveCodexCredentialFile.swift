import Foundation

final class ActiveCodexCredentialFile: @unchecked Sendable {
    private let url: URL
    private let fileManager: FileManager

    init(url: URL, fileManager: FileManager) {
        self.url = url
        self.fileManager = fileManager
    }

    func read() throws -> Data? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        guard !data.isEmpty else { return nil }
        try validate(data)
        return data
    }

    func write(_ credential: Data) throws {
        try validate(credential)
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try credential.write(to: url, options: [.atomic])
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    func remove() throws {
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
    }

    func restore(_ credential: Data?) throws {
        if let credential {
            try write(credential)
        } else {
            try remove()
        }
    }

    private func validate(_ credential: Data) throws {
        guard (try? JSONSerialization.jsonObject(with: credential)) is [String: Any] else {
            throw CodexAccountError.invalidCredential
        }
    }
}
