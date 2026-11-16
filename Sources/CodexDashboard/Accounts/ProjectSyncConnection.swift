import Foundation

@MainActor
final class ProjectSyncConnection {
    let id: String
    let client: DevToolsClient
    let home: URL
    init(id: String, home: URL, port: @escaping @Sendable () -> Int) {
        self.id = id
        self.home = home
        client = DevToolsClient(portProvider: port)
    }
    func disconnect() async { await client.disconnect() }

    func request(_ method: String, _ params: [String: Any]) async throws -> Data {
        guard let target = await client.mainRendererTargets().first else { throw DashboardError.rendererTimedOut }
        let input = try JSONSerialization.data(withJSONObject: ["method": method, "params": params])
        let script = "window.__codexDashboard?.projectRequest?.(\(String(decoding: input, as: UTF8.self))) ?? null"
        guard let response = try await client.evaluateString(script, in: target, timeout: .seconds(23)) else {
            throw DashboardError.synchronizationFailed("The project connection is not ready.")
        }
        let data = Data(response.utf8)
        if let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], let error = object["error"] as? [String: Any] {
            throw DashboardError.synchronizationFailed(error["message"] as? String ?? "Project request failed.")
        }
        return data
    }

    func snapshot() async throws -> [CodexProject] {
        struct Page: Decodable {
            struct Result: Decodable { let data: [CodexProject]; let nextCursor: String? }
            let result: Result
        }
        var projects: [CodexProject] = [], cursor: String?
        repeat {
            var params: [String: Any] = ["limit": 100, "sortKey": "position"]
            if let cursor { params["cursor"] = cursor }
            let page = try JSONDecoder().decode(Page.self, from: await request("project/list", params))
            projects += page.result.data; cursor = page.result.nextCursor
        } while cursor != nil
        // Account-bound remote projects are not part of the shared local list.
        let local = projects.filter { !$0.roots.isEmpty && $0.roots.allSatisfy { $0.path.hasPrefix("/") } }
        let presentation = try await presentation(projects: local)
        let byID = Dictionary(uniqueKeysWithValues: local.map { ($0.id, $0) })
        let known = Set(presentation.order)
        return presentation.order.compactMap { byID[$0] } + local.filter { !known.contains($0.id) }
    }

    func pinned(in snapshot: [CodexProject]) async throws -> [String] {
        try await presentation(projects: snapshot).pinned
    }

    func setPresentation(order: [String], pinned: [String], snapshot: [CodexProject], removing: Set<String> = []) async throws {
        let current = try await presentation(projects: snapshot)
        let rawOrder = current.merging(localIDs: order, into: current.rawOrder, removing: removing)
        let rawPinned = current.merging(localIDs: pinned, into: current.rawPinned, removing: removing)
        guard current.rawOrder != rawOrder || current.rawPinned != rawPinned else { return }
        let request: [String: [String]] = [
            "order": current.rawOrder == rawOrder ? [] : rawOrder,
            "pinned": rawPinned,
        ]
        let data = try JSONSerialization.data(withJSONObject: request)
        let updateOrder = current.rawOrder != rawOrder
        let updatePins = current.rawPinned != rawPinned
        try await useNativeProjectServices(input: data, body: """
          if (\(updateOrder) && typeof services.projects?.setProjectOrder !== 'function') return false;
          if (\(updatePins) && typeof services.projectPresentation?.setPinnedProjects !== 'function') return false;
          if (\(updateOrder)) await services.projects.setProjectOrder(request.order);
          if (\(updatePins)) await services.projectPresentation.setPinnedProjects(request.pinned);
          return true;
        """)
        let deadline = ContinuousClock.now + .seconds(3)
        repeat {
            let saved = try await presentation(projects: snapshot)
            if saved.rawOrder == rawOrder && saved.rawPinned == rawPinned { return }
            try await Task.sleep(for: .milliseconds(50))
        } while ContinuousClock.now < deadline
        throw DashboardError.synchronizationFailed("Codex did not confirm the shared project order and pins.")
    }

    func refreshSidebar(snapshot: [CodexProject], removing: Set<String>) async throws {
        let presentation = try await presentation(projects: snapshot)
        let removedIDs = removing.reduce(into: removing.union(presentation.duplicateAliases)) {
            $0.formUnion(presentation.inactiveAliasesByServer[$1] ?? [])
        }
        let projects: [[String: Any]] = snapshot.compactMap { project in
            let localID = presentation.legacyByServer[project.id] ?? project.id
            let folders = project.roots.map(\.path)
            return ["id": localID, "name": project.name, "rootPaths": folders]
        }
        let deletions = removedIDs
        guard !projects.isEmpty || !deletions.isEmpty else { return }
        let data = try JSONSerialization.data(withJSONObject: ["projects": projects, "removed": Array(deletions)])
        try await useNativeProjectServices(input: data, body: """
          if (typeof services.applicationState?.write !== 'function' ||
              typeof services.projectCatalog?.readLocalProjects !== 'function') return false;
          const current = await services.projectCatalog.readLocalProjects() ?? {};
          const next = { ...current };
          let changed = false;
          for (const id of request.removed) {
            if (next[id] === undefined) continue;
            delete next[id];
            changed = true;
          }
          for (const project of request.projects) {
            const existing = current[project.id];
            if (existing?.name === project.name &&
                JSON.stringify(existing.rootPaths) === JSON.stringify(project.rootPaths)) continue;
            changed = true;
            next[project.id] = {
              ...existing, ...project, createdAt: existing?.createdAt ?? Date.now(), updatedAt: Date.now()
            };
          }
          if (!changed) return true;
          const result = await services.applicationState.write('local-projects', next);
          return result?.success === true;
        """)
    }

    private func presentation(projects: [CodexProject]) async throws -> ProjectListPresentation {
        guard let target = await client.mainRendererTargets().first else { throw DashboardError.rendererTimedOut }
        let input = try JSONSerialization.data(withJSONObject: ["project-order", "pinned-project-ids", "app-server-project-id-by-legacy-project-id-by-host"])
        let script = Self.nativeProjectServicesExpression(input: input, body: """
          const values = await Promise.all(request.map(key => services.applicationState.read(key)));
          const state = Object.fromEntries(request.map((key, i) => [key, values[i]?.value]));
          state['local-projects'] = await services.projectCatalog.readLocalProjects() ?? {};
          return JSON.stringify(state);
        """)
        guard let raw = try await client.evaluateString(script, in: target, timeout: .seconds(10)),
              let state = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any] else {
            throw DashboardError.synchronizationFailed("Codex’s live project presentation is unavailable.")
        }
        return ProjectListPresentation.read(state: state, projects: projects)
    }

    private func useNativeProjectServices(input: Data, body: String) async throws {
        guard let target = await client.mainRendererTargets().first else { throw DashboardError.rendererTimedOut }
        let script = Self.nativeProjectServicesExpression(input: input, body: body)
        guard try await client.evaluateBoolean(script, in: target) else {
            throw DashboardError.synchronizationFailed("Codex’s native project controls are unavailable.")
        }
    }

    private static func nativeProjectServicesExpression(input: Data, body: String) -> String {
        """
        (async () => {
          const request = \(String(decoding: input, as: UTF8.self));
          // Use the already loaded renderer runtime. Codex hashes the entry
          // script and uses different module IDs across desktop builds.
          const entry = [...document.scripts].reverse().find(script =>
            script.type === 'module' && script.src.startsWith(location.origin + '/assets/'));
          if (!entry) return false;
          const runtime = (await import(entry.src)).__webpack_require__;
          if (!runtime?.m) return false;
          const moduleID = Object.keys(runtime.m).find(id => {
            const factory = String(runtime.m[id]);
            return factory.includes('setAppServices:') && factory.includes('appServices:');
          });
          const services = moduleID && runtime(moduleID).appServices;
          if (!services) return false;
          \(body)
        })()
        """
    }

    func create(sharedID: String, value: SharedProjectCatalog.Value) async throws -> String {
        var metadata = value.metadata; metadata[SharedProjectCatalog.marker] = sharedID
        let data = try await request("project/create", ["idempotencyKey": "dashboard-shared-\(sharedID)",
            "name": value.name, "roots": value.roots.map { ["path": $0.path] }, "metadata": metadata])
        struct Response: Decodable { struct Result: Decodable { let project: CodexProject }; let result: Result }
        return try JSONDecoder().decode(Response.self, from: data).result.project.id
    }

    func update(localID: String, sharedID: String, value: SharedProjectCatalog.Value) async throws {
        var metadata = value.metadata; metadata[SharedProjectCatalog.marker] = sharedID
        _ = try await request("project/update", ["projectId": localID, "name": value.name,
            "roots": value.roots.map { ["path": $0.path] }, "metadata": metadata])
    }
    func delete(localID: String) async throws { _ = try await request("project/delete", ["projectId": localID]) }
    func move(localID: String, before: String?) async throws {
        _ = try await request("project/move", ["projectId": localID, "beforeProjectId": before as Any? ?? NSNull()])
    }
}
