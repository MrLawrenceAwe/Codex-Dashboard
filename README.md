# Codex Dashboard

Codex Dashboard is a native macOS controller that adds a recent-thread dashboard
to the local Codex app. It relaunches Codex with a loopback-only DevTools connection
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
3. Select **Restart & Enable**.
4. Select **Thread Dashboard** directly in the Codex sidebar. It opens in
   the main content pane while the rest of Codex navigation stays available.

The controller must remain open to refresh thread activity and restore the dashboard after renderer reloads. Use
**Disable Thread Dashboard** to unload the injected UI immediately. A normal Codex restart also
removes it.

## Architecture

- Native SwiftUI control panel; no browser automation or Node runtime.
- Single-instance startup arbitration prevents older controllers from overwriting the active dashboard.
- Loopback-only Chromium DevTools connection managed by `LiveDashboardRuntime` and `DashboardRenderer`.
- Versioned dashboard resources under `Sources/CodexDashboard/Resources/Dashboard`.
- A read-only compatibility check reports storage, rollout-event, renderer, sidebar, unread-state, composer, and prompt-menu contract drift after Codex updates.
- Swift source is grouped by application UI, compatibility checks, thread data, renderer runtime, and shared support concerns; tests mirror those boundaries.
- Local thread metadata from `state_5.sqlite` and explicit turn lifecycle events from thread rollout files, reconciled against the current Codex app launch so interrupted work does not remain active forever.
- Activity snapshots run on a fixed two-second cadence; unread state refreshes independently every 500 milliseconds, and working-tree status enrichment every ten seconds. Visible sidebar read-state changes have an additional 250-millisecond renderer fallback.
- Threads are ordered by Codex's last final response, so in-progress commentary does not reshuffle them. Before the first final response, creation time is used. The dashboard loads the latest 60; search and filters apply to the loaded set.
- Threads can be viewed by collapsible project or as one list sorted by most recently updated.
- Unread dots and the Unread filter use Codex's complete persisted local unread set, including threads not currently mounted in the sidebar.
- Grouped projects show a quiet marker when their Git working tree has uncommitted changes, and the **Changed projects** filter isolates those projects.
- The composer’s **Add** menu includes a local **Prompts** library. Saved prompts can be organised into named collapsible sections, reordered or moved between sections with drag and drop, created, edited, deleted, and inserted into the current chat without leaving Codex.
- No modification of `/Applications/ChatGPT.app` or its code signature.
- A native-looking **Thread Dashboard** sidebar item is inserted beside Codex's other
  top-level destinations; there is no floating launcher.
- Codex host selectors are isolated in `codex-host.js`; prompt storage, menu integration, dialog rendering, composer insertion, dashboard rendering, and host exposure live in focused modules listed by `injection-manifest.json`.

This is an unofficial personal integration. Codex updates can require dashboard
injection maintenance.
