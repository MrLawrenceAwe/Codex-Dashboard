import SwiftUI

private struct ConnectionStatusCard: View {
    @ObservedObject var coordinator: AppCoordinator

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
    @ObservedObject var coordinator: AppCoordinator
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
    @ObservedObject var coordinator: AppCoordinator

    var body: some View {
        let codexVersion = CodexConfiguration.installedVersion ?? "not found"
        let dashboardShortVersion = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "development"
        let dashboardBuild = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        let dashboardVersion = dashboardBuild.map { "\(dashboardShortVersion) (\($0))" }
            ?? dashboardShortVersion
        let actions = coordinator.dashboardActions
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

            HStack(spacing: 10) {
                Button(DashboardActionPresentation.openTitle) {
                    Task { await coordinator.openTaskDashboard() }
                }
                .disabled(!actions.canOpen)

                Button(DashboardActionPresentation.restartTitle) {
                    Task { await coordinator.restartCodexAndEnableDashboard() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!actions.canRestart)

                if coordinator.connectionState.rendererIsAvailable {
                    Button(DashboardActionPresentation.disableTitle) {
                        Task { await coordinator.disableIntegration() }
                    }
                    .disabled(!actions.canDisable)
                }
            }

            CompatibilityCard(coordinator: coordinator)

            VStack(alignment: .leading, spacing: 8) {
                Toggle(
                    "Send usage alerts to my phone",
                    isOn: Binding(
                        get: { coordinator.phoneNotificationsEnabled },
                        set: { coordinator.setPhoneNotificationsEnabled($0) }
                    )
                )
                .font(.system(size: 12, weight: .medium))

                if coordinator.phoneNotificationsEnabled {
                    Text("In ntfy, choose Add Subscription and enter this private topic:")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Text(coordinator.phoneNotificationTopic)
                        .font(.system(size: 10, design: .monospaced))
                        .textSelection(.enabled)
                    HStack(spacing: 8) {
                        Button("Copy Topic") { coordinator.copyPhoneNotificationTopic() }
                        Button("New Topic") {
                            coordinator.generateNewPhoneNotificationTopic()
                        }
                        Button("Send Test") { Task { await coordinator.testPhoneNotification() } }
                    }
                    Text("The topic is the subscription secret. Reset details are sent through ntfy.sh.")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                if let message = coordinator.phoneNotificationStatusMessage {
                    Text(message)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(13)
            .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.primary.opacity(0.07)))

            VStack(alignment: .leading, spacing: 8) {
                Text("Prompt library")
                    .font(.system(size: 12, weight: .medium))
                HStack(spacing: 8) {
                    Button("Import…") { Task { await coordinator.importPromptLibrary() } }
                    Button("Export…") { coordinator.exportPromptLibrary() }
                    Button("Show File") { coordinator.revealPromptLibrary() }
                }
                if let message = coordinator.promptLibraryStatusMessage {
                    Text(message)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 5) {
                Text("Codex Dashboard \(dashboardVersion) · Codex \(codexVersion)")
                Text("\(coordinator.rendererTargetCount) renderer target(s)")
                Text("\(coordinator.threads.count) loaded · \(coordinator.totalThreadCount) total tasks")
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

            if coordinator.connectionError != nil || coordinator.connectionNotice != nil || coordinator.threadDataWarning != nil {
                VStack(alignment: .leading, spacing: 6) {
                    if let error = coordinator.connectionError { Text(error) }
                    if let notice = coordinator.connectionNotice { Text(notice) }
                    if let warning = coordinator.threadDataWarning { Text(warning) }
                }
                .font(.system(size: 12))
                .foregroundStyle(
                    coordinator.connectionError == nil && coordinator.threadDataWarning == nil
                        ? .secondary
                        : Color(red: 1.0, green: 0.60, blue: 0.60)
                )
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    (coordinator.connectionError == nil && coordinator.threadDataWarning == nil
                        ? Color.secondary.opacity(0.08)
                        : Color.red.opacity(0.07)),
                    in: RoundedRectangle(cornerRadius: 8)
                )
            }

            Text("The app runs from the menu bar. The Task Dashboard reads local Codex task metadata and activity logs; the signed Codex application bundle is never modified.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(24)
        .frame(width: 620, height: 760, alignment: .topLeading)
    }
}
