import Foundation

private struct CodexAccountUsageCacheDocument: Codable {
    static let currentVersion = 1

    let version: Int
    let snapshots: [String: CodexAccountUsageSnapshot]
}

final class UsageCache: @unchecked Sendable {
    private let cacheURL: URL
    private let fileManager: FileManager
    private let lock = NSLock()

    init(
        cacheURL: URL = CodexConfiguration.accountUsageCacheURL,
        fileManager: FileManager = .default
    ) {
        self.cacheURL = cacheURL
        self.fileManager = fileManager
    }

    func load() throws -> [UUID: CodexAccountUsageSnapshot] {
        try lock.withLock {
            guard fileManager.fileExists(atPath: cacheURL.path) else { return [:] }
            let document = try JSONDecoder().decode(
                CodexAccountUsageCacheDocument.self,
                from: Data(contentsOf: cacheURL)
            )
            guard document.version == CodexAccountUsageCacheDocument.currentVersion else {
                return [:]
            }
            return Dictionary(uniqueKeysWithValues: document.snapshots.compactMap { key, value in
                UUID(uuidString: key).map { ($0, value) }
            })
        }
    }

    func save(_ snapshots: [UUID: CodexAccountUsageSnapshot]) throws {
        try lock.withLock {
            try fileManager.createDirectory(
                at: cacheURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let document = CodexAccountUsageCacheDocument(
                version: CodexAccountUsageCacheDocument.currentVersion,
                snapshots: Dictionary(uniqueKeysWithValues: snapshots.map {
                    ($0.key.uuidString, $0.value)
                })
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(document).write(to: cacheURL, options: .atomic)
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: cacheURL.path
            )
        }
    }
}
