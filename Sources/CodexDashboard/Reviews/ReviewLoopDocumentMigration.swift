import Foundation

/// Converts the unversioned single-loop and array formats into the current document.
enum ReviewLoopDocumentMigration {
    struct Document: Codable {
        static let currentVersion = 4
        let version: Int
        let loops: [ReviewLoop]
    }

    static func decode(_ data: Data) throws -> [ReviewLoop] {
        let value = try JSONSerialization.jsonObject(with: data)
        if let document = value as? [String: Any], let version = document["version"] as? Int {
            guard (1...Document.currentVersion).contains(version) else {
                throw ReviewLoopError("Unsupported review-loop document version \(version).")
            }
            if version == Document.currentVersion {
                return try JSONDecoder().decode(Document.self, from: data).loops
            }
            guard let saved = document["loops"] as? [[String: Any]] else { throw ReviewLoopError("Invalid review-loop document.") }
            return try JSONDecoder().decode([ReviewLoop].self, from: JSONSerialization.data(withJSONObject: saved.map(migrate)))
        }
        let savedLoops = value as? [[String: Any]] ?? (value as? [String: Any]).map { [$0] }
        guard let savedLoops else { throw ReviewLoopError("Invalid review-loop document.") }
        let migrated = savedLoops.map(migrate)
        return try JSONDecoder().decode([ReviewLoop].self, from: JSONSerialization.data(withJSONObject: migrated))
    }

    private static func migrate(_ saved: [String: Any]) -> [String: Any] {
        var loop = saved
        if loop["focus"] as? String == "naming" { loop["focus"] = "organisationAndNaming" }
        if loop["liveTesting"] == nil { loop["liveTesting"] = false }
        if loop["pushToRemote"] == nil { loop["pushToRemote"] = false }
        if loop["promptContext"] == nil {
            if let context = loop["projectType"] {
                loop["promptContext"] = context
            } else if let instructions = loop["instructions"] as? String {
                let kind: String
                switch instructions {
                case "": kind = "general"
                case "(this is a project for personal use)": kind = "personal"
                default: kind = "savedContext"
                }
                loop["promptContext"] = kind == "savedContext"
                    ? ["kind": kind, "context": instructions] : ["kind": kind]
            }
        }
        loop.removeValue(forKey: "projectType")
        loop.removeValue(forKey: "instructions")

        let previousSelection = loop["selection"] as? [String: Any]
        for key in ["reviewSelection", "fixSelection"] {
            if let selection = (loop[key] as? [String: Any]) ?? previousSelection {
                var current = selection
                if current["modelID"] == nil { current["modelID"] = current["model"] }
                if current["reasoningEffort"] == nil { current["reasoningEffort"] = current["effort"] }
                current.removeValue(forKey: "model")
                current.removeValue(forKey: "effort")
                loop[key] = current
            }
        }
        loop.removeValue(forKey: "selection")
        if loop["focus"] == nil { loop["focus"] = "bugs" }
        if loop["speed"] == nil { loop["speed"] = "standard" }
        if loop["priorityLimit"] == nil && ["bugs", "performance"].contains(loop["focus"] as? String ?? "") {
            loop["priorityLimit"] = "P2"
        }
        return loop
    }
}
