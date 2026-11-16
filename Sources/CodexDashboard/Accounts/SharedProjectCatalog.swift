import Foundation

/// A three-way merge baseline for the shared folder list. Chats never enter it.
struct SharedProjectCatalog: Codable, Equatable {
    static let marker = "codex-dashboard-shared-project-id"
    struct Value: Codable, Equatable {
        var name: String
        var roots: [CodexProject.Root]
        var metadata: [String: String]
        init(_ project: CodexProject) {
            name = project.name; roots = project.roots; metadata = project.metadata
            metadata.removeValue(forKey: SharedProjectCatalog.marker)
        }
        func project(id: String) -> CodexProject {
            .init(id: id, name: name, roots: roots, metadata: metadata)
        }
    }
    struct Replica: Codable, Equatable {
        var links: [String: String] = [:]
        var observed: [String: Value] = [:]
        var order: [String] = []
        var pinned: [String]?
        var retiredLocalIDs = Set<String>()
    }
    var version = 1
    var projects: [String: Value] = [:]
    var order: [String] = []
    var pinned: [String] = []
    var deleted = Set<String>()
    var replicas: [String: Replica] = [:]

    /// Windows connected to the same server share its project IDs. Reuse the
    /// main replica's identity even before a new project's marker is written.
    mutating func alignSharedBackend(replicaID: String, snapshot: [CodexProject]) {
        guard let main = replicas["main"] else { return }
        for project in snapshot {
            if let sharedID = main.links[project.id] {
                replicas[replicaID, default: Replica()].links[project.id] = sharedID
            }
        }
    }

    mutating func observe(replicaID: String, snapshot: [CodexProject]) {
        let fresh = replicas[replicaID] == nil
        var replica = replicas[replicaID] ?? Replica()
        let present = Set(snapshot.map(\.id))
        if !fresh {
            for (localID, sharedID) in replica.links where !present.contains(localID) {
                if replica.observed[localID] != nil {
                    replica.retiredLocalIDs.insert(localID)
                    projects.removeValue(forKey: sharedID)
                    order.removeAll { $0 == sharedID }
                    deleted.insert(sharedID)
                    pinned.removeAll { $0 == sharedID }
                }
            }
        }
        var claimed = Set(replica.links.filter { present.contains($0.key) }.map(\.value))
        var added = false
        for project in snapshot {
            let value = Value(project)
            var sharedID = replica.links[project.id]
            if sharedID == nil, let marker = project.metadata[Self.marker], !claimed.contains(marker),
               projects[marker] != nil || deleted.contains(marker) {
                sharedID = marker
            }
            if sharedID == nil, fresh {
                // Adopt identical imports once. A folder can belong to multiple
                // groups with different names or metadata.
                sharedID = order.first { !claimed.contains($0) && projects[$0] == value }
            }
            if sharedID == nil {
                let id = UUID().uuidString
                sharedID = id; projects[id] = value; order.append(id); added = true
            }
            guard let id = sharedID else { continue }
            claimed.insert(id)
            replica.links[project.id] = id
            if let base = replica.observed[project.id], var merged = projects[id] {
                if value.name != base.name { merged.name = value.name }
                if value.roots != base.roots { merged.roots = value.roots }
                for key in Set(base.metadata.keys).union(value.metadata.keys) where base.metadata[key] != value.metadata[key] {
                    merged.metadata[key] = value.metadata[key]
                }
                projects[id] = merged
            }
        }
        let currentOrder = snapshot.compactMap { replica.links[$0.id] }.filter { projects[$0] != nil }
        let common = Set(currentOrder).intersection(replica.order)
        let reordered = replica.order.filter { common.contains($0) } != currentOrder.filter { common.contains($0) }
        if !fresh, added || reordered {
            let included = Set(currentOrder)
            order = currentOrder + order.filter { !included.contains($0) }
        }
        replica.links = replica.links.filter { present.contains($0.key) }
        replica.observed = Dictionary(uniqueKeysWithValues: snapshot.map { ($0.id, Value($0)) })
        replica.order = currentOrder
        replicas[replicaID] = replica
    }

    mutating func observePinned(replicaID: String, localIDs: [String]) {
        guard var replica = replicas[replicaID] else { return }
        let current = localIDs.compactMap { replica.links[$0] }.filter { projects[$0] != nil }
        if let previous = replica.pinned {
            let removed = Set(previous).subtracting(current)
            pinned.removeAll { removed.contains($0) }
            for id in current where !previous.contains(id) && !pinned.contains(id) { pinned.append(id) }
        } else if replicaID == "main" { pinned = current }
        replica.pinned = current
        replicas[replicaID] = replica
    }

    mutating func retire(replicaID: String, localID: String) {
        replicas[replicaID]?.retiredLocalIDs.insert(localID)
        replicas[replicaID]?.links.removeValue(forKey: localID)
        replicas[replicaID]?.observed.removeValue(forKey: localID)
    }

    mutating func acknowledgeProject(replicaID: String, localID: String, sharedID: String, value: Value) {
        replicas[replicaID]?.links[localID] = sharedID
        replicas[replicaID]?.observed[localID] = value
    }

    mutating func acknowledgePresentation(replicaID: String, order: [String], pinned: [String]) {
        guard var replica = replicas[replicaID] else { return }
        replica.order = order.compactMap { replica.links[$0] }
        replica.pinned = pinned.compactMap { replica.links[$0] }
        replicas[replicaID] = replica
    }
}
