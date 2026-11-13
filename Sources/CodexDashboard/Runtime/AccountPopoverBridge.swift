import Foundation

@MainActor
final class AccountPopoverBridge {
    private let devTools: any DevToolsServing
    private var receivedAccountRequestIDs: Set<String> = []
    private var completedAccountRequests: [String: AccountPopoverSnapshot] = [:]
    private var completedAccountRequestOrder: [String] = []

    init(devTools: any DevToolsServing) {
        self.devTools = devTools
    }

    func poll(in targets: [DevToolsTarget], isEnabled: () -> Bool) async -> AccountPopoverActionPollResult {
        var foundAvailableRenderer = false
        for target in targets {
            do {
                guard let serialized = try await devTools.evaluateString(
                    RendererScript.readQueuedAccountPopoverAction,
                    in: target,
                    timeout: .seconds(1)
                ), serialized != RendererScript.accountPopoverUnavailable else { continue }
                guard isEnabled(), !Task.isCancelled else { return .unavailable }
                foundAvailableRenderer = true
                if serialized == "null" { continue }
                guard let data = serialized.data(using: .utf8),
                      let action = try? JSONDecoder().decode(AccountPopoverAction.self, from: data)
                else { continue }
                if (action.kind == .switchAccount || action.kind == .removeSavedAccount), action.accountID == nil {
                    continue
                }
                if let snapshot = completedAccountRequests[action.requestID] {
                    _ = try? await devTools.evaluateBoolean(
                        RendererScript.completeAccountPopoverAction(action, snapshot: snapshot), in: target
                    )
                    continue
                }
                guard receivedAccountRequestIDs.insert(action.requestID).inserted else { continue }
                // Receipt is recorded locally before the UI acknowledgement. A lost
                // acknowledgement must never repeat a sign-out or account switch.
                _ = try? await devTools.evaluateBoolean(
                    RendererScript.acknowledgeAccountPopoverAction(action), in: target
                )
                return .action(action)
            } catch {
                // A closed or unavailable window must not starve the other windows.
                continue
            }
        }
        return foundAvailableRenderer ? .empty : .unavailable
    }

    func complete(_ action: AccountPopoverAction, snapshot: AccountPopoverSnapshot,
                  targets: () async -> [DevToolsTarget]) async {
        // Record before target discovery can suspend and allow another poll.
        completedAccountRequests[action.requestID] = snapshot
        completedAccountRequestOrder.append(action.requestID)
        if completedAccountRequestOrder.count > 64 {
            let expired = completedAccountRequestOrder.removeFirst()
            completedAccountRequests[expired] = nil
            receivedAccountRequestIDs.remove(expired)
        }
        for target in await targets() {
            _ = try? await devTools.evaluateBoolean(
                RendererScript.completeAccountPopoverAction(action, snapshot: snapshot), in: target
            )
        }
    }
}
