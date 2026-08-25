import Foundation

enum PromptLibrarySchema {
    static let currentVersion = 3
    static let defaultSection = "General"
    static let defaultModel = "gpt-5.6-sol"
    static let defaultReasoningEffort = "medium"
    static let defaultSpeed = "standard"
    static let reasoningEfforts = ["light", "medium", "high", "xhigh"]
    static let speeds = ["standard", "fast"]

    static var javascriptDeclaration: String {
        let schema: [String: Any] = [
            "version": currentVersion,
            "defaultSection": defaultSection,
            "defaults": [
                "model": defaultModel,
                "reasoningEffort": defaultReasoningEffort,
                "speed": defaultSpeed,
            ],
            "reasoningEfforts": reasoningEfforts,
            "speeds": speeds,
        ]
        let data = try! JSONSerialization.data(withJSONObject: schema, options: [.sortedKeys])
        return "const PROMPT_LIBRARY_SCHEMA = Object.freeze(\(String(decoding: data, as: UTF8.self)));"
    }
}

struct PromptLibraryDocument: Codable, Equatable, Sendable {
    static let empty = PromptLibraryDocument(
        version: PromptLibrarySchema.currentVersion,
        prompts: [],
        sections: []
    )

    let version: Int
    let prompts: [SavedPrompt]
    let sections: [String]

    var isValid: Bool {
        version == PromptLibrarySchema.currentVersion
            && Set(prompts.map(\.id)).count == prompts.count
            && prompts.allSatisfy(\.isValid)
    }

}

struct SavedPrompt: Codable, Equatable, Sendable {
    let id: String
    let name: String
    let content: String
    let section: String?
    let scope: SavedPromptScope
    let preset: SavedPromptPreset?
    let usePreset: Bool?

    var isValid: Bool {
        !id.isEmpty && !name.isEmpty && !content.isEmpty && scope.isValid && (preset?.isValid ?? true)
    }

}

struct SavedPromptScope: Codable, Equatable, Sendable {
    let type: String
    let projectPath: String?

    var isValid: Bool {
        type == "global" || (type == "project" && !(projectPath ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
}

struct SavedPromptPreset: Codable, Equatable, Sendable {
    private static let reasoningEffortValues = Set(PromptLibrarySchema.reasoningEfforts)
    private static let speedValues = Set(PromptLibrarySchema.speeds)

    let model: String?
    let reasoningEffort: String?
    let speed: String?

    var isValid: Bool {
        model.map { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? true
            && (reasoningEffort.map(Self.reasoningEffortValues.contains) ?? true)
            && (speed.map(Self.speedValues.contains) ?? true)
    }

}
