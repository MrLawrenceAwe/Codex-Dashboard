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
All controls are available from the menu bar, with a separate Diagnostics window available on demand. Launch at Login is optional. By default, the utility brings Codex to the foreground and opens the completed task on task completion, except for chats started in the ChatGPT Chrome extension; this can be disabled from the menu bar. Use
**Disable Task Dashboard** to unload the injected UI immediately. A normal Codex restart also
removes it.

## Architecture

- Native SwiftUI menu-bar utility with an on-demand diagnostics window; no browser automation or Node runtime.
- Single-instance startup arbitration prevents older controllers from overwriting the active dashboard.
- Loopback-only Chromium DevTools connection managed by `LocalCodexDashboardRuntime` and `DashboardRenderer`.
- Versioned dashboard resources under `Sources/CodexDashboard/Resources/Dashboard`, grouped into `Core`, `Accounts`, `Threads`, `Todos`, `Sidebar`, and `Prompts`.
- The injection manifest is the source of truth for both runtime resources and compatibility contract bundles. Prompt-library schema values are defined once in Swift and injected into the renderer contract. The injection version hashes the assembled payload, including that schema.
- A read-only compatibility check reports storage, rollout-event, renderer, sidebar, unread-state, composer, and composer-control contract drift after Codex updates.
- Swift source is grouped by application coordination, accounts, compatibility checks, prompt persistence, thread data, renderer runtime, and shared support concerns; tests mirror those boundaries and are split by behaviour.
- Local thread metadata from `state_5.sqlite` and explicit turn lifecycle events from thread rollout files, reconciled against the current Codex app launch so interrupted work does not remain active forever.
- `CodexDataChangeMonitor` watches catalog, unread, and account files; `WorkingTreeChangeMonitor` owns project and Git metadata watches, with recursive events supplied by `RecursiveProjectChangeMonitor`. Their debounce policies remain separate. These local filesystem notifications accelerate refreshes. Git metadata notifications also follow linked-worktree pointers to the metadata directory that actually changes. Authoritative catalog polling runs every two seconds and unread-state polling every 500 milliseconds while active; background cadence drops to eight seconds and one second respectively. Working-tree fallback polling runs every 15 seconds while active and every minute in the background, and returning to Codex forces an immediate status refresh. Git status checks disable optional locks so observation does not itself generate repository-change events. Silent renderer-only read-state changes retain a bounded fallback: 1.5 seconds after a native snapshot, then every three seconds while the dashboard is open, ten seconds while closed, and thirty seconds while hidden.
- Threads are ordered by Codex's indexed recency metadata, avoiding historical rollout scans. All threads active during the current Codex process remain in the catalog and have their latest lifecycle envelope inspected, even beyond the usual 500-thread history limit. The renderer initially mounts the 10 most recent matching tasks and exposes **Load more** in 10-task pages.
- Threads are grouped into collapsible projects. **Recents** is the default dashboard view, alongside **Running**, **Unread**, and **Changed projects** filters.
- Hover or keyboard-focus a native sidebar project and use its colour button to highlight the project name. Choose from six colours or **No highlight**; reuse a colour for any number of projects (for example, green for active projects). Choices persist locally by project ID across reloads and project renames.
- Native sidebar projects show a disclosure chevron and remain individually collapsible through Codex's own project-row interaction.
- Unread dots and the Unread filter use Codex's complete persisted local unread set, including tasks outside the recent-history limit and tasks not mounted in the sidebar. Newly unread tasks outside the loaded catalog trigger an immediate catalog refresh. Returning to Codex refreshes persisted unread state before the catalog, and opening the dashboard immediately reconciles live sidebar read state. Only matching local sidebar rows can override local state; unchanged sidebar values cannot repeatedly override newer persisted changes. Live changes survive persistence lag until acknowledged or superseded by new task activity. Opening a task does not optimistically mark it read; Codex remains the source of truth.
- Grouped projects show a quiet marker when their Git working tree has uncommitted changes, and the **Changed projects** filter isolates those projects. Running changed projects remain visible there, while Commit or push waits for an idle project thread.
- Changed project groups expose **Mute change alerts** and **Commit or push**. Mute change alerts hides that project's change notifications until restored; Commit or push opens the most recent idle thread only when Codex's native Git command is available.
- A **Prompts** button sits beside the composer’s **Add** button for one-click access to the local prompt library. Saved prompts can be global or limited to the active project, organised into named collapsible sections, reordered or moved between sections with drag and drop, created, edited, deleted, and inserted into the current chat without leaving Codex. Renderer edits are staged locally until the native bridge persists and acknowledges them. The canonical library is stored at `~/Library/Application Support/Codex Dashboard/prompt-library.json`, with rolling backups and import/export controls in Diagnostics.
- Prompt search, keyboard and pointer reordering, section rename/deletion, and `{{selection}}` and `{{clipboard}}` placeholders speed up reusable prompt workflows. Prompts can optionally apply saved model, reasoning-effort (including Max and Ultra), and Standard/Fast speed settings through Codex's model list, Power slider, and speed controls before insertion. Unavailable or locked selections stop insertion; saved model identifiers remain intact and editable when Codex's model list changes. Deleting a section moves its prompts to **General** rather than deleting them.
- Dashboard filter and collapsed-project preferences persist across renderer reloads.
- The menu bar provides dashboard, restart, disable, compatibility, diagnostics, completion foregrounding, and launch-at-login actions.
- Multiple Codex accounts can be saved under their authenticated OpenAI names and switched from either the menu bar or the Task Dashboard header. Credential blobs stay in macOS Keychain; the non-secret saved-account list and Codex account identifiers are stored in `~/Library/Application Support/Codex Dashboard/accounts.json`. The active saved account is reconciled with Codex's current sign-in before it is displayed or switched. External sign-in changes clear the previous account's displayed usage and reset the usage session before another request. Switching waits for idle tasks, preserves the shared Codex thread/configuration directory, updates the active account atomically, restarts Codex, and rolls back if relaunch fails.
- Account orchestration, active credential-file access, saved-account document persistence, and credential identity decoding are isolated so transaction and migration behaviour can be tested independently.
- The menu-bar account submenu shows each saved account's five-hour and weekly Codex usage remaining, countdowns and local date/time for each timed reset, and the number of available banked resets with the nearest known expiry. The active account refreshes every 30 seconds while Codex is running and immediately when the account menu opens or a task completes. Inactive accounts refresh every five minutes through short-lived isolated Codex homes populated from macOS Keychain, without switching or restarting Codex; manual per-account and update-all actions are also available. Background and interactive batch refresh share one account coordinator operation, with explicit Keychain interaction policy and one cache write per batch. Refreshed credentials return to Keychain, isolated homes are removed after each request, and non-sensitive usage snapshots remain cached locally with timestamps across relaunches.
- macOS and optional phone notifications are scheduled one hour before five-hour resets only while both weekly and five-hour usage remain, and 72 hours, 48 hours, 36 hours, 24 hours, 12 hours, five hours, and one hour before weekly resets and the next banked-reset expiry. Every alert includes the exact local reset or expiry time. The dashboard immediately alerts when a five-hour or weekly usage window falls below 80%, 50%, or 20% remaining; each threshold fires once per reset window. If Codex revises a deadline after its normal warning point, one clearly labelled time-update alert reports the new time instead of sending a late “one hour” warning. The dashboard also immediately alerts when a five-hour or weekly usage amount drops before its previously scheduled reset, which catches unexpected OpenAI-applied resets. Limit-reset alerts identify the account and report the latest five-hour, weekly, and banked-reset amounts remaining; banked-reset alerts report how many resets are available. Five-hour threshold and reset alerts are likewise suppressed after weekly usage is exhausted.
- Optional phone reset notifications use the free ntfy service. Enable them in Diagnostics, subscribe to the generated private topic in the ntfy phone app, and use **Send Test** to verify delivery. The topic is stored locally; only the alert title and message are sent to `ntfy.sh`. Successful reset alerts are recorded locally so refreshes and relaunches do not send duplicates. Both five-hour and weekly limits also send an immediate alert after the dashboard observes their scheduled reset, including the new remaining percentage and next reset time.
- Compatibility checks run automatically after the installed Codex version changes. Warnings and incompatibilities replace the normal menu-bar icon; the icon tooltip, menu, notification, copied diagnostics, and Diagnostics window identify the exact failed check. Blocking drift prevents remounting until it is reviewed.
- Diagnostics show versions, refresh state, thread counts, renderer targets, and warnings, and can be copied in one action.
- No modification of `/Applications/ChatGPT.app` or its code signature.
- A native-looking **Task Dashboard** sidebar item is inserted beside Codex's other
  top-level destinations; there is no floating launcher.
- A neighboring **To-dos** destination stores a lightweight personal task list locally.
- Injection startup and shared page navigation live in `Core`; `dashboard-bridge.js` exposes the native-to-renderer API and `createPageVisibilityController` manages page visibility. Task Dashboard and To-dos own their page controllers, with to-do interactions in `todo-list-controller.js` and markup and rendering in `todo-list-view.js`.
- Codex host selectors and injected-page lifecycle code are isolated in `Core`; account controls, prompt storage and UI, composer integration, and thread rendering live in focused modules listed by `injection-manifest.json`.

This is an unofficial personal integration. Codex updates can require dashboard
injection maintenance.

## Account switching

1. While signed in to Codex, choose **Accounts → Save Current Account**. The dashboard uses the authenticated account's name automatically.
2. Choose **Sign In to Another Account…**. Codex restarts signed out; complete the normal OpenAI sign-in in Codex.
3. Save the second account. You can then switch between the saved accounts from the menu bar or the account selector in **Task Dashboard**.

Codex still uses one active account at a time. The switcher does not merge accounts, transfer subscriptions or usage, or rotate accounts automatically. Do not commit, export, or manually copy `~/.codex/auth.json`.

## Development preview

Run `./DashboardPreview/generate.sh`, then open `DashboardPreview/index.html` in a
browser. Regenerate after changing renderer resources or the prompt schema. The
ignored `injection.js` is built by the production `InjectionBundle` loader, including
the Swift-defined prompt schema; preview fixtures use the current thread contract.
Generation exits before starting the menu-bar application.

Shared page visibility, navigation-button construction, and icons live in `Core`. Initial mounting and renderer repairs share one mounting operation. `Threads/thread-unread-state.js` owns unread reconciliation, completion ticks, polling, and the snapshot thread-ID index. The prompt controller receives an
explicit thread lookup for composer context. Native import/export and renderer
persistence share the prompt store constructed by the application coordinator.

Internal Codex data uses `Thread` terminology; UI copy uses **Task**. Renderer snapshots use `RendererThread`. Project change preferences use `mutedProjectPaths`; a one-time migration preserves values from the previous stored field. To-do edits share persistence rollback, and image drafts use explicit loading, ready, invalid, and empty states.

## Visual baselines

The web test suite compares wide dark, medium light, and narrow dark screenshots against committed baselines. After an intentional visual change, regenerate them with:

```sh
UPDATE_VISUAL_BASELINES=1 swift test --filter DashboardVisualRegressionTests
```
