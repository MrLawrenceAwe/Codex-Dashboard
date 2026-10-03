# Architecture and behaviour

## Runtime and integration

- Native SwiftUI menu-bar utility with an on-demand diagnostics window; no browser automation or Node runtime.
- Single-instance startup arbitration prevents older controllers from overwriting the active dashboard.
- Loopback-only Chromium DevTools connection managed by `LocalCodexDashboardRuntime` and `DashboardRenderer`.
- Versioned dashboard resources under `Sources/CodexDashboard/Resources/Dashboard`, grouped into `Core`, `Accounts`, `Composer`, `Threads`, `Todos`, `Sidebar`, `Prompts`, and `Reviews`.
- The injection manifest is the source of truth for both runtime resources and compatibility contract bundles. Prompt-library and shared composer-preset schema values are defined once in Swift and injected into the renderer contract. The injection version hashes the assembled payload, including that schema.
- Swift source is grouped by application coordination, accounts, compatibility checks, prompt persistence, thread data, renderer runtime, and shared support concerns; tests mirror those boundaries and are split by behaviour.
- Local thread metadata from `state_5.sqlite` and explicit turn lifecycle events from thread rollout files, reconciled against the current Codex app launch so interrupted work does not remain active forever.
- The menu bar provides dashboard, restart, compatibility, diagnostics, completion foregrounding, and launch-at-login actions. **Disable dashboard integration** removes all injected pages and controls, including To-dos and Prompts.
- Subprocess deadlines cover process termination and complete stdout/stderr draining. Nonblocking pipe readers close on timeout or cancellation even if a descendant retains a write end.
- No modification of `/Applications/ChatGPT.app` or its code signature.
- The renderer bridge connects native snapshots to feature controllers and restores injected pages after host reloads. See the [renderer module map and contracts](development.md#code-organisation) for source ownership and integration details.

## Chat overview and projects

- Threads are ordered by Codex's indexed recency metadata, avoiding historical rollout scans. All threads active during the current Codex process remain in the catalog and have their latest lifecycle envelope inspected, even beyond the usual 500-thread history limit. The renderer initially mounts the 10 most recent matching tasks and exposes **Load more** in 10-task pages.
- **All chats** is the default dashboard view, with all running tasks above the paged recent tasks. **Unread** groups chats into collapsible projects; **Local changes** shows projects with uncommitted changes or unpushed commits.
- Hover or keyboard-focus a native sidebar project and use its colour button to highlight the project name. Choose from seven colours or **No highlight**; reuse a colour for any number of projects (for example, green for active projects). Choices persist locally by project ID across reloads and project renames.
- Native sidebar projects show a disclosure chevron and remain individually collapsible through Codex's own project-row interaction.
- Persisted unread status is scoped to the active authenticated principal (Codex’s hash of the account and user IDs). Account changes invalidate the unread cache even when the global-state file is unchanged; saved identities never contribute unread flags to the current account.
- Unread dots and the Unread filter use Codex's complete persisted local unread set, including tasks outside the recent-history limit and tasks not mounted in the sidebar. Newly unread tasks outside the loaded catalog trigger an immediate catalog refresh. Returning to Codex refreshes persisted unread state before the catalog, and opening the dashboard immediately reconciles live sidebar read state. Only matching local sidebar rows can override local state; unchanged sidebar values cannot repeatedly override newer persisted changes. Live changes survive persistence lag until acknowledged or superseded by new task activity. Opening a task does not optimistically mark it read; Codex remains the source of truth.
- Chat overview uses Codex’s saved projects and roots for project names and grouping. Symlink aliases resolve to one saved root. Removing a project removes its change indicators and moves its remaining chats to **Other chats**; it does not archive or delete them. The original chat checkout path remains available for review-loop isolation.
- Grouped projects show separate markers for uncommitted changes and unpushed commits, and the **Local changes** filter isolates those projects. Unpushed status compares HEAD with local upstream refs, or all remote refs when no upstream exists; it never fetches. A repository without a remote only reports uncommitted changes. Running changed projects remain visible there, while Commit or push waits for an idle project thread.
- Changed project groups expose **Hide change indicators** and **Commit or push**. Hide change indicators suppresses that project's visual change indicators and groups it under **Indicators hidden** until restored. **Commit or push** remains available while indicators are hidden; Commit or push opens the most recent idle thread and selects **Commit** from Codex's **Git actions** menu to open the native dialog.
- Dashboard filter and collapsed-project preferences persist across renderer reloads.
- A native-looking **Chat overview** sidebar item is inserted beside Codex's other
  top-level destinations; there is no floating launcher.

## Refresh and monitoring

- `CodexDataChangeMonitor` watches catalog, unread, and account files; `WorkingTreeChangeMonitor` owns project and Git metadata watches, with recursive events supplied by `RecursiveProjectChangeMonitor`. Their debounce policies remain separate. These local filesystem notifications accelerate refreshes. Git metadata notifications also follow linked-worktree pointers to the metadata directory that actually changes. Returning to Codex forces an immediate Git status refresh. Git status checks disable optional locks so observation does not itself generate repository-change events.

Polling intervals are defined by `App/Monitoring/RefreshScheduler.Schedule`. File events and user actions can trigger earlier refreshes; intervals are waits after each operation finishes.

| Refresh | Active | Background |
| --- | --- | --- |
| Thread catalog | 2 seconds | 8 seconds |
| Native unread state, with file monitoring | 15 seconds | 60 seconds |
| Native unread state, without file monitoring | 500 milliseconds | 1 second |
| Project Git status fallback | 15 seconds | 60 seconds |
| Active-account usage | 2 minutes | Skipped |
| Inactive-account usage | 5 minutes | 5 minutes |

Renderer unread reconciliation runs 1.5 seconds after a native snapshot, then every 3 seconds with Chat overview open, 10 seconds with it closed, or 30 seconds while the renderer is hidden.

## Prompts and to-dos

- A **Prompts** button sits beside the composer’s **Add** button for one-click access to the local prompt library. Saved prompts can be global or limited to the active project, organised into named collapsible sections, reordered or moved between sections with drag and drop, created, edited, deleted, and inserted into the current chat without leaving Codex. Renderer edits are staged locally until the native bridge persists and acknowledges them. The canonical library is stored at `~/Library/Application Support/Codex Dashboard/prompt-library.json`, with rolling backups and import/export controls in Diagnostics.
- Prompt search, keyboard and pointer reordering, section rename/deletion, and `{{selection}}` and `{{clipboard}}` placeholders speed up reusable prompt workflows. Prompts can optionally apply saved model, reasoning-effort (including Max and Ultra), and Standard/Fast speed settings through Codex's model list, Power slider, and speed controls before insertion. Unavailable or locked selections stop insertion; saved model identifiers remain intact and editable when Codex's model list changes. Deleting a section moves its prompts to **General** rather than deleting them.
- A neighboring **To-dos** destination stores a lightweight personal task list locally. To-dos can link to an existing task or populate a new task with their text and image.
- To-do writes merge each window's changed fields into the latest shared document while preserving other windows' items and image references; concurrent deletions take precedence over stale edits, and storage notifications refresh open windows.
- Prompt edits use separate durable pending changes per window. The renderer combines those changes with the current native library before the native bridge saves and acknowledges them. Concurrent prompt and section deletions take precedence over stale edits; new or moved prompts targeting a deleted section go to General.

## Accounts

- Multiple Codex accounts can be saved under their authenticated OpenAI names and switched from **Codex profile menu → Accounts**. Credential blobs stay in macOS Keychain and are accessed through the separately signed `CodexDashboardKeychainHelper`, which verifies the Dashboard caller and keeps its build identity across UI rebuilds; the non-secret saved-account list and Codex account identifiers are stored in `~/Library/Application Support/Codex Dashboard/accounts.json`. The active saved account is reconciled with Codex's current sign-in before it is displayed or switched. External sign-in changes clear the previous account's displayed usage and reset the usage session before another request. Switching checks fresh task state for running tasks, cancels old usage requests without waiting for provider cleanup, preserves the shared Codex thread/configuration directory, updates the active account atomically, restarts Codex, and rolls back if relaunch fails. The dashboard mounts the preflight task snapshot immediately after relaunch; normal polling refreshes it for the new process. New usage requests wait for provider cleanup before reading the switched account.
- Credential-file changes automatically refresh Keychain credentials only for accounts still in the saved list. Forgetting an active account keeps Codex signed in without silently recreating the saved account; **Save current account** adds it again explicitly.
- Account orchestration, active credential-file access, saved-account document persistence, and credential identity decoding are isolated so transaction and migration behaviour can be tested independently.
- Account metadata loading, migration and Keychain transactions run on a serial worker queue; menu rendering uses the last published account snapshot while refreshes finish asynchronously. An unidentified active credential clears the active saved-account association and cannot replace a saved login. Active usage refreshes share one request across both metadata loading and usage fetching.
- The Accounts panel in Codex’s profile menu shows each saved account's five-hour and weekly Codex usage remaining, countdowns for each timed reset, and the number of available banked resets with the nearest known expiry. Active-account usage refreshes on the polling schedule in [Refresh and monitoring](#refresh-and-monitoring) and immediately when the account menu opens, Codex activates, or a chat completes. Inactive accounts refresh through short-lived isolated Codex homes populated from macOS Keychain, without switching or restarting Codex; manual per-account and update-all actions are also available. Background and interactive batch refresh share one account coordinator operation, with explicit Keychain interaction policy and one cache write per batch. Refreshed credentials return to Keychain, isolated homes are removed after each request, and non-sensitive usage snapshots remain cached locally with timestamps across relaunches.

## Usage notifications

- macOS and optional phone notifications are scheduled one hour before five-hour resets only while both weekly and five-hour usage remain, and 72 hours, 48 hours, 36 hours, 24 hours, 12 hours, five hours, and one hour before weekly resets and the next banked-reset expiry. Refreshed alerts include the current local reset or expiry time; if macOS delivers a scheduled fallback without a successful refresh, it labels the deadline as last recorded and asks the user to check current usage. Phone reminders retry a failed usage refresh instead of sending the old deadline. The dashboard immediately alerts when the five-hour window falls below 50% or 20% remaining, or the weekly window falls below 80%, 50%, or 20%; each threshold fires once per reset window. It also alerts when an observed account gains banked resets, including while weekly usage is exhausted; the first observation establishes the baseline. If Codex revises a deadline after its normal warning point, one clearly labelled time-update alert reports the new time instead of sending a late “one hour” warning. The dashboard also immediately alerts when a five-hour or weekly usage amount drops before its previously scheduled reset, which catches unexpected OpenAI-applied resets. Limit-reset alerts identify the account and report the latest five-hour and weekly amounts remaining, plus banked resets when available; banked-reset alerts report how many resets are available. Five-hour threshold and reset alerts are likewise suppressed after weekly usage is exhausted.
- Optional phone usage alerts use the free ntfy service. Enable them in Diagnostics, subscribe to the generated private topic in the ntfy phone app, and use **Send Test** to verify delivery. The topic is stored locally; only the alert title and message are sent to `ntfy.sh`. Successful reset alerts are recorded locally so refreshes and relaunches do not send duplicates. Both five-hour and weekly limits also send an immediate alert after the dashboard observes their scheduled reset, including the new remaining percentage and next reset time.
- When an account has no weekly usage remaining, automatic limit alerts for that account are suppressed, including weekly reminders, limit deadline updates, and their phone delivery retries. Banked-reset expiry reminders, expiry time updates, and their phone retries remain active. Refreshing usage cancels pending limit alerts; limit alerts resume when weekly allowance returns, including the observed weekly-reset notification. Explicit **Send Test** remains available.

## Compatibility and diagnostics

- A read-only compatibility check reports storage, rollout-event, renderer, sidebar, unread-state, composer, and composer-control contract drift after Codex updates.
- Compatibility checks run automatically after the installed Codex version changes. Warnings and incompatibilities replace the normal menu-bar icon; the icon tooltip, menu, notification, copied diagnostics, and Diagnostics window identify the exact failed check. Blocking drift prevents remounting until it is reviewed.
- Diagnostics show versions, refresh state, thread counts, renderer targets, and warnings, and can be copied in one action.

This is an unofficial personal integration. Codex updates can require dashboard
injection maintenance.


Notification models, pure planning, delivery, and history persistence live in
`Sources/CodexDashboard/Accounts/Notifications`. `UsageNotificationPlanner` builds a
single plan for each observation time. `DesktopUsageNotifier` and `NtfyUsageNotifier`
retain independent histories through `UsageNotificationHistory`, including immediate and phone deadline delivery records; successful delivery
on one channel never acknowledges delivery on the other. Existing durable keys are
preserved so refactoring cannot resend alerts or discard phone settings.

## Review loops

The sidebar includes a dedicated **Review loops** page beside **To-dos**. Choose a local,
single-folder project, a review type (bugs and issues; performance and responsiveness; combined bugs and performance; simplification and structure; simplification and naming; or content and quality), Standard or Fast speed, required separate review and fix models with optional supported reasoning efforts, and a maximum of 1–20 rounds (default 5). Bugs and performance reviews offer project context (general or personal). Bugs and performance reviews also offer a priority limit (**P0 only**, **P0–P1**, **P0–P2**, or **P0–P3**); P0–P2 includes P0, P1, and P2. Each review starts in a new chat on the same branch and checkout. Multiple projects can have active loops, with one active loop per project and checkout.

Bugs and issues, performance and responsiveness, and the combined review type offer optional **Live testing** (off by default). When enabled, review prompts add **Also use live testing to find bugs and issues.** Fix prompts add **Verify fixes for findings discovered through live testing using live testing.** The agent chooses the tools and methods. With live testing on, the **Browser extension** option adds **Use Computer Use to reload the browser extension before live testing.** The setting is saved with the loop and shown on its card. Existing saved loops migrate with live testing off.

The review prompt follows the selected review type. The bugs prompt is **Review project for bugs and issues.** The content prompt is **Review project for content accuracy, clarity, wording, consistency, completeness, presentation, and effectiveness for its intended purpose.** Content reviews cover non-code work such as CVs, documents, and presentations, report findings without priority labels, and use the standard address-and-commit follow-up. Selecting Personal project for a bugs or performance review adds **(this is a project for personal use)** before the final period.

Simplification and structure reviews cover both code and content, including UI copy, documentation, prompts, and configuration. The naming variant uses the same scope and also reviews naming. Every review prompt explicitly requires a read-only investigation: report recommendations, leave files and HEAD unchanged, and wait for the separate fix follow-up before applying edits. Uncommitted changes during review block the loop with an explanation before any fix prompt or push is sent.

The driver appends a Markdown contract for the final response to each prompt; it does not restrict investigation or progress updates. Reviews show a
summary and a separate explanation and file link for each finding. Bugs and
performance findings also have priority headings. The report instructions explicitly list the allowed priorities. Dashboard retains the complete report for inspection but excludes lower-priority findings from fixes; a mixed-priority report does not block the loop.
`ReviewReportContract` reads the explicit status and finding count, rejecting missing
sections or count mismatches instead of inferring success from prose. If no qualifying issues are found, the loop
stops without sending a fix request. Otherwise the same chat receives
**Fix the finding and commit**, **Fix both findings and commit**, or **Fix all findings and commit**,
according to the number of qualifying findings, followed by instructions to verify each
finding and mark invalid ones as withdrawn. When a review also contains excluded priorities, the fix prompt lists only qualifying findings, with their original review numbers and titles; descriptions remain in the preceding review. When every finding qualifies, the short fix prompt needs no list. Withdrawn numbers must refer to those qualifying findings. With live testing off, the workflow does not request
tests or require a test result. A Markdown fix report identifies the addressed
fixed count, withdrawn finding numbers, and commit. A fully withdrawn
review ends without a commit; a partial withdrawal continues after the fix commit.
No JSON output schema is sent to Codex.
Dashboard independently verifies a clean working tree, unchanged branch,
matching HEAD, and ancestry from the round's starting commit before scheduling
the next fresh review. The optional **Remote push** setting defaults to **Keep commits local**.
When enabled, Dashboard pushes the verified fix commit after each round to the configured
upstream branch, or to the current branch on `origin` (or the sole remote) when no upstream
is configured. New branch pushes record an upstream. Pushes are never forced; a failure
blocks the loop, and Resume retries the existing verified fix without another fix prompt.
A restart during a push also reconciles and retries that same commit.
Reaching the round limit ends the loop with a distinct
green **Limit reached** status indicating that all configured rounds finished successfully.
The absence of reported findings is the reviewer's assessment, not proof that
all bugs have been eliminated.

`Reviews/ReviewLoopCoordinator` owns the state machine with separate review acceptance,
fix submission, and round completion stages. `ReviewPrompts` defines the execution
prompts shared with previews, `ReviewLoopPresentation` builds status and prompt
previews, and `ReviewLoopFileStore` persists state.
`ReviewLoopDriver` uses the desktop renderer's existing local app-server connection;
`ReviewRepositoryCheckpoint` verifies Git state through argument-based subprocess
calls. The driver uses the saved review selection for review turns and the fix
selection for fix turns, and
does not override permission settings. The bridge polls through the native
renderer synchronization loop and reads bounded turn/item pages. The renderer
page queues controls and its view module renders snapshots; it does not own execution.

State is atomically persisted to `~/Library/Application Support/Codex Dashboard/review-loop.json`.
Intent is saved before each task or follow-up launch. Unknown launches are never
resent automatically. Relaunching Dashboard pauses unfinished loops; Resume
reconciles known tasks first for paused loops. Blocked loops remain active and offer Resume and Stop. A loop previously blocked by mixed-priority findings can resume directly without a replacement report. Open the review chat and answer its question or resolve its blocker, then Resume. Resume inspects the existing chat, including user follow-up turns, and accepts its latest final report only after the usual finding counts, clean checkout, original branch, and commit ancestry checks. Codex handles edits and commits; users do not need to create evidence files or commits. Follow-ups remain in the same round and do not use extra rounds. Unknown chat launches are never duplicated. A blocker before any round launches retries checkout verification. Responses from older JSON-format turns are not
converted; start a new loop if an unfinished old turn returns that format. Malformed reports, failed/interrupted turns, approval
requests, dirty checkouts, or unexpected changes stop progression with an
explanation. Pause lets the current review/fix round finish. Stop prevents new
work and interrupts the latest running turn in the loop’s review or fix chat. A stop
during prompt submission also interrupts the turn once its launch is acknowledged.
Interruption failures remain visible on the stopped loop. Keep both Codex and Dashboard
running. Avoid other edits in the
selected checkout while a loop is active. The desktop bridge is unofficial and
may require maintenance after Codex updates.
