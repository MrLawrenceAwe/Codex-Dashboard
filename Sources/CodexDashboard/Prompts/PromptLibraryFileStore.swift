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
        self.maximumBackupCount = max(0, maximumBackupCount)
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
        let document = PromptLibraryMigration.migrate(storedDocument)
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
        pruneBackups()
        return true
    }

    func importDocument(from sourceURL: URL) throws {
        let document = try JSONDecoder().decode(
            PromptLibraryDocument.self,
            from: Data(contentsOf: sourceURL)
        )
        let migratedDocument = PromptLibraryMigration.migrate(document)
        guard migratedDocument.isValid else { throw DashboardError.invalidPromptLibrary }
        try save(migratedDocument)
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
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let timestamp = formatter.string(from: now()).replacingOccurrences(of: ":", with: "-")
        let backupURL = backupDirectoryURL.appendingPathComponent(
            "prompt-library-\(timestamp)-\(UUID().uuidString).json"
        )
        try data.write(to: backupURL, options: .atomic)
    }

    private func pruneBackups() {
        guard let backups = try? fileManager.contentsOfDirectory(
            at: backupDirectoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ).filter(Self.isGeneratedBackup).sorted(by: { left, right in
            let leftDate = try? left.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            let rightDate = try? right.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            return (leftDate ?? .distantPast) > (rightDate ?? .distantPast)
        }) else { return }
        for staleBackup in backups.dropFirst(maximumBackupCount) {
            try? fileManager.removeItem(at: staleBackup)
        }
    }

    private static func isGeneratedBackup(_ url: URL) -> Bool {
        guard url.pathExtension == "json" else { return false }
        let filename = url.deletingPathExtension().lastPathComponent
        guard filename.hasPrefix("prompt-library-"), filename.count > 37 else { return false }
        let separator = filename.index(filename.endIndex, offsetBy: -37)
        guard filename[separator] == "-" else { return false }
        return UUID(uuidString: String(filename[filename.index(after: separator)...])) != nil
    }
}
