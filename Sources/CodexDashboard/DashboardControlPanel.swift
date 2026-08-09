import SwiftUI

private struct StatusCard: View {
    @ObservedObject var viewModel: DashboardViewModel

    private var statusColor: Color {
        if viewModel.connectionState.dashboardIsMounted {
            return Color(red: 0.45, green: 0.94, blue: 0.61)
        }
        if viewModel.connectionState != .appClosed {
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
            Button("Refresh") { Task { await viewModel.refresh() } }
                .buttonStyle(.borderless)
                .font(.system(size: 11, weight: .medium))
        }
        .padding(13)
        .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.primary.opacity(0.07)))
    }
}

struct DashboardControlPanel: View {
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
                    Text("Thread dashboard controller")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text("Codex Dashboard")
                        .font(.system(size: 24, weight: .semibold))
                        .tracking(-0.5)
                    Text("Recent threads, built into your local Codex app.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }

            StatusCard(viewModel: viewModel)

            HStack(spacing: 10) {
                Button {
                    Task { await viewModel.restartAndEnableDashboard() }
                } label: {
                    Text("Restart & Enable Dashboard")
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 15)
                        .frame(height: 34)
                        .frame(maxWidth: .infinity)
                        .background(
                            Color.primary.opacity(0.10),
                            in: RoundedRectangle(cornerRadius: 7)
                        )
                }
                .buttonStyle(.plain)
                .disabled(viewModel.isPerformingAction)

                Button("Open Dashboard") { Task { await viewModel.openDashboard() } }
                    .disabled(!viewModel.connectionState.dashboardIsMounted || viewModel.isPerformingAction)

                Button("Disable Dashboard") { Task { await viewModel.disableDashboard() } }
                    .disabled(!viewModel.connectionState.rendererIsAvailable || viewModel.isPerformingAction)
            }
            .controlSize(.large)

            if viewModel.sessionError != nil || viewModel.dataWarning != nil {
                VStack(alignment: .leading, spacing: 6) {
                    if let error = viewModel.sessionError { Text(error) }
                    if let warning = viewModel.dataWarning { Text(warning) }
                }
                .font(.system(size: 12))
                .foregroundStyle(Color(red: 1.0, green: 0.60, blue: 0.60))
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.red.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
            }

            Text("The dashboard reads local Codex thread metadata and activity logs. Restarting closes Codex briefly; the signed application bundle is never modified.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(24)
        .frame(width: 620, height: 370, alignment: .topLeading)
        .onAppear { viewModel.startRefreshing() }
        .onDisappear { viewModel.stopRefreshing() }
    }
}
