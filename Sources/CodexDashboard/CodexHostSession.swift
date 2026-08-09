import AppKit
import Foundation

enum DashboardDisableResult {
    case applicationClosed
    case bridgeConnected
}

@MainActor
protocol DashboardHosting: AnyObject {
    var applicationIsRunning: Bool { get }
    var applicationLaunchDate: Date? { get }
    var keepsDashboardMounted: Bool { get }

    func mainRendererTargets() async -> [DevToolsTarget]
    func prepareForRestart()
    func restartApplication() async throws -> [DevToolsTarget]
    func mountDashboard(
        with payload: DashboardPayload,
        on targets: [DevToolsTarget],
        force: Bool
    ) async throws
    func disableDashboard() async throws -> DashboardDisableResult
    func openDashboard() async
}

@MainActor
final class CodexHostSession: DashboardHosting {
    private let devTools = DevToolsClient()
    private let injection: DashboardInjection
    private var shouldKeepDashboardMounted = true
    private var mountedTargetIDs: Set<String> = []
    private var lastDeliveredPayload: DashboardPayload?

    init() throws {
        injection = try DashboardInjection.load()
    }

    var applicationIsRunning: Bool {
        !runningApplications.isEmpty
    }

    var applicationLaunchDate: Date? {
        runningApplications.compactMap(\.launchDate).max()
    }

    private var runningApplications: [NSRunningApplication] {
        NSRunningApplication.runningApplications(
            withBundleIdentifier: CodexConfiguration.bundleIdentifier
        )
    }

    var keepsDashboardMounted: Bool {
        shouldKeepDashboardMounted
    }

    func mainRendererTargets() async -> [DevToolsTarget] {
        await devTools.mainRendererTargets()
    }

    func stopMaintainingDashboard() {
        shouldKeepDashboardMounted = false
        clearMountState()
    }

    func prepareForRestart() {
        shouldKeepDashboardMounted = true
        clearMountState()
    }

    func restartApplication() async throws -> [DevToolsTarget] {
        let applicationURL = CodexConfiguration.applicationURL
        guard FileManager.default.fileExists(atPath: applicationURL.path) else {
            throw DashboardError.missingCodexApplication
        }

        let applications = NSRunningApplication.runningApplications(
            withBundleIdentifier: CodexConfiguration.bundleIdentifier
        )
        applications.forEach { $0.terminate() }

        let quitDeadline = ContinuousClock.now + .seconds(12)
        while applicationIsRunning {
            guard ContinuousClock.now < quitDeadline else {
                throw DashboardError.codexQuitTimedOut
            }
            try await Task.sleep(for: .milliseconds(250))
        }

        let launchConfiguration = NSWorkspace.OpenConfiguration()
        launchConfiguration.arguments = CodexConfiguration.launchArguments
        launchConfiguration.activates = true
        _ = try await NSWorkspace.shared.openApplication(
            at: applicationURL,
            configuration: launchConfiguration
        )

        let rendererDeadline = ContinuousClock.now + .seconds(18)
        var targets: [DevToolsTarget] = []
        while targets.isEmpty {
            targets = await mainRendererTargets()
            if !targets.isEmpty { break }
            guard ContinuousClock.now < rendererDeadline else {
                throw DashboardError.rendererTimedOut
            }
            try await Task.sleep(for: .milliseconds(350))
        }
        return targets
    }

    func mountDashboard(
        with payload: DashboardPayload,
        on targets: [DevToolsTarget],
        force: Bool = false
    ) async throws {
        let targetIDs = Set(targets.map(\.id))
        var mountedDashboard = false

        for target in targets {
            try Task.checkCancellation()
            guard shouldKeepDashboardMounted else { return }
            let canCheckExistingDashboard = !force && mountedTargetIDs.contains(target.id)
            let isHealthy: Bool
            if canCheckExistingDashboard {
                isHealthy = (try? await devTools.evaluateBoolean(
                    injection.healthCheckExpression,
                    in: target
                )) == true
            } else {
                isHealthy = false
            }
            guard !Task.isCancelled, shouldKeepDashboardMounted else { return }
            if !isHealthy {
                guard try await devTools.evaluateBoolean(
                    injection.mountExpression,
                    in: target
                ) else {
                    throw DashboardError.enableFailed(
                        "The dashboard injection did not mount in the Codex renderer."
                    )
                }
                mountedDashboard = true
            }
        }

        if mountedDashboard || payload != lastDeliveredPayload || targetIDs != mountedTargetIDs {
            try await deliver(payload, to: targets)
            lastDeliveredPayload = payload
        }
        mountedTargetIDs = targetIDs
    }

    func disableDashboard() async throws -> DashboardDisableResult {
        stopMaintainingDashboard()
        let targets = await mainRendererTargets()
        guard !targets.isEmpty else { return .applicationClosed }

        for target in targets {
            let disabled = try await devTools.evaluateBoolean(
                "(() => { window.__codexDashboard?.destroy?.(); return typeof window.__codexDashboard === 'undefined'; })()",
                in: target
            )
            guard disabled else {
                throw DashboardError.disableFailed("The renderer still reports an active dashboard.")
            }
        }
        return .bridgeConnected
    }

    func openDashboard() async {
        for target in await mainRendererTargets() {
            _ = try? await devTools.evaluateBoolean(
                "(() => { window.__codexDashboard?.open?.(); return true; })()",
                in: target
            )
        }
    }

    private func deliver(_ payload: DashboardPayload, to targets: [DevToolsTarget]) async throws {
        let data = try JSONEncoder().encode(payload)
        guard let json = String(data: data, encoding: .utf8) else {
            throw DashboardError.enableFailed("Thread data could not be encoded for the renderer.")
        }
        let expression = """
        (() => {
          const dashboard = window.__codexDashboard;
          if (typeof dashboard?.update !== 'function') return false;
          dashboard.update(\(json));
          return true;
        })()
        """
        for target in targets {
            guard try await devTools.evaluateBoolean(expression, in: target) else {
                throw DashboardError.enableFailed(
                    "The dashboard was unavailable while thread data was being delivered."
                )
            }
        }
    }

    private func clearMountState() {
        mountedTargetIDs = []
        lastDeliveredPayload = nil
    }
}
