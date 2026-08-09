import SwiftUI

private struct ConnectionStatusCard: View {
    @ObservedObject var viewModel: DashboardViewModel

    private var statusColor: Color {
        if viewModel.connectionState.dashboardIsMounted {
            return Color(red: 0.45, green: 0.94, blue: 0.61)
        }
        if viewModel.connectionState != .codexClosed {
            return Color(red: 0.96, green: 0.77, blue: 0.42)
        }
        return .secondary
    }

    var body: some View {
        let status = viewModel.statusPresentation
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
            Button("Sync Now") { Task { await viewModel.synchronizeDashboard() } }
                .buttonStyle(.borderless)
                .font(.system(size: 11, weight: .medium))
        }
        .padding(13)
        .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.primary.opacity(0.07)))
    }
}

private struct CompatibilityCard: View {
    @ObservedObject var viewModel: DashboardViewModel
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
                    Text(viewModel.compatibilityReport?.summary ?? "Check private Codex contracts before or after an update.")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(viewModel.isCheckingCompatibility ? "Checking…" : "Check Compatibility") {
                    Task { await viewModel.checkCompatibility() }
                }
                .buttonStyle(.borderless)
                .font(.system(size: 11, weight: .medium))
                .disabled(viewModel.isCheckingCompatibility)
            }

            if let report = viewModel.compatibilityReport {
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
        .onChange(of: viewModel.compatibilityReport) { _, report in
            detailsAreExpanded = report.map { $0.blockingCount > 0 || $0.warningCount > 0 } ?? false
        }
    }
}

struct DashboardControllerView: View {
    @StateObject private var viewModel = DashboardViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.primary.opacity(0.07))
                    Text("D")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.secondary)
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

            ConnectionStatusCard(viewModel: viewModel)

            CompatibilityCard(viewModel: viewModel)

            HStack(spacing: 10) {
                Button {
                    Task {
                        if viewModel.connectionState.dashboardIsMounted {
                            await viewModel.openThreadDashboard()
                        } else {
                            await viewModel.restartCodexAndEnableThreadDashboard()
                        }
                    }
                } label: {
                    Text(viewModel.connectionState.dashboardIsMounted ? "Open Dashboard" : "Restart & Enable")
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 15)
                        .frame(height: 36)
                        .frame(maxWidth: .infinity)
                        .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 8))
                        .foregroundStyle(Color.white)
                }
                .buttonStyle(.plain)
                .disabled(viewModel.isPerformingAction)

                if viewModel.connectionState.rendererIsAvailable {
                    Menu {
                        Button("Disable Thread Dashboard", role: .destructive) {
                            Task { await viewModel.disableThreadDashboard() }
                        }
                        .disabled(viewModel.isPerformingAction)
                    } label: {
                        Image(systemName: "ellipsis")
                            .frame(width: 34, height: 34)
                    }
                    .menuStyle(.borderlessButton)
                    .help("More dashboard actions")
                }
            }
            .controlSize(.large)

            if viewModel.connectionError != nil || viewModel.threadDataWarning != nil {
                VStack(alignment: .leading, spacing: 6) {
                    if let error = viewModel.connectionError { Text(error) }
                    if let warning = viewModel.threadDataWarning { Text(warning) }
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
        .frame(width: 620, height: 600, alignment: .topLeading)
        .onAppear {
            viewModel.startMonitoring()
            Task { await viewModel.checkCompatibility() }
        }
        .onDisappear { viewModel.stopMonitoring() }
    }
}
