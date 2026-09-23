import Foundation

enum ComposerPresetSchema {
    static let defaultModel = "gpt-6-astra"
    static let defaultReasoningEffort = "medium"
    static let defaultSpeed = "standard"
    static let reasoningEfforts = ["light", "medium", "high", "xhigh", "max", "ultra"]
    static let speeds = ["standard", "fast"]

    static var javascriptDeclaration: String {
        let schema: [String: Any] = [
            "defaults": [
                "model": defaultModel,
                "reasoningEffort": defaultReasoningEffort,
                "speed": defaultSpeed,
            ],
            "reasoningEfforts": reasoningEfforts,
            "speeds": speeds,
        ]
        let data = try! JSONSerialization.data(withJSONObject: schema, options: [.sortedKeys])
        return "const COMPOSER_PRESET_SCHEMA = Object.freeze(\(String(decoding: data, as: UTF8.self)));"
    }
}
