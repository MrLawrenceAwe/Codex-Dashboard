import Foundation

struct PromptLibraryDocument: Codable, Equatable, Sendable {
    static let empty = PromptLibraryDocument(version: 3, prompts: [], sections: [])

    let version: Int
    let prompts: [SavedPrompt]
    let sections: [String]

    var isValid: Bool {
        version == 3
            && Set(prompts.map(\.id)).count == prompts.count
            && prompts.allSatisfy(\.isValid)
    }

    var migratingLegacyReasoningEffort: PromptLibraryDocument {
        PromptLibraryDocument(
            version: version,
            prompts: prompts.map(\.migratingLegacyReasoningEffort),
            sections: sections
        )
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

    var migratingLegacyReasoningEffort: SavedPrompt {
        SavedPrompt(
            id: id,
            name: name,
            content: content,
            section: section,
            scope: scope,
            preset: preset?.migratingLegacyReasoningEffort,
            usePreset: usePreset
        )
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
    private static let reasoningEffortValues: Set<String> = [
        "light", "medium", "high", "xhigh",
    ]
    private static let speedValues: Set<String> = ["standard", "fast"]

    let model: String?
    let reasoningEffort: String?
    let speed: String?

    var isValid: Bool {
        model.map { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? true
            && (reasoningEffort.map(Self.reasoningEffortValues.contains) ?? true)
            && (speed.map(Self.speedValues.contains) ?? true)
    }

    var migratingLegacyReasoningEffort: SavedPromptPreset {
        SavedPromptPreset(
            model: model,
            reasoningEffort: reasoningEffort == "low" ? "light" : reasoningEffort,
            speed: speed
        )
    }
}
