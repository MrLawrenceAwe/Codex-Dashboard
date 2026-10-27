import Foundation

@MainActor
final class PromptLibraryBridge {
    private let devTools: any DevToolsServing
    private let store: PromptLibraryFileStore
    private var lastDeliveredLibrary: PromptLibraryDocument?
    private var nativeLibraryIsAuthoritative = false

    init(devTools: any DevToolsServing, store: PromptLibraryFileStore) {
        self.devTools = devTools
        self.store = store
    }

    func useStoredLibrary() {
        nativeLibraryIsAuthoritative = true
    }

    func reset() {
        lastDeliveredLibrary = nil
    }

    func synchronize(
        targets: [DevToolsTarget],
        previouslyHealthyTargets: [DevToolsTarget],
        didMountAnyTarget: Bool,
        requiresRendererRead: Bool = false
    ) async throws {
        guard let firstTarget = targets.first else {
            if requiresRendererRead { throw DashboardError.synchronizationFailed("Connect Codex before exporting the latest prompt library.") }
            return
        }
        if requiresRendererRead {
            // A missing dashboard and an empty pending queue both return null.
            // Verify the full library so an unavailable renderer cannot produce
            // a successful export of an older native document.
            guard try await exportedLibrary(using: RendererScript.exportPromptLibrary,
                                            from: firstTarget, requiresRendererRead: true) != nil else {
                throw DashboardError.synchronizationFailed("The prompt library is unavailable in Codex. Reconnect before exporting.")
            }
        }
        var seededNativeLibrary = false
        // Seed every renderer with the current native document before reading
        // pending edits. Each queued edit can then merge against this version,
        // including edits made before the first synchronization after launch.
        if !nativeLibraryIsAuthoritative,
           let currentLibrary = try store.load(),
           currentLibrary != lastDeliveredLibrary {
            try await evaluateAcrossTargets(
                try RendererScript.deliverPromptLibrary(currentLibrary),
                targets: targets,
                failureMessage: "The prompt library was unavailable in the Codex renderer."
            )
            lastDeliveredLibrary = currentLibrary
            seededNativeLibrary = true
        }
        if !nativeLibraryIsAuthoritative,
           let pendingLibrary = try await exportedLibrary(
            using: RendererScript.exportPendingPromptLibrary,
            from: firstTarget,
            requiresRendererRead: requiresRendererRead
        ) {
            if !nativeLibraryIsAuthoritative {
                _ = try store.save(pendingLibrary)
                let acknowledgement = try RendererScript.acknowledgePendingPromptLibrary(
                    pendingLibrary
                )
                try await acknowledgePendingLibrary(acknowledgement, on: targets)
            }
        }

        var storedLibrary = try store.load()
        let nativeLibraryChanged = storedLibrary != lastDeliveredLibrary
        let sourceTarget = previouslyHealthyTargets.first ?? (storedLibrary == nil ? firstTarget : nil)
        if !nativeLibraryIsAuthoritative,
           !seededNativeLibrary,
           !nativeLibraryChanged,
           let sourceTarget,
           let rendererLibrary = try await exportedLibrary(
               using: RendererScript.exportPromptLibrary,
               from: sourceTarget,
               requiresRendererRead: requiresRendererRead
           ) {
            if !nativeLibraryIsAuthoritative {
                _ = try store.save(rendererLibrary)
                storedLibrary = rendererLibrary
            }
        }

        if nativeLibraryIsAuthoritative {
            try await discardPendingLibrary(on: targets)
        }
        guard let nativeLibrary = storedLibrary else { return }
        guard nativeLibraryIsAuthoritative || (didMountAnyTarget && !seededNativeLibrary)
            || nativeLibrary != lastDeliveredLibrary else { return }

        try await evaluateAcrossTargets(
            try RendererScript.deliverPromptLibrary(nativeLibrary),
            targets: targets,
            failureMessage: "The prompt library was unavailable in the Codex renderer."
        )
        lastDeliveredLibrary = nativeLibrary
        nativeLibraryIsAuthoritative = false
    }

    private func exportedLibrary(
        using expression: String,
        from target: DevToolsTarget,
        requiresRendererRead: Bool
    ) async throws -> PromptLibraryDocument? {
        do {
            guard let serialized = try await devTools.evaluateString(expression, in: target) else {
                if requiresRendererRead && expression == RendererScript.exportPromptLibrary {
                    throw DashboardError.synchronizationFailed("The prompt library is unavailable in Codex. Reconnect before exporting.")
                }
                return nil
            }
            let storedLibrary = try JSONDecoder().decode(PromptLibraryDocument.self, from: Data(serialized.utf8))
            let library = PromptLibraryMigration.migrate(storedLibrary)
            guard library.isValid else { throw DashboardError.invalidPromptLibrary }
            return library
        } catch {
            if requiresRendererRead { throw error }
            return nil
        }
    }

    private func discardPendingLibrary(on targets: [DevToolsTarget]) async throws {
        try await evaluateAcrossTargets(
            RendererScript.discardPendingPromptLibrary,
            targets: targets,
            failureMessage: "The pending prompt library could not be cleared from the renderer."
        )
    }

    private func acknowledgePendingLibrary(
        _ acknowledgement: String,
        on targets: [DevToolsTarget]
    ) async throws {
        try await evaluateAcrossTargets(
            acknowledgement,
            targets: targets,
            failureMessage: "The prompt library save could not be acknowledged by the renderer."
        )
    }

    private func evaluateAcrossTargets(
        _ expression: String,
        targets: [DevToolsTarget],
        failureMessage: String
    ) async throws {
        for target in targets {
            guard try await devTools.evaluateBoolean(expression, in: target) else {
                throw DashboardError.synchronizationFailed(failureMessage)
            }
        }
    }
}
