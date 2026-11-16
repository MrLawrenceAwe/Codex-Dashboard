import Foundation

/// Synchronizes project registrations through each window's own app-server so
/// Codex receives its normal project-change notifications and refreshes its UI.
@MainActor
final class SharedProjectSynchronizer {
    private let file: URL
    private var catalog: SharedProjectCatalog
    private var connections: [String: ProjectSyncConnection] = [:]
    private(set) var lastError: String?

    init(file: URL = CodexConfiguration.dashboardSupportDirectory().appendingPathComponent("shared-projects.json")) throws {
        self.file = file
        if FileManager.default.fileExists(atPath: file.path) {
            catalog = try JSONDecoder().decode(SharedProjectCatalog.self, from: Data(contentsOf: file))
            guard catalog.version == 1 else { throw DashboardError.synchronizationFailed("Unsupported shared project list version.") }
        } else { catalog = SharedProjectCatalog() }
    }

    func synchronize(endpoints: [(id: String, home: URL, port: @Sendable () -> Int)]) async {
        let live = Set(endpoints.map(\.id))
        for id in Array(connections.keys) where !live.contains(id) {
            if let removed = connections.removeValue(forKey: id) { await removed.disconnect() }
        }
        for endpoint in endpoints where connections[endpoint.id] == nil {
            connections[endpoint.id] = ProjectSyncConnection(id: endpoint.id, home: endpoint.home, port: endpoint.port)
        }
        do {
            var snapshots: [String: [CodexProject]] = [:]
            var readError: String?
            for endpoint in endpoints {
                do { snapshots[endpoint.id] = try await connections[endpoint.id]?.snapshot() }
                catch { readError = error.localizedDescription }
            }
            guard catalog.replicas["main"] != nil || snapshots["main"] != nil else {
                lastError = readError
                return
            }
            // Shared windows project one catalog. A partial read from another
            // window is never evidence that its projects were deleted.
            for id in Array(snapshots.keys) where id.hasPrefix("shared:") {
                if let main = snapshots["main"], let replica = snapshots[id],
                   Set(main.map(\.id)) == Set(replica.map(\.id)) { continue }
                snapshots.removeValue(forKey: id)
            }
            let order = snapshots.keys.sorted { a, b in a == "main" || (b != "main" && a < b) }
            for id in order {
                if id.hasPrefix("shared:") { catalog.alignSharedBackend(replicaID: id, snapshot: snapshots[id]!) }
                catalog.observe(replicaID: id, snapshot: snapshots[id]!)
                if let connection = connections[id] {
                    catalog.observePinned(replicaID: id, localIDs: try connection.pinned(in: snapshots[id]!))
                }
            }
            // Persist the merged intent before writes. Create requests are
            // idempotent and carry the shared ID for recovery after interruption.
            try save()
            for id in order {
                guard let connection = connections[id], let snapshot = snapshots[id] else { continue }
                do { try await apply(to: connection, snapshot: snapshot) }
                catch { readError = error.localizedDescription }
            }
            lastError = readError
        } catch { lastError = error.localizedDescription }
    }

    private func apply(to connection: ProjectSyncConnection, snapshot: [CodexProject]) async throws {
        let id = connection.id
        guard let replica = catalog.replicas[id] else { return }
        // Do not overwrite edits made while other windows were being read.
        guard try await connection.snapshot() == snapshot else { return }
        var changed = false
        if !id.hasPrefix("shared:") {
            for project in snapshot {
                guard let sharedID = replica.links[project.id] else { continue }
                if catalog.deleted.contains(sharedID) {
                    try await connection.delete(localID: project.id)
                    catalog.retire(replicaID: id, localID: project.id)
                } else if let value = catalog.projects[sharedID],
                          value != SharedProjectCatalog.Value(project) || project.metadata[SharedProjectCatalog.marker] != sharedID {
                    try await connection.update(localID: project.id, sharedID: sharedID, value: value)
                    catalog.acknowledgeProject(replicaID: id, localID: project.id, sharedID: sharedID, value: value)
                } else {
                    continue
                }
                try save()
                changed = true
            }
            let mapped = Set(snapshot.compactMap { replica.links[$0.id] })
            for sharedID in catalog.order where !mapped.contains(sharedID) {
                guard let value = catalog.projects[sharedID] else { continue }
                let localID = try await connection.create(sharedID: sharedID, value: value)
                catalog.acknowledgeProject(replicaID: id, localID: localID, sharedID: sharedID, value: value)
                try save()
                changed = true
            }
        }
        // A read after our writes can include concurrent user edits. Keep the
        // baseline tied to the operations we acknowledged.
        let actual = changed ? try await connection.snapshot() : snapshot
        let links = catalog.replicas[id]?.links ?? [:]
        var localByShared: [String: String] = [:]
        for project in actual {
            if let sharedID = links[project.id], localByShared[sharedID] == nil {
                localByShared[sharedID] = project.id
            }
        }
        let desired = catalog.order.compactMap { localByShared[$0] }
        let desiredPinned = catalog.pinned.compactMap { localByShared[$0] }
        // A mode change switches this window to a different server's IDs. Drop
        // only the old presentation entries, never delete those registrations.
        let otherBackend = id == "main" ? nil : id.hasPrefix("shared:") ? String(id.dropFirst("shared:".count)) : "shared:" + id
        let previousIDs = otherBackend.flatMap { catalog.replicas[$0] }.map { Set($0.observed.keys) } ?? []
        let obsoletePresentation = previousIDs.subtracting(actual.map(\.id))
        let removed = (catalog.replicas[id]?.retiredLocalIDs ?? []).union(obsoletePresentation)
        try await connection.refreshSidebar(snapshot: actual, removing: removed)
        try await connection.setPresentation(order: desired, pinned: desiredPinned, snapshot: actual, removing: removed)
        catalog.acknowledgePresentation(replicaID: id, order: desired, pinned: desiredPinned)
        try save()
    }

    private func save() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(catalog)
        if (try? Data(contentsOf: file)) == data { return }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    func disconnect() async {
        for connection in connections.values { await connection.disconnect() }
        connections.removeAll()
    }
}
