import Foundation

enum PromptLibraryMigration {
    static func migrate(_ document: PromptLibraryDocument) -> PromptLibraryDocument {
        PromptLibraryDocument(
            version: document.version,
            prompts: document.prompts.map { prompt in
                SavedPrompt(
                    id: prompt.id,
                    name: prompt.name,
                    content: prompt.content,
                    section: prompt.section,
                    scope: prompt.scope,
                    preset: prompt.preset.map(migrate),
                    usePreset: prompt.usePreset
                )
            },
            sections: document.sections
        )
    }

    private static func migrate(_ preset: SavedPromptPreset) -> SavedPromptPreset {
        SavedPromptPreset(
            model: preset.model,
            reasoningEffort: preset.reasoningEffort == "low" ? "light" : preset.reasoningEffort,
            speed: preset.speed
        )
    }
}
