import AppKit

@MainActor
struct AccountWindowPresenter {
    /// Target the renderer as well as the PID. App-wide activation alone can
    /// select a different window when several instances share a bundle ID.
    func present(_ application: NSRunningApplication, profile: AccountWindowProfile) async throws {
        guard let arguments = CodexConfiguration.processArguments(for: application.processIdentifier),
              profile.matches(processArguments: arguments),
              let port = CodexConfiguration.devToolsPort(inProcessArguments: arguments) else {
            throw AccountWindowError.windowNotPresented
        }
        let client = DevToolsClient(portProvider: { port })
        do {
            var requestedReopen = false
            var requestedCodexMode = false
            let deadline = ContinuousClock.now + .seconds(10)
            while ContinuousClock.now < deadline {
                guard !application.isTerminated else { throw AccountWindowError.windowNotPresented }
                let targets = await client.mainRendererTargets()
                if let target = targets.first {
                    application.unhide()
                    application.activate(options: [])
                    let focused: Bool
                    do {
                        try await client.bringToFront(target)
                        focused = try await client.evaluateBoolean(
                            "document.visibilityState === 'visible' && document.hasFocus()", in: target)
                    } catch {
                        let native = error as NSError
                        guard native.domain == NSPOSIXErrorDomain || native.domain == NSURLErrorDomain else { throw error }
                        // Focusing is reversible. Rediscover the renderer after a
                        // closed socket; never replay a chat or account request.
                        await client.disconnect()
                        try await Task.sleep(for: .milliseconds(200))
                        continue
                    }
                    if focused, NSWorkspace.shared.frontmostApplication?.processIdentifier == application.processIdentifier {
                        let mode = try await client.evaluateString(
                            Self.codexModeScript(requestSwitch: !requestedCodexMode), in: target)
                        switch mode {
                        case "codex":
                            await client.disconnect()
                            return
                        case "switching":
                            requestedCodexMode = true
                        case "unavailable":
                            throw AccountWindowError.codexModeUnavailable
                        default:
                            break
                        }
                    }
                } else if !requestedReopen, Date.now.timeIntervalSince(application.launchDate ?? .now) > 3 {
                    // A process may remain running after its last window closes.
                    // Reopen the same profile; its singleton forwards to that process.
                    requestedReopen = true
                    let configuration = NSWorkspace.OpenConfiguration()
                    configuration.createsNewApplicationInstance = true
                    configuration.arguments = profile.arguments + CodexConfiguration.debugArguments(port: port)
                    configuration.environment = profile.environment
                    configuration.activates = true
                    _ = try await NSWorkspace.shared.openApplication(at: CodexConfiguration.codexApplicationURL,
                                                                     configuration: configuration)
                }
                try await Task.sleep(for: .milliseconds(200))
            }
            throw AccountWindowError.windowNotPresented
        } catch {
            await client.disconnect()
            throw error
        }
    }
    static func codexModeScript(requestSwitch: Bool) -> String {
        """
        (() => {
          // The mode selector exposes the same callback its native menu uses.
          // Read the React props so this works with localized mode labels.
          for (const button of document.querySelectorAll('button[aria-haspopup="menu"]')) {
            if (!button.checkVisibility({visibilityProperty: true})) continue;
            const key = Object.keys(button).find(key => key.startsWith('__reactFiber$'));
            for (let fiber = button[key]; fiber; fiber = fiber.return) {
              const props = fiber.memoizedProps;
              if (typeof props?.onModeSelect !== 'function' ||
                  typeof props.codexAvailable !== 'boolean') continue;
              if (props.mode === 'codex') return 'codex';
              if (!props.codexAvailable || props.disabled) return 'unavailable';
              if (\(requestSwitch)) props.onModeSelect('codex');
              return 'switching';
            }
          }
          return 'waiting';
        })()
        """
    }

}
