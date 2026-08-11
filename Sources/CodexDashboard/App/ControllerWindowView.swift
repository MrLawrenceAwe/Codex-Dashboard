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

struct DiagnosticsWindowView: View {
    @ObservedObject var coordinator: DashboardCoordinator

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
                    Text("Diagnostics")
                        .font(.system(size: 24, weight: .semibold))
                        .tracking(-0.5)
                    Text("Codex Dashboard status, compatibility, and runtime details.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }

            ConnectionStatusCard(coordinator: coordinator)

            CompatibilityCard(coordinator: coordinator)

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
                Button("Copy Diagnostics") { coordinator.copyDiagnostics() }
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)

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

            Text("The app runs from the menu bar. The Thread Dashboard reads local Codex thread metadata and activity logs; the signed Codex application bundle is never modified.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(24)
        .frame(width: 620, height: 560, alignment: .topLeading)
    }
}
