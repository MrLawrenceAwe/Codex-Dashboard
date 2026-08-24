import Foundation

final class PromptLibraryFileStore {
    private let fileManager: FileManager
    let documentURL: URL
    let backupDirectoryURL: URL
    private let now: () -> Date
    private let maximumBackupCount: Int

    init(
        documentURL: URL? = nil,
        fileManager: FileManager = .default,
        now: @escaping () -> Date = Date.init,
        maximumBackupCount: Int = 10
    ) {
        self.fileManager = fileManager
        self.now = now
        self.maximumBackupCount = maximumBackupCount
        let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        let directory = documentURL?.deletingLastPathComponent()
            ?? applicationSupport.appendingPathComponent("Codex Dashboard", isDirectory: true)
        self.documentURL = documentURL ?? directory.appendingPathComponent("prompt-library.json")
        backupDirectoryURL = directory.appendingPathComponent("Prompt Library Backups", isDirectory: true)
    }

    func load() throws -> PromptLibraryDocument? {
        guard fileManager.fileExists(atPath: documentURL.path) else { return nil }
        let storedDocument = try JSONDecoder().decode(PromptLibraryDocument.self, from: Data(contentsOf: documentURL))
        let document = storedDocument.migratingLegacyReasoningEffort
        guard document.isValid else { throw DashboardError.invalidPromptLibrary }
        if document != storedDocument {
            try save(document)
        }
        return document
    }

    @discardableResult
    func save(_ document: PromptLibraryDocument) throws -> Bool {
        guard document.isValid else { throw DashboardError.invalidPromptLibrary }
        let data = try encoded(document)
        let currentData = try? Data(contentsOf: documentURL)
        guard currentData != data else { return false }
        try fileManager.createDirectory(at: documentURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let currentData {
            try createBackup(with: currentData)
        }
        try data.write(to: documentURL, options: .atomic)
        return true
    }

    func importDocument(from sourceURL: URL) throws {
        let document = try JSONDecoder().decode(
            PromptLibraryDocument.self,
            from: Data(contentsOf: sourceURL)
        ).migratingLegacyReasoningEffort
        guard document.isValid else { throw DashboardError.invalidPromptLibrary }
        try save(document)
    }

    func exportDocument(to destinationURL: URL) throws {
        let document = try load() ?? .empty
        try encoded(document).write(to: destinationURL, options: .atomic)
    }

    private func encoded(_ document: PromptLibraryDocument) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(document)
    }

    private func createBackup(with data: Data) throws {
        try fileManager.createDirectory(at: backupDirectoryURL, withIntermediateDirectories: true)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let timestamp = formatter.string(from: now()).replacingOccurrences(of: ":", with: "-")
        let backupURL = backupDirectoryURL.appendingPathComponent("prompt-library-\(timestamp).json")
        try data.write(to: backupURL, options: .atomic)
        let backups = try fileManager.contentsOfDirectory(
            at: backupDirectoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ).sorted { left, right in
            let leftDate = try? left.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            let rightDate = try? right.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            return (leftDate ?? .distantPast) > (rightDate ?? .distantPast)
        }
        for staleBackup in backups.dropFirst(maximumBackupCount) {
            try fileManager.removeItem(at: staleBackup)
        }
    }
}
