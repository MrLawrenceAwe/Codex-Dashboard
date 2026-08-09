# Codex Dashboard

Codex Dashboard is a native macOS controller that adds a recent-thread dashboard
to the local Codex app. It relaunches Codex with a loopback-only DevTools bridge
and injects a removable dashboard into the main renderer.

## Install

Run:

```sh
./install.sh
```

This builds and ad-hoc signs `Codex Dashboard.app`, then installs it in
`$HOME/Applications`.

## Use

1. Open **Codex Dashboard** from `$HOME/Applications`.
2. Finish any active response in Codex.
3. Select **Restart & Enable Dashboard**.
4. Select **Dashboard** directly in the Codex sidebar. The dashboard opens in
   the main content pane while the rest of Codex navigation stays available.

The controller must remain open to refresh thread activity and restore the dashboard after renderer reloads. Use
**Disable Dashboard** to unload the injected UI immediately. A normal Codex restart also
removes it.

## Architecture

- Native SwiftUI control panel; no browser automation or Node runtime.
- Single-instance startup arbitration prevents older controllers from overwriting the active dashboard.
- Loopback-only Chromium DevTools bridge managed by `CodexHostSession`.
- Versioned dashboard resources under `Sources/CodexDashboard/Resources/Dashboard`.
- Local thread metadata from `state_5.sqlite` and explicit turn lifecycle events from thread rollout files, reconciled against the current Codex app launch so interrupted work does not remain active forever.
- Activity snapshots run on a fixed two-second cadence; Git status enrichment refreshes independently every ten seconds.
- Threads are ordered by Codex's last final response, so in-progress commentary does not reshuffle them. Before the first final response, creation time is used. The dashboard loads the latest 60; search and filters apply to the loaded set.
- Threads can be viewed by collapsible project or as one list sorted by most recently updated.
- Unread dots and the Unread filter mirror Codex's own sidebar read state.
- Grouped projects show a quiet marker when their Git working tree has uncommitted changes, and the Uncommitted filter isolates those projects.
- No modification of `/Applications/ChatGPT.app` or its code signature.
- A native-looking **Dashboard** sidebar item is inserted beside Codex's other
  top-level destinations; there is no floating launcher.
- Codex UI selectors are isolated in `dashboard.js` for maintenance after app updates.

This is an unofficial personal integration. Codex updates can require dashboard
injection maintenance.
