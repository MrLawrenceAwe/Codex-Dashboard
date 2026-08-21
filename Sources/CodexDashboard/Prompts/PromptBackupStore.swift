import Foundation

actor PromptBackupStore {
    static let shared = PromptBackupStore()

    private let backupURL: URL
    private var cachedJSON: String?
    private var hasLoadedCache = false

    private struct Library: Decodable {
        let version: Int?
        let prompts: [Prompt]
        let sections: [String]
    }

    private struct Prompt: Decodable {
        let id: String
        let name: String
        let content: String
        let section: String?
        let scope: Scope?
    }

    private struct Scope: Decodable {
        let type: String
        let projectPath: String?

        var isValid: Bool {
            switch type {
            case "global":
                return true
            case "project":
                return !(projectPath?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            default:
                return false
            }
        }
    }

    init(fileManager: FileManager = .default) {
        let root = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Codex Dashboard", isDirectory: true)
        backupURL = root.appendingPathComponent("prompt-library.json")
    }

    init(backupURL: URL) {
        self.backupURL = backupURL
    }

    func load() -> String? {
        if hasLoadedCache { return cachedJSON }
        if let json = try? String(contentsOf: backupURL, encoding: .utf8),
           Self.isValidLibrary(json)
        {
            cachedJSON = json
        } else {
            cachedJSON = nil
        }
        hasLoadedCache = true
        return cachedJSON
    }

    @discardableResult
    func save(_ json: String) throws -> Bool {
        guard Self.isValidLibrary(json), let data = json.data(using: .utf8) else {
            throw DashboardError.invalidPromptLibrary
        }
        guard load() != json else { return false }
        try FileManager.default.createDirectory(
            at: backupURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: backupURL, options: .atomic)
        cachedJSON = json
        hasLoadedCache = true
        return true
    }

    nonisolated static func isValidLibrary(_ json: String) -> Bool {
        guard let data = json.data(using: .utf8),
              let library = try? JSONDecoder().decode(Library.self, from: data)
        else { return false }
        return (library.version == nil || library.version == 2)
            && Set(library.prompts.map(\.id)).count == library.prompts.count
            && library.prompts.allSatisfy { $0.scope?.isValid ?? true }
    }
}
