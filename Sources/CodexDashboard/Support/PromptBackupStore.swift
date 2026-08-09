import Foundation

actor PromptBackupStore {
    static let shared = PromptBackupStore()

    private let backupURL: URL

    init(fileManager: FileManager = .default) {
        let root = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Codex Dashboard", isDirectory: true)
        backupURL = root.appendingPathComponent("prompt-library.json")
    }

    init(backupURL: URL) {
        self.backupURL = backupURL
    }

    func load() -> String? {
        try? String(contentsOf: backupURL, encoding: .utf8)
    }

    func save(_ json: String) throws {
        guard let data = json.data(using: .utf8),
              (try JSONSerialization.jsonObject(with: data)) is [String: Any]
        else { throw DashboardError.invalidPromptLibrary }
        try FileManager.default.createDirectory(
            at: backupURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: backupURL, options: .atomic)
    }

    var path: String { backupURL.path }
}
