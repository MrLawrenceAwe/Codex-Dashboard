import AppKit
import SwiftUI

@MainActor
final class DiagnosticsWindowController: NSWindowController {
    init(coordinator: AppCoordinator) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 760),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Codex Dashboard Diagnostics"
        window.isReleasedWhenClosed = false
        window.center()
        window.contentView = NSHostingView(rootView: DiagnosticsWindowView(coordinator: coordinator))
        super.init(window: window)
        shouldCascadeWindows = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func showDiagnostics() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}
