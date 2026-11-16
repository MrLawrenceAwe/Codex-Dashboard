import Foundation

/// Codex migrates its legacy sidebar on first contact with a new server home.
/// Register aliases for the broker's home before either renderer connects.
enum SharedChatProjectAliases {
    static let mappingKey = "app-server-project-id-by-legacy-project-id-by-host"
    static let projectsKey = "local-projects"

    static func prepare(configuration: ChatHandoffServer.Configuration, catalog: SharedProjectCatalog,
                        validateOnly: Bool = false, mainOnly: Bool = false) throws {
        let historyHome = configuration.historyHome
        let mainState = try readState(at: historyHome)
        let mainHost = "local:\(historyHome.path)"
        let sharedHost = "local:\(configuration.root.appendingPathComponent("owner").path)"
        let mainAliases = mappings(in: mainState)[mainHost] ?? [:]
        let mainLinks = catalog.replicas["main"]?.links ?? [:]
        let actualIDs = try projectIDs(at: historyHome)
        var mainByShared: [String: String] = [:]
        for (projectID, sharedID) in mainLinks where actualIDs.contains(projectID) {
            guard mainByShared.updateValue(projectID, forKey: sharedID) == nil else { throw ChatHandoffError.projectAliases }
        }

        // Validate every profile before writing any state.
        let updates = try configuration.windows.compactMap { window -> (URL, Data)? in
            guard !mainOnly || window.id == "main" else { return nil }
            let state = try readState(at: window.home)
            let projects = state[projectsKey] as? [String: Any] ?? [:]
            guard !projects.isEmpty else { return nil }
            let allMappings = mappings(in: state)
            let oldAliases = allMappings["local:\(window.home.path)"] ?? [:]
            // Use the saved replica links to distinguish intentionally separate
            // projects with identical names and folders.
            let replicaKey = UUID(uuidString: window.id)?.uuidString ?? window.id
            let windowLinks = catalog.replicas[replicaKey]?.links ?? [:]
            let shared = try aliases(
                for: Set(projects.keys), actualIDs: actualIDs,
                oldAliases: oldAliases, windowLinks: windowLinks,
                mainByShared: mainByShared, mainAliases: mainAliases,
                previous: allMappings[sharedHost] ?? [:], main: window.id == "main"
            )
            var updated = state
            var hosts = allMappings
            guard hosts[sharedHost] != shared else { return nil }
            hosts[sharedHost] = shared
            updated[mappingKey] = hosts
            return (window.home.appendingPathComponent(".codex-global-state.json"),
                try JSONSerialization.data(withJSONObject: updated, options: [.sortedKeys]))
        }
        guard !validateOnly else { return }
        for (file, data) in updates { try data.write(to: file, options: .atomic) }
    }

    static func aliases(
        for keys: Set<String>, actualIDs: Set<String>, oldAliases: [String: String],
        windowLinks: [String: String], mainByShared: [String: String],
        mainAliases: [String: String], previous: [String: String], main: Bool
    ) throws -> [String: String] {
        var result = previous.filter { actualIDs.contains($0.value) }
        for key in keys {
            let oldID = oldAliases[key] ?? key
            let linked = windowLinks[oldID].flatMap { mainByShared[$0] }
            let canonical = main ? mainAliases[key] : linked
            let candidates = [canonical, actualIDs.contains(key) ? key : nil, result[key]]
            guard let id = candidates.compactMap({ $0 }).first(where: actualIDs.contains) else {
                throw ChatHandoffError.projectAliases
            }
            result[key] = id
        }
        return result
    }

    private static func mappings(in state: [String: Any]) -> [String: [String: String]] {
        state[mappingKey] as? [String: [String: String]] ?? [:]
    }

    private static func readState(at home: URL) throws -> [String: Any] {
        let file = home.appendingPathComponent(".codex-global-state.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return [:] }
        guard let state = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any] else {
            throw ChatHandoffError.projectAliases
        }
        return state
    }

    private static func projectIDs(at home: URL) throws -> Set<String> {
        let database = home.appendingPathComponent("state_5.sqlite")
        guard FileManager.default.fileExists(atPath: database.path) else { return [] }
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = ["-readonly", "-batch", database.path, "SELECT id FROM projects;"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw ChatHandoffError.projectAliases }
        return Set(String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).map(String.init))
    }
}
