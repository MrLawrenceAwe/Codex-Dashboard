# Codex Dashboard

Codex Dashboard is a native macOS controller that adds a recent-thread dashboard
to the local Codex app. It relaunches Codex with a loopback-only DevTools connection
and injects a removable dashboard into the main renderer.

## Install

Run:

```sh
./install.sh
```

This runs the test suite, builds and ad-hoc signs `Codex Dashboard.app`, then
installs it in `$HOME/Applications`. Use `./install.sh --relaunch` to open the
new build, or `--skip-tests` during local iteration. `--no-launch` is the
default and is also accepted explicitly.

To uninstall without permanently deleting the bundle, run `./uninstall.sh`.
It moves the installed app to the Trash.

## Use

1. Open **Codex Dashboard** from `$HOME/Applications`.
2. Finish any active response in Codex.
3. Select **Restart & Enable**.
4. Select **Thread Dashboard** directly in the Codex sidebar. It opens in
   the main content pane while the rest of Codex navigation stays available.

The application must remain running to refresh thread activity and restore the dashboard after renderer reloads,
but its controller window can be closed; menu-bar controls remain available. Launch at Login is optional. Use
**Disable Thread Dashboard** to unload the injected UI immediately. A normal Codex restart also
removes it.

## Architecture

- Native SwiftUI control panel; no browser automation or Node runtime.
- Single-instance startup arbitration prevents older controllers from overwriting the active dashboard.
- Loopback-only Chromium DevTools connection managed by `LiveDashboardRuntime` and `DashboardRenderer`.
- Versioned dashboard resources under `Sources/CodexDashboard/Resources/Dashboard`.
- A read-only compatibility check reports storage, rollout-event, renderer, sidebar, unread-state, composer, and composer-control contract drift after Codex updates.
- Swift source is grouped by application UI, compatibility checks, thread data, renderer runtime, and shared support concerns; tests mirror those boundaries.
- Local thread metadata from `state_5.sqlite` and explicit turn lifecycle events from thread rollout files, reconciled against the current Codex app launch so interrupted work does not remain active forever.
- Activity snapshots run every two seconds while Codex or the controller is active; unread state refreshes independently every 500 milliseconds and working-tree status every ten seconds. Background cadence drops to eight seconds, one second, and thirty seconds respectively. Silent renderer-only read-state changes have a bounded fallback: 1.5 seconds after a native snapshot, then every three seconds while the dashboard is open, ten seconds while closed, and thirty seconds while hidden.
- Threads are ordered by Codex's last final response, so in-progress commentary does not reshuffle them. Before the first final response, creation time is used. The most recent 60 are loaded, and the dashboard explicitly shows the loaded and total counts so the scope of search is clear.
- Threads can be viewed by collapsible project or as one list sorted by most recently updated.
- Unread dots and the Unread filter use Codex's complete persisted local unread set, including threads not currently mounted in the sidebar.
- Grouped projects show a quiet marker when their Git working tree has uncommitted changes, and the **Changed projects** filter isolates those projects.
- Changed project groups expose **Commit or push**, which opens the most recent idle thread for that project and dispatches Codex's native Git command. The Environment-panel control is retained as a compatibility fallback.
- A **Prompts** button sits beside the composer’s **Add** button for one-click access to the local prompt library. Saved prompts can be organised into named collapsible sections, reordered or moved between sections with drag and drop, created, edited, deleted, and inserted into the current chat without leaving Codex.
- Prompt search, duplication, JSON import/export, `{{selection}}` and `{{clipboard}}` placeholders, and an automatic app-owned backup under `~/Library/Application Support/Codex Dashboard/` protect and speed up reusable prompt workflows.
- Dashboard filter, grouping, and collapsed-project preferences persist across renderer reloads.
- The menu-bar controller provides open, sync, restart, diagnostics, and launch-at-login actions after the main window is closed.
- Independent native macOS completion notifications use both lifecycle transitions and unread-state changes, so short turns are still detected when Codex's own alerts are missed. They can be disabled from the controller or menu bar.
- Compatibility checks run automatically and are highlighted after the installed Codex version changes. Blocking drift prevents remounting until it is reviewed.
- Diagnostics show versions, refresh state, thread counts, renderer targets, warnings, and the prompt-backup location, and can be copied in one action.
- No modification of `/Applications/ChatGPT.app` or its code signature.
- A native-looking **Thread Dashboard** sidebar item is inserted beside Codex's other
  top-level destinations; there is no floating launcher.
- Codex host selectors are isolated in `codex-host.js`; prompt storage, composer-launcher integration, dialog rendering, composer insertion, dashboard rendering, and host exposure live in focused modules listed by `injection-manifest.json`.

This is an unofficial personal integration. Codex updates can require dashboard
injection maintenance.
