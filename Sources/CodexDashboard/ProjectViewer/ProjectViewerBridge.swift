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

    func synchronize(devTools: any DevToolsServing, targets: [DevToolsTarget], threads: [RendererThread]) async {
        for target in targets {
            guard let serialized = try? await devTools.evaluateString(
                "window.__codexDashboard?.pendingProjectViewerRequest?.() ?? null", in: target
            ), let request = try? JSONDecoder().decode(Request.self, from: Data(serialized.utf8)) else { continue }
            let key = target.id + ":" + request.id
            let firstReceipt = handledIDs.insert(key).inserted
            if firstReceipt {
                handledOrder.append(key)
                if handledOrder.count > 64 { handledIDs.remove(handledOrder.removeFirst()) }
            }
            if let idData = try? JSONEncoder().encode(request.id) {
                let id = String(decoding: idData, as: UTF8.self)
                _ = try? await devTools.evaluateBoolean(
                    "window.__codexDashboard?.acknowledgeProjectViewerRequest?.(\(id)) === true", in: target
                )
            }
            guard firstReceipt, let root = await allowedRoot(request, threads: threads), !Task.isCancelled else { continue }
            let paths: [String]?
            if let threadID = request.threadID {
                paths = (try? await catalog.editedFiles(for: threadID, checkout: request.path)) ?? []
            } else {
                paths = nil
            }
            guard !Task.isCancelled else { return }
            ProjectViewerWindowController.shared.open(root: root, editedPaths: paths)
        }
    }
}
