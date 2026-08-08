import SwiftUI

struct StatusCard: View {
    @ObservedObject var controller: DashboardController

    private var statusColor: Color {
        if controller.state.dashboardIsEnabled {
            return Color(red: 0.45, green: 0.94, blue: 0.61)
        }
        if controller.state != .hostClosed {
            return Color(red: 0.96, green: 0.77, blue: 0.42)
        }
        return .secondary
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(statusColor)
                .frame(width: 7, height: 7)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 4) {
                Text(controller.statusTitle)
                    .font(.system(size: 13, weight: .medium))
                Text(controller.statusDetail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Button("Refresh") { Task { await controller.refresh() } }
                .buttonStyle(.borderless)
                .font(.system(size: 11, weight: .medium))
        }
        .padding(13)
        .background(.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(.white.opacity(0.07)))
    }
}

struct DashboardControlView: View {
    @StateObject private var controller = DashboardController()

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(.white.opacity(0.07))
                    Text("D")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .frame(width: 36, height: 36)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Local UI layer")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text("Codex Dashboard")
                        .font(.system(size: 24, weight: .semibold))
                        .tracking(-0.5)
                    Text("Active threads, built into your local Codex app.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }

            StatusCard(controller: controller)

            HStack(spacing: 10) {
                Button {
                    Task { await controller.restartCodexAndEnableDashboard() }
                } label: {
                    Text("Restart Codex & Enable Dashboard")
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 15)
                        .frame(height: 34)
                        .frame(maxWidth: .infinity)
                        .background(
                            .white.opacity(0.10),
                            in: RoundedRectangle(cornerRadius: 7)
                        )
                }
                .buttonStyle(.plain)
                .disabled(controller.isBusy)

                Button("Open Dashboard") { Task { await controller.openDashboard() } }
                    .disabled(!controller.state.dashboardIsEnabled || controller.isBusy)

                Button("Disable Dashboard") { Task { await controller.disableDashboard() } }
                    .disabled(!controller.state.hostIsConnected || controller.isBusy)
            }
            .controlSize(.large)

            if controller.state.errorMessage != nil || controller.dataWarning != nil {
                VStack(alignment: .leading, spacing: 6) {
                    if let error = controller.state.errorMessage { Text(error) }
                    if let warning = controller.dataWarning { Text(warning) }
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
    }
}
