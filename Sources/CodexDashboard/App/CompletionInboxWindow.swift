import AppKit
import SwiftUI

@MainActor
final class CompletionInboxWindowController {
    private let window: NSWindow

    init(coordinator: AppCoordinator) {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 480),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = "Completion Inbox"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: CompletionInboxView(coordinator: coordinator))
        window.minSize = NSSize(width: 440, height: 320)
        window.center()
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

struct CompletionInboxView: View {
    @ObservedObject var coordinator: AppCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Completion Inbox").font(.title2.bold())
                    Text("\(coordinator.completionInbox.count)")
                        .foregroundStyle(.secondary).monospacedDigit()
                    Spacer()
                    Button("Dismiss all") { coordinator.dismissAllCompletions() }
                        .disabled(coordinator.completionInbox.isEmpty)
                }
                Text("Latest completion per task. Items stay until you dismiss them.")
                    .font(.callout).foregroundStyle(.secondary)
                Picker("On completion", selection: Binding(
                    get: { coordinator.completionBehavior },
                    set: { behavior in Task { await coordinator.selectCompletionBehavior(behavior) } }
                )) {
                    ForEach(TaskCompletionBehavior.allCases) { behavior in
                        Text(behavior.title).tag(behavior)
                    }
                }
                .pickerStyle(.menu)
                if let notice = coordinator.completionInboxNotice {
                    Text(notice).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let notice = coordinator.completionNotificationNotice {
                    Text(notice).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(20)
            Divider()
            if coordinator.completionInbox.isEmpty {
                ContentUnavailableView(
                    "All caught up", systemImage: "checkmark.circle",
                    description: Text("New completions appear here while Codex Dashboard is running.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(coordinator.completionInbox) { completion in
                    HStack(alignment: .center, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(completion.title).font(.body.weight(.medium)).lineLimit(2)
                                .help(completion.title)
                            Text(completion.projectName).foregroundStyle(.secondary).lineLimit(1)
                            Text(completion.completedAt, style: .relative)
                                .font(.caption).foregroundStyle(.secondary)
                                .help(completion.completedAt.formatted(date: .abbreviated, time: .standard))
                        }
                        Spacer(minLength: 0)
                        Button("Open task") {
                            Task { await coordinator.openCompletedTask(completion.id) }
                        }
                        .disabled(coordinator.isPerformingAction)
                        Button { coordinator.dismissCompletion(completion.id) } label: {
                            Image(systemName: "xmark")
                        }
                        .accessibilityLabel("Dismiss \(completion.title)")
                        .help("Dismiss completion")
                    }
                    .padding(.vertical, 8)
                }
                .buttonStyle(.borderless)
            }
        }
        .frame(minWidth: 440, minHeight: 320)
    }
}
