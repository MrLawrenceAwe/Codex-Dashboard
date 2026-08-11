import SwiftUI

private struct ConnectionStatusCard: View {
    @ObservedObject var coordinator: DashboardCoordinator

    private var statusColor: Color {
        if coordinator.connectionState.dashboardIsMounted {
            return Color(red: 0.45, green: 0.94, blue: 0.61)
        }
        if coordinator.connectionState != .codexClosed {
            return Color(red: 0.96, green: 0.77, blue: 0.42)
        }
        return .secondary
    }

    var body: some View {
        let status = coordinator.statusPresentation
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(statusColor)
                .frame(width: 7, height: 7)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 4) {
                Text(status.title)
                    .font(.system(size: 13, weight: .medium))
                Text(status.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Button("Sync Now") { Task { await coordinator.synchronizeDashboard() } }
                .buttonStyle(.borderless)
                .font(.system(size: 11, weight: .medium))
        }
        .padding(13)
        .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.primary.opacity(0.07)))
    }
}

private struct CompatibilityCard: View {
    @ObservedObject var coordinator: DashboardCoordinator
    @State private var detailsAreExpanded = false

    private func color(for status: CompatibilityStatus) -> Color {
        switch status {
        case .compatible: Color(red: 0.45, green: 0.94, blue: 0.61)
        case .warning, .unavailable: Color(red: 0.96, green: 0.77, blue: 0.42)
        case .incompatible: Color(red: 1.0, green: 0.42, blue: 0.42)
        }
    }

    private func label(for status: CompatibilityStatus) -> String {
        switch status {
        case .compatible: "Compatible"
        case .warning: "Warning"
        case .incompatible: "Incompatible"
        case .unavailable: "Not checked"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Codex update compatibility")
                        .font(.system(size: 12, weight: .medium))
                    Text(coordinator.compatibilityReport?.summary ?? "Check private Codex contracts before or after an update.")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(coordinator.isCheckingCompatibility ? "Checking…" : "Check Compatibility") {
                    Task { await coordinator.checkCompatibility() }
                }
                .buttonStyle(.borderless)
                .font(.system(size: 11, weight: .medium))
                .disabled(coordinator.isCheckingCompatibility)
            }

            if let report = coordinator.compatibilityReport {
                DisclosureGroup(isExpanded: $detailsAreExpanded) {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 9) {
                            ForEach(report.checks) { check in
                                HStack(alignment: .top, spacing: 8) {
                                    Circle()
                                        .fill(color(for: check.status))
                                        .frame(width: 6, height: 6)
                                        .padding(.top, 4)
                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack(spacing: 6) {
                                            Text(check.title)
                                                .font(.system(size: 11, weight: .medium))
                                            Text(label(for: check.status))
                                                .font(.system(size: 10, weight: .medium))
                                                .foregroundStyle(color(for: check.status))
                                        }
                                        Text(check.detail)
                                            .font(.system(size: 11))
                                            .foregroundStyle(.secondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .frame(height: 190)
                    .padding(.top, 6)
                } label: {
                    Label {
                        Text(report.summary)
                            .font(.system(size: 11, weight: .medium))
                    } icon: {
                        Circle()
                            .fill(report.blockingCount > 0 ? Color.red : (report.warningCount > 0 ? Color.orange : Color.green))
                            .frame(width: 7, height: 7)
                    }
                }
                .disclosureGroupStyle(.automatic)
            }
        }
        .padding(13)
        .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.primary.opacity(0.07)))
        .onChange(of: coordinator.compatibilityReport) { _, report in
            detailsAreExpanded = report.map { $0.blockingCount > 0 || $0.warningCount > 0 } ?? false
        }
    }
}

struct ControllerWindowView: View {
    @ObservedObject var coordinator: DashboardCoordinator
    @ObservedObject var launchAtLogin: LaunchAtLoginController

    var body: some View {
        let codexVersion = CodexConfiguration.installedVersion ?? "not found"
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.primary.opacity(0.07))
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .scaledToFit()
                }
                .frame(width: 36, height: 36)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Codex Dashboard")
                        .font(.system(size: 24, weight: .semibold))
                        .tracking(-0.5)
                    Text("Recent threads, built into your local Codex app.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }

            ConnectionStatusCard(coordinator: coordinator)

            CompatibilityCard(coordinator: coordinator)

            DisclosureGroup("Diagnostics") {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Codex \(codexVersion) · \(coordinator.rendererTargetCount) renderer target(s)")
                    Text("\(coordinator.threads.count) loaded · \(coordinator.totalThreadCount) total threads")
                    if let refreshed = coordinator.lastSuccessfulRefresh {
                        Text("Last refresh \(refreshed.formatted(date: .omitted, time: .standard))")
                    }
                    if coordinator.compatibilityWasTriggeredByUpdate {
                        Text("Compatibility was checked because the Codex version changed.")
                            .foregroundStyle(.orange)
                    }
                    HStack {
                        Button("Copy Diagnostics") { coordinator.copyDiagnostics() }
                        Toggle("Launch at Login", isOn: Binding(
                            get: { launchAtLogin.isEnabled },
                            set: { launchAtLogin.setEnabled($0) }
                        ))
                        .toggleStyle(.checkbox)
                    }
                    if let error = launchAtLogin.errorMessage { Text(error).foregroundStyle(.red) }
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(.top, 5)
            }
            .font(.system(size: 11, weight: .medium))

            HStack(spacing: 10) {
                if coordinator.connectionState.dashboardIsMounted {
                    Button {
                        Task { await coordinator.openThreadDashboard() }
                    } label: {
                        Text("Open Dashboard")
                            .font(.system(size: 12, weight: .semibold))
                            .padding(.horizontal, 15)
                            .frame(height: 36)
                            .frame(maxWidth: .infinity)
                            .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 8))
                            .foregroundStyle(Color.white)
                    }
                    .buttonStyle(.plain)
                    .disabled(coordinator.isPerformingAction)

                    Button("Restart & Enable") {
                        Task { await coordinator.restartCodexAndEnableThreadDashboard() }
                    }
                    .disabled(coordinator.isPerformingAction)
                } else {
                    Button {
                        Task { await coordinator.restartCodexAndEnableThreadDashboard() }
                    } label: {
                        Text("Restart & Enable")
                            .font(.system(size: 12, weight: .semibold))
                            .padding(.horizontal, 15)
                            .frame(height: 36)
                            .frame(maxWidth: .infinity)
                            .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 8))
                            .foregroundStyle(Color.white)
                    }
                    .buttonStyle(.plain)
                    .disabled(coordinator.isPerformingAction)
                }

                if coordinator.connectionState.rendererIsAvailable {
                    Menu {
                        Button("Disable Thread Dashboard", role: .destructive) {
                            Task { await coordinator.disableThreadDashboard() }
                        }
                        .disabled(coordinator.isPerformingAction)
                    } label: {
                        Image(systemName: "ellipsis")
                            .frame(width: 34, height: 34)
                    }
                    .menuStyle(.borderlessButton)
                    .help("More dashboard actions")
                }
            }
            .controlSize(.large)

            if coordinator.connectionError != nil || coordinator.threadDataWarning != nil {
                VStack(alignment: .leading, spacing: 6) {
                    if let error = coordinator.connectionError { Text(error) }
                    if let warning = coordinator.threadDataWarning { Text(warning) }
                }
                .font(.system(size: 12))
                .foregroundStyle(Color(red: 1.0, green: 0.60, blue: 0.60))
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.red.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
            }

            Text("The Thread Dashboard reads local Codex thread metadata and activity logs. Restarting closes Codex briefly; the signed application bundle is never modified.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(24)
        .frame(width: 620, height: 680, alignment: .topLeading)
        .onAppear {
            coordinator.startMonitoring()
        }
    }
}
