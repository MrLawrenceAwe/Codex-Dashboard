import AppKit
import Foundation

extension AppCoordinator {
    func importPromptLibrary() async {
        guard !isPerformingAction else { return }
        let panel = NSOpenPanel()
        panel.title = "Import Prompt Library"
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let sourceURL = panel.url else { return }
        await synchronizationCoalescer.cancelAndWait()
        do {
            try promptLibraryStore.importDocument(from: sourceURL)
            dashboardRuntime?.useStoredPromptLibraryOnNextSync()
            promptLibraryStatusMessage = "Imported prompt library."
            await synchronizeDashboard()
        } catch {
            promptLibraryStatusMessage = error.localizedDescription
        }
    }

    func exportPromptLibrary() async {
        let panel = NSSavePanel()
        panel.title = "Export Prompt Library"
        panel.nameFieldStringValue = "codex-dashboard-prompts.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let destinationURL = panel.url else { return }
        await exportPromptLibrary(to: destinationURL)
    }

    func exportPromptLibrary(to destinationURL: URL) async {
        guard !isPerformingAction else {
            promptLibraryStatusMessage = "Another dashboard action is in progress. Try exporting when it finishes."
            return
        }
        // Hold the action gate while draining dashboard synchronization and
        // flushing its prompt bridge; periodic polls must not overlap this read.
        isPerformingAction = true
        defer { isPerformingAction = false }
        await synchronizationCoalescer.waitForCurrentSynchronization()
        do {
            guard let dashboardRuntime else {
                throw DashboardError.synchronizationFailed("Dashboard runtime is unavailable. Try exporting after reconnecting.")
            }
            try await dashboardRuntime.flushPromptLibrary()
            try promptLibraryStore.exportDocument(to: destinationURL)
            promptLibraryStatusMessage = "Exported prompt library."
        } catch {
            promptLibraryStatusMessage = error.localizedDescription
        }
    }

    func revealPromptLibrary() {
        do {
            if try promptLibraryStore.load() == nil {
                try promptLibraryStore.save(.empty)
            }
            NSWorkspace.shared.activateFileViewerSelecting([promptLibraryStore.documentURL])
        } catch {
            promptLibraryStatusMessage = error.localizedDescription
        }
    }
}
