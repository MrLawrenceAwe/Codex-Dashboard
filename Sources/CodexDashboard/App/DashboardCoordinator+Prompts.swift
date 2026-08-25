import AppKit
import Foundation

extension DashboardCoordinator {
    func importPromptLibrary() async {
        let panel = NSOpenPanel()
        panel.title = "Import Prompt Library"
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let sourceURL = panel.url else { return }
        await synchronizationGate.cancel()
        do {
            try promptLibraryStore.importDocument(from: sourceURL)
            dashboardRuntime?.preferNativePromptLibraryOnNextSynchronization()
            promptLibraryStatusMessage = "Imported prompt library."
            await synchronizeDashboard()
        } catch {
            promptLibraryStatusMessage = error.localizedDescription
        }
    }

    func exportPromptLibrary() {
        let panel = NSSavePanel()
        panel.title = "Export Prompt Library"
        panel.nameFieldStringValue = "codex-dashboard-prompts.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let destinationURL = panel.url else { return }
        do {
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
