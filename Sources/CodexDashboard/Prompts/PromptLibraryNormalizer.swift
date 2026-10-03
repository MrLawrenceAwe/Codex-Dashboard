import Foundation

enum PromptLibraryNormalizer {
    static func normalize(_ document: PromptLibraryDocument) -> PromptLibraryDocument {
        guard document.version == 3 else { return document }
        return PromptLibraryDocument(
            version: PromptLibrarySchema.currentVersion,
            prompts: document.prompts.map { prompt in
                SavedPrompt(
                    id: prompt.id,
                    name: prompt.name,
                    content: prompt.content,
                    section: prompt.section,
                    scope: prompt.scope,
                    preset: prompt.preset.map(normalize),
                    usePreset: prompt.usePreset
                )
            },
            sections: document.sections
        )
    }

    private static func normalize(_ preset: SavedPromptPreset) -> SavedPromptPreset {
        SavedPromptPreset(
            model: preset.model,
            reasoningEffort: preset.reasoningEffort == "light" ? "low" : preset.reasoningEffort,
            speed: preset.speed
        )
    }
}
