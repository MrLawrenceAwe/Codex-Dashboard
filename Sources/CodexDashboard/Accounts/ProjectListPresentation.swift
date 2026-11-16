import Foundation

/// Native sidebar IDs may predate app-server IDs. Translate the existing mapping
/// rather than copying account state or writing a running app's preferences file.
struct ProjectListPresentation {
    let order: [String]
    let pinned: [String]
    let rawOrder: [String]
    let rawPinned: [String]
    let unmapped: Set<String>
    let inactiveAliasesByServer: [String: Set<String>]
    let legacyByServer: [String: String]
    static func read(home: URL, projects: [CodexProject]) throws -> Self {
        let file = home.appendingPathComponent(".codex-global-state.json")
        let state = FileManager.default.fileExists(atPath: file.path)
            ? (try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any] ?? [:]) : [:]
        let ids = Set(projects.map(\.id))
        let hosts = state["app-server-project-id-by-legacy-project-id-by-host"] as? [String: [String: String]] ?? [:]
        var serverByLegacy: [String: String] = [:], legacyByServer: [String: String] = [:]
        for host in hosts.keys.sorted() {
            for (legacy, server) in hosts[host]!.sorted(by: { $0.key < $1.key }) where ids.contains(server) {
                serverByLegacy[legacy] = server
                if legacyByServer[server] == nil { legacyByServer[server] = legacy }
            }
        }
        func translate(_ key: String) -> [String] {
            var seen = Set<String>()
            return (state[key] as? [String] ?? []).compactMap {
                let id = ids.contains($0) ? $0 : serverByLegacy[$0]
                guard let id, seen.insert(id).inserted else { return nil }; return id
            }
        }
        let rawOrder = state["project-order"] as? [String] ?? []
        let rawPinned = state["pinned-project-ids"] as? [String] ?? []
        let unmapped = Set(rawOrder + rawPinned).filter { !ids.contains($0) && serverByLegacy[$0] == nil }
        var inactiveAliases: [String: Set<String>] = [:]
        for host in hosts.values {
            for (legacy, server) in host where serverByLegacy[legacy] == nil {
                inactiveAliases[server, default: []].insert(legacy)
            }
        }
        return .init(order: translate("project-order"), pinned: translate("pinned-project-ids"),
                     rawOrder: rawOrder, rawPinned: rawPinned, unmapped: unmapped, inactiveAliasesByServer: inactiveAliases, legacyByServer: legacyByServer)
    }
    func merging(localIDs: [String], into original: [String], removing: Set<String> = []) -> [String] {
        let desired = localIDs.map { legacyByServer[$0] ?? $0 }
        var result: [String] = [], index = 0
        let removedAliases = removing.reduce(into: removing) { $0.formUnion(inactiveAliasesByServer[$1] ?? []) }
        for id in original where !removedAliases.contains(id) {
            if unmapped.contains(id) { result.append(id) }
            else if index < desired.count { result.append(desired[index]); index += 1 }
        }
        result += desired.dropFirst(index)
        return result
    }
}
