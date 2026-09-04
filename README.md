# Codex Dashboard

Codex Dashboard is a native macOS menu-bar utility that adds a recent-task dashboard
to the local Codex app. It relaunches Codex with a loopback-only DevTools connection
and injects a removable dashboard into the main renderer.

The DevTools connection is limited to the local machine and uses a new high port each
time the dashboard launches, but Chromium DevTools does not authenticate local clients.
Use this utility only on a trusted personal macOS account; do not leave Codex running
with the dashboard enabled when untrusted local software has access to your account.

## Install

Run:

```sh
./install.sh
```

This runs the test suite, builds and ad-hoc signs `Codex Dashboard.app`, then
atomically installs it in `$HOME/Applications`, preserving the previous bundle until the replacement is verified. Use `./install.sh --relaunch` to open the
new build, or `--skip-tests` during local iteration. `--no-launch` is the
default and is also accepted explicitly.

To uninstall without permanently deleting the bundle, run `./uninstall.sh`.
It moves the installed app to the Trash.

## Use

1. Open **Codex Dashboard** from `$HOME/Applications`; it appears in the menu bar.
2. Finish any active response in Codex.
3. Select **Restart & Enable**.
4. Select **Task Dashboard** directly in the Codex sidebar. It opens in
   the main content pane while the rest of Codex navigation stays available.

Select **To-dos** in the same sidebar area to keep a personal task list in Codex's
local renderer storage.
Each to-do can be edited, completed, filtered, or deleted without leaving the app.

The application runs without a main window and must remain open to refresh thread activity and restore the dashboard after renderer reloads.
All controls are available from the menu bar, with a separate Diagnostics window available on demand. Launch at Login is optional. By default, the utility brings Codex to the foreground and opens the completed task on task completion; this can be disabled from the menu bar. Use
**Disable Task Dashboard** to unload the injected UI immediately. A normal Codex restart also
removes it.

## Architecture

- Native SwiftUI menu-bar utility with an on-demand diagnostics window; no browser automation or Node runtime.
- Single-instance startup arbitration prevents older controllers from overwriting the active dashboard.
- Loopback-only Chromium DevTools connection managed by `LocalCodexDashboardRuntime` and `DashboardRenderer`.
- Versioned dashboard resources under `Sources/CodexDashboard/Resources/Dashboard`, grouped into `Core`, `Accounts`, `Threads`, and `Prompts`.
- The injection manifest is the source of truth for both runtime resources and compatibility contract bundles. Prompt-library schema values are defined once in Swift and injected into the renderer contract.
- A read-only compatibility check reports storage, rollout-event, renderer, sidebar, unread-state, composer, and composer-control contract drift after Codex updates.
- Swift source is grouped by application coordination, accounts, compatibility checks, prompt persistence, thread data, renderer runtime, and shared support concerns; tests mirror those boundaries and are split by behaviour.
- Local thread metadata from `state_5.sqlite` and explicit turn lifecycle events from thread rollout files, reconciled against the current Codex app launch so interrupted work does not remain active forever.
- Thread, unread-state, and project-directory changes use local filesystem notifications as an accelerator. Git metadata notifications also follow linked-worktree pointers to the metadata directory that actually changes. Authoritative catalog polling runs every two seconds and unread-state polling every 500 milliseconds while active; background cadence drops to eight seconds and one second respectively. Working-tree fallback polling runs every 15 seconds while active and every minute in the background, and returning to Codex forces an immediate status refresh. Git status checks disable optional locks so observation does not itself generate repository-change events. Silent renderer-only read-state changes retain a bounded fallback: 1.5 seconds after a native snapshot, then every three seconds while the dashboard is open, ten seconds while closed, and thirty seconds while hidden.
- Threads are ordered by Codex's indexed recency metadata, avoiding historical rollout scans. Only threads active during the current Codex process have their latest lifecycle envelope inspected. The renderer initially mounts 60 matching threads and exposes **Load more threads** in 60-thread pages to keep the DOM responsive.
- Threads are grouped into collapsible projects. **Running** is the default dashboard view, alongside focused **Unread** and **Changed projects** filters.
- Native sidebar projects show a disclosure chevron and remain individually collapsible through Codex's own project-row interaction.
- Unread dots and the Unread filter use Codex's complete persisted local unread set, including threads not currently mounted in the sidebar.
- Grouped projects show a quiet marker when their Git working tree has uncommitted changes, and the **Changed projects** filter isolates those projects. Running changed projects remain visible there, while Commit or push waits for an idle project thread.
- Changed project groups expose **Ignore** and **Commit or push**. Ignore hides that project's change notifications until restored; Commit or push opens the most recent idle thread only when Codex's native Git command is available.
- A **Prompts** button sits beside the composer’s **Add** button for one-click access to the local prompt library. Saved prompts can be global or limited to the active project, organised into named collapsible sections, reordered or moved between sections with drag and drop, created, edited, deleted, and inserted into the current chat without leaving Codex. The canonical library is stored at `~/Library/Application Support/Codex Dashboard/prompt-library.json`, with rolling backups and import/export controls in Diagnostics.
- Prompt search, keyboard and pointer reordering, section rename/deletion, and `{{selection}}` and `{{clipboard}}` placeholders speed up reusable prompt workflows. Prompts can optionally apply saved model, reasoning-effort (including Max and Ultra), and Standard/Fast speed settings through Codex's model list, Power slider, and speed controls before insertion. Unavailable or locked selections stop insertion; saved model identifiers remain intact and editable when Codex's model list changes. Deleting a section moves its prompts to **General** rather than deleting them.
- Dashboard filter and collapsed-project preferences persist across renderer reloads.
- The menu bar provides dashboard, restart, disable, compatibility, diagnostics, completion foregrounding, and launch-at-login actions.
- Multiple Codex accounts can be saved under their authenticated OpenAI names and switched from either the menu bar or the Task Dashboard header. Credential blobs stay in macOS Keychain; the non-secret saved-account list and Codex account identifiers are stored in `~/Library/Application Support/Codex Dashboard/accounts.json`. The active saved account is reconciled with Codex's current sign-in before it is displayed or switched. Switching waits for idle tasks, preserves the shared Codex thread/configuration directory, updates the active account atomically, restarts Codex, and rolls back if relaunch fails.
- Account orchestration, active credential-file access, saved-account document persistence, and credential identity decoding are isolated so transaction and migration behaviour can be tested independently.
- The menu-bar account submenu shows each saved account's five-hour and weekly Codex usage remaining, countdowns and local date/time for each timed reset, and the number of available banked resets with the nearest known expiry. The active account refreshes every 30 seconds while Codex is running and immediately when the account menu opens or a task completes. Inactive accounts refresh every five minutes through short-lived isolated Codex homes populated from macOS Keychain, without switching or restarting Codex; manual per-account and update-all actions are also available. Refreshed credentials return to Keychain, isolated homes are removed after each request, and non-sensitive usage snapshots remain cached locally with timestamps across relaunches.
- Compatibility checks run automatically and are highlighted after the installed Codex version changes. Blocking drift prevents remounting until it is reviewed.
- Diagnostics show versions, refresh state, thread counts, renderer targets, and warnings, and can be copied in one action.
- No modification of `/Applications/ChatGPT.app` or its code signature.
- A native-looking **Task Dashboard** sidebar item is inserted beside Codex's other
  top-level destinations; there is no floating launcher.
- A neighboring **To-dos** destination stores a lightweight personal task list locally.
- Codex host selectors and injected-page lifecycle code are isolated in `Core`; account controls, prompt storage and UI, composer integration, and thread rendering live in focused modules listed by `injection-manifest.json`.

This is an unofficial personal integration. Codex updates can require dashboard
injection maintenance.

## Account switching

1. While signed in to Codex, choose **Accounts → Save Current Account**. The dashboard uses the authenticated account's name automatically.
2. Choose **Sign In to Another Account…**. Codex restarts signed out; complete the normal OpenAI sign-in in Codex.
3. Save the second account. You can then switch between the saved accounts from the menu bar or the account selector in **Task Dashboard**.

Codex still uses one active account at a time. The switcher does not merge accounts, transfer subscriptions or usage, or rotate accounts automatically. Do not commit, export, or manually copy `~/.codex/auth.json`.

## Visual baselines

The web test suite compares wide dark, medium light, and narrow dark screenshots against committed baselines. After an intentional visual change, regenerate them with:

```sh
UPDATE_VISUAL_BASELINES=1 swift test --filter DashboardVisualRegressionTests
```
