import SwiftUI

@main
struct CodexDashboardApp: App {
    var body: some Scene {
        WindowGroup {
            DashboardControlView()
                .preferredColorScheme(.dark)
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) { }
        }
    }
}
