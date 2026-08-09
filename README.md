# Codex Dashboard

Codex Dashboard is a native macOS controller for an active-thread dashboard
inside the Codex experience in ChatGPT. It follows the useful part of Attune's
architecture—a normal app relaunch with a loopback-only DevTools bridge—while
keeping functional UI extensions separate from Attune's deliberately CSS-only
safety contract.

## Install

Run:

```sh
./install.sh
```

This builds and ad-hoc signs `Codex Dashboard.app`, then installs it in
`$HOME/Applications`.

## Use

1. Open **Codex Dashboard** from `$HOME/Applications`.
2. Finish any active response in ChatGPT.
3. Select **Restart Codex & Enable Dashboard**.
4. Select **Dashboard** directly in the Codex sidebar. The dashboard opens in
   the main content pane while the rest of Codex navigation stays available.

The controller must remain open to refresh thread activity and restore the dashboard after renderer reloads. Use
**Disable Dashboard** to unload the injected UI immediately. A normal ChatGPT restart also
removes it.

## Architecture

- Native SwiftUI control panel; no browser controller or Node runtime.
- Single-instance startup arbitration prevents older controllers from overwriting the active dashboard.
- Loopback-only Chromium DevTools connection.
- Versioned dashboard resources under `Sources/CodexDashboard/Resources/Dashboard`.
- Local thread metadata from `state_5.sqlite` and explicit turn lifecycle events from thread rollout files.
- Threads are ordered by their last update. The dashboard loads the latest 60; search and filters apply to the loaded set.
- Threads can be viewed by collapsible project or as one list sorted by most recently updated.
- Completed responses receive an unread dot until their thread is opened from the dashboard or Codex sidebar, and the Unread filter collects them in one view.
- Grouped projects show a quiet marker when their Git working tree has uncommitted changes.
- No modification of `/Applications/ChatGPT.app` or its code signature.
- A native-looking **Dashboard** sidebar item is inserted beside Codex's other
  top-level destinations; there is no floating launcher.
- Host selectors are isolated in `dashboard.js` for maintenance after Codex UI updates.

This is an unofficial personal integration. ChatGPT updates can require adapter
maintenance.
