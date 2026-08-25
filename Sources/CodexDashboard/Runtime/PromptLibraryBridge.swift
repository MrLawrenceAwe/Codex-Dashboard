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

    func preferNativeLibrary() {
        nativeLibraryIsAuthoritative = true
    }

    func reset() {
        lastDeliveredLibrary = nil
    }

    func synchronize(
        targets: [DevToolsTarget],
        healthyTargets: [DevToolsTarget],
        mountedDashboard: Bool
    ) async throws {
        guard let firstTarget = targets.first else { return }
        var nativeWins = nativeLibraryIsAuthoritative
        var discardedPendingLibrary = false
        if nativeWins {
            try await discardPendingLibrary(on: targets)
            discardedPendingLibrary = true
        } else if let pendingLibrary = await exportedLibrary(
            using: RendererScript.exportPendingPromptLibrary,
            from: firstTarget
        ) {
            nativeWins = nativeLibraryIsAuthoritative
            if nativeWins {
                try await discardPendingLibrary(on: targets)
                discardedPendingLibrary = true
            } else {
                _ = try store.save(pendingLibrary)
                let acknowledgement = try RendererScript.acknowledgePendingPromptLibrary(
                    pendingLibrary
                )
                guard try await devTools.evaluateBoolean(acknowledgement, in: firstTarget) else {
                    throw DashboardError.enableFailed(
                        "The prompt library save could not be acknowledged by the renderer."
                    )
                }
            }
        }

        let storedLibrary = try store.load()
        let nativeLibraryChanged = storedLibrary != lastDeliveredLibrary
        let sourceTarget = healthyTargets.first ?? (storedLibrary == nil ? firstTarget : nil)
        if !nativeLibraryChanged,
           let sourceTarget,
           let rendererLibrary = await exportedLibrary(
               using: RendererScript.exportPromptLibrary,
               from: sourceTarget
           ) {
            nativeWins = nativeLibraryIsAuthoritative
            if nativeWins {
                if !discardedPendingLibrary {
                    try await discardPendingLibrary(on: targets)
                    discardedPendingLibrary = true
                }
            } else {
                _ = try store.save(rendererLibrary)
            }
        }

        nativeWins = nativeWins || nativeLibraryIsAuthoritative
        if nativeWins, !discardedPendingLibrary {
            try await discardPendingLibrary(on: targets)
        }
        guard let nativeLibrary = try store.load() else { return }
        guard nativeWins || mountedDashboard || nativeLibrary != lastDeliveredLibrary else { return }

        let expression = try RendererScript.deliverPromptLibrary(nativeLibrary)
        for target in targets {
            guard try await devTools.evaluateBoolean(expression, in: target) else {
                throw DashboardError.enableFailed(
                    "The prompt library was unavailable in the Codex renderer."
                )
            }
        }
        lastDeliveredLibrary = nativeLibrary
        if nativeWins { nativeLibraryIsAuthoritative = false }
    }

    private func exportedLibrary(
        using expression: String,
        from target: DevToolsTarget
    ) async -> PromptLibraryDocument? {
        guard
            let serialized = try? await devTools.evaluateString(expression, in: target),
            let data = serialized.data(using: .utf8),
            let library = try? JSONDecoder().decode(PromptLibraryDocument.self, from: data),
            library.isValid
        else { return nil }
        return library
    }

    private func discardPendingLibrary(on targets: [DevToolsTarget]) async throws {
        for target in targets {
            guard try await devTools.evaluateBoolean(
                RendererScript.discardPendingPromptLibrary,
                in: target
            ) else {
                throw DashboardError.enableFailed(
                    "The pending prompt library could not be cleared from the renderer."
                )
            }
        }
    }
}
