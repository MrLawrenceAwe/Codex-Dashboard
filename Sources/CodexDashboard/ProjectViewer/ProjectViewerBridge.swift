import Foundation

@MainActor
final class ProjectViewerBridge {
    struct Request: Decodable {
        let id: String
        let path: String
        let projectID: String?
        var threadID: String? = nil
    }
    private let catalog: CodexThreadCatalogProvider

    init(catalog: CodexThreadCatalogProvider = CodexThreadCatalogProvider()) {
        self.catalog = catalog
    }
    private var handledIDs = Set<String>()
    private var handledOrder: [String] = []
    private var openTask: Task<Void, Never>?

    func cancelPendingOpen() {
        openTask?.cancel()
        openTask = nil
    }

    func allowedRoot(_ request: Request, threads: [RendererThread]) async -> URL? {
        guard request.path.hasPrefix("/") else { return nil }
        if let threadID = request.threadID {
            guard request.projectID == nil, threads.contains(where: {
                $0.id == threadID && $0.checkoutPath == request.path
            }) else { return nil }
        } else if let projectID = request.projectID {
            guard !projectID.isEmpty,
                  (try? await catalog.savedProjectContainsRoot(id: projectID, path: request.path)) == true
            else { return nil }
        } else {
            guard threads.contains(where: {
                $0.checkoutPath == request.path || $0.projectGroupPath == request.path
            }) else { return nil }
        }
        return FileSystemPath.canonicalURL(request.path)
    }

    func receive(_ serialized: String, from target: DevToolsTarget, devTools: any DevToolsServing,
                 threads: [RendererThread]) {
        guard let request = try? JSONDecoder().decode(Request.self, from: Data(serialized.utf8)) else { return }
        let key = target.id + ":" + request.id
        let firstReceipt = handledIDs.insert(key).inserted
        Task {
            if let idData = try? JSONEncoder().encode(request.id) {
                let id = String(decoding: idData, as: UTF8.self)
                _ = try? await devTools.evaluateBoolean(
                    "window.__codexDashboard?.acknowledgeProjectViewerRequest?.(\(id)) === true", in: target
                )
            }
        }
        guard firstReceipt else { return }
        handledOrder.append(key)
        if handledOrder.count > 64 { handledIDs.remove(handledOrder.removeFirst()) }
        cancelPendingOpen()
        openTask = Task {
            guard !Task.isCancelled, let root = await allowedRoot(request, threads: threads),
                  !Task.isCancelled else { return }
            if let threadID = request.threadID {
                ProjectViewerWindowController.shared.open(root: root) { [catalog] in
                    (try? await catalog.editedFiles(for: threadID, checkout: request.path)) ?? []
                }
            } else {
                ProjectViewerWindowController.shared.open(root: root)
            }
        }
    }
}
