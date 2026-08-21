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
        let preset: Preset?
        let usePreset: Bool?
    }

    private struct Preset: Decodable {
        let model: String?
        let reasoningEffort: String?
        let speed: String?

        var isValid: Bool {
            (model.map(Self.models.contains) ?? true)
                && (reasoningEffort.map(Self.reasoningEfforts.contains) ?? true)
                && (speed.map(Self.speeds.contains) ?? true)
        }

        private static let models: Set<String> = [
            "gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna", "gpt-5.5", "gpt-5.4", "gpt-5.4-mini",
        ]
        private static let reasoningEfforts: Set<String> = ["low", "medium", "high", "xhigh"]
        private static let speeds: Set<String> = ["standard", "fast"]
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
        // Version 2 remains readable so an on-disk backup cannot strand user prompts during migration.
        return (library.version == nil || library.version == 2 || library.version == 3)
            && Set(library.prompts.map(\.id)).count == library.prompts.count
            && library.prompts.allSatisfy { $0.scope?.isValid ?? true }
            && library.prompts.allSatisfy { $0.preset?.isValid ?? true }
    }
}
