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
        HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(statusColor)
                .frame(width: 10, height: 10)
                .shadow(color: statusColor.opacity(0.35), radius: 5)
                .padding(.top, 4)
            VStack(alignment: .leading, spacing: 5) {
                Text(controller.statusTitle)
                    .font(.system(size: 14, weight: .semibold))
                Text(controller.statusDetail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Button("Refresh") { Task { await controller.refresh() } }
                .buttonStyle(.borderless)
                .font(.system(size: 12, weight: .medium))
        }
        .padding(16)
        .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.08)))
    }
}

struct DashboardControlView: View {
    @StateObject private var controller = DashboardController()

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .top, spacing: 16) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14)
                        .fill(Color(red: 0.72, green: 1.0, blue: 0.79))
                    Text("D")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(Color(red: 0.06, green: 0.09, blue: 0.07))
                }
                .frame(width: 48, height: 48)
                VStack(alignment: .leading, spacing: 5) {
                    Text("LOCAL UI LAYER")
                        .font(.system(size: 9, weight: .bold))
                        .tracking(1.5)
                        .foregroundStyle(.secondary)
                    Text("Codex Dashboard")
                        .font(.system(size: 31, weight: .bold, design: .rounded))
                        .tracking(-1.2)
                    Text("Active tasks, built into your local Codex app.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
            }

            StatusCard(controller: controller)

            HStack(spacing: 10) {
                Button {
                    Task { await controller.restartCodexAndEnableDashboard() }
                } label: {
                    Text("Restart Codex & Enable Dashboard")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color(red: 0.05, green: 0.08, blue: 0.06))
                        .padding(.horizontal, 18)
                        .frame(height: 38)
                        .frame(maxWidth: .infinity)
                        .background(
                            Color(red: 0.64, green: 0.95, blue: 0.70),
                            in: RoundedRectangle(cornerRadius: 9)
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
                .background(Color.red.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
            }

            Text("The dashboard reads local Codex task metadata and activity logs. Restarting closes Codex briefly; the signed application bundle is never modified.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(28)
        .frame(width: 660, height: 410, alignment: .topLeading)
        .background(
            RadialGradient(
                colors: [Color.green.opacity(0.075), .clear],
                center: .topLeading,
                startRadius: 0,
                endRadius: 380
            )
        )
    }
}
