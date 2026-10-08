# Architecture

For controls and operational guidance, see [Using Codex Dashboard](usage.md).
For source ownership, build instructions, and migrations, see [Development](development.md).

## Runtime and integration

The native Swift menu-bar application coordinates local thread data, accounts,
compatibility checks, and renderer synchronization. `LocalCodexDashboardRuntime`
manages Codex's process and `DashboardRenderer` maintains the injected resources
through a loopback-only Chromium DevTools connection. Single-instance arbitration
prevents older controllers from overwriting the active dashboard. Codex's signed
application bundle is not modified.

The injection manifest defines runtime resources and compatibility contract bundles.
Swift supplies the prompt-library contract and shared composer-preset schema;
the injection version hashes the assembled payload. The renderer bridge connects
snapshots to feature controllers and restores pages after host reloads. Feature
controllers own mounting and teardown.

Subprocess deadlines include termination and complete stdout/stderr draining.
The shared `AsyncPipeReader` closes on timeout or cancellation even if descendants
retain pipe write ends; account app-server reads use it as well.

## Thread snapshots

`CodexThreadCatalogProvider` reads `state_5.sqlite` and orders chats by indexed
recency. The recent-history limit is 500; required unread chats and currently active
chats can extend that catalog. `RolloutActivityReader` reads explicit lifecycle
events and reconciles them against the current Codex launch so interrupted work
does not stay running indefinitely.

Project grouping uses saved projects and canonical roots, including symlink aliases.
Removed projects lose change indicators; their chats retain their original checkout
paths under Other chats. Worktree chats retain appropriate checkout grouping.
`ThreadSnapshotService` applies cached Git status and unread state to the catalog.
Git checks use local upstream refs, or all remote refs without an upstream, and
never fetch. Optional Git locks are disabled to avoid observation generating events.
Overlapping periodic Git reads share one scan per project. File events during a
scan request one subsequent scan, coalescing bursts without dropping the final change.

Unread state is scoped to the active authenticated principal, independently of
saved accounts. Account changes invalidate its cache even if global state is
unchanged. Newly unread chats outside the loaded catalog cause an immediate refresh.
On activation, unread state refreshes before the catalog. Opening Chat overview
also reconciles mounted local sidebar rows. Unchanged sidebar values cannot
repeatedly override newer persisted state; live changes survive persistence lag
until acknowledged or superseded by activity. Opening a chat does not optimistically
mark it read: Codex remains the source of truth.

## Refresh and monitoring

`CodexDataChangeMonitor` watches catalog, unread, and account files.
`WorkingTreeChangeMonitor` owns project and Git metadata watches, with recursive
project events from `RecursiveProjectChangeMonitor`. Debounce policies remain
separate. Git metadata watches follow linked-worktree pointers. Codex activation
forces a Git refresh; filesystem events and user actions accelerate polling.

`RefreshScheduler.Schedule` defines waits after each operation completes:

| Refresh | Active | Background |
| --- | --- | --- |
| Thread catalog | 2 seconds | 8 seconds |
| Unread state, with file monitoring | 15 seconds | 60 seconds |
| Unread state, without file monitoring | 500 milliseconds | 1 second |
| Git status fallback | 15 seconds | 60 seconds |
| Active-account usage | 2 minutes | Skipped |
| Inactive-account usage | 5 minutes | 5 minutes |

Renderer unread reconciliation runs 1.5 seconds after a native snapshot, then every
3 seconds with Chat overview open, 10 seconds closed, or 30 seconds hidden.

## Persistence

Prompt-library edits use durable pending changes in renderer storage. Each edit
captures a base and desired document. `PromptLibraryBridge` combines these with the
current native library, persists it, then acknowledges the queued changes. Native
storage is `~/Library/Application Support/Codex Dashboard/prompt-library.json` with
rolling backups. Concurrent prompt/section deletions beat stale edits; new or moved
prompts targeting a concurrently deleted section move to General.

To-dos live in renderer storage, with image data in IndexedDB and an inline fallback.
Writes merge changed fields into the latest shared document, preserving other
windows' edits and image references. Concurrent deletion beats stale edits; storage
notifications refresh open windows. Draft protection prevents replacement of an
actively edited field before its change is committed. View preferences and project
highlights persist separately.

## Accounts and credentials

`CodexAccountManager` handles account transactions through isolated credential-file,
identity-decoding, document-store, and vault components. The non-secret saved list
is `~/Library/Application Support/Codex Dashboard/accounts.json`; credential blobs
stay in macOS Keychain. `CodexDashboardKeychainHelper` verifies the Dashboard caller
and accesses them over pipes. `DashboardKeychainProtocol` shares typed messages;
`DashboardKeychain` contains the native vault independently of Dashboard UI builds.
See [local signing](development.md#local-signing) for approval persistence.

Metadata loading, reconciliation, migrations, and Keychain transactions run on a
serial worker. Menus use the last published account snapshot. Unidentified active
credentials clear the saved-account association and cannot overwrite a saved login.
External sign-in changes clear old usage and invalidate its session. Credential-file
changes update only accounts still saved, preventing removed accounts reappearing.

Switching checks fresh running-task state, cancels old usage requests, atomically
updates the active credential, restarts Codex, and rolls back if relaunch fails.
The shared Codex configuration/thread directory stays intact. A preflight snapshot
mounts after relaunch; new usage requests wait for provider cleanup. Active usage
requests coalesce across metadata and usage fetching. Inactive requests use temporary
Codex homes populated from Keychain; refreshed credentials return to the vault and
homes are removed after each request. Batch refreshes preserve interaction policy
and perform one cache write. Non-sensitive usage snapshots persist with timestamps.

## Notifications

`UsageNotificationPlanner` builds one pure plan per observation time.
`UsageNotificationUpdateCoordinator` serializes updates. `DesktopUsageNotifier` and
`NtfyUsageNotifier` deliver through separate channels and maintain independent
`UsageNotificationHistory` records. Delivery on one channel never acknowledges the
other. Durable keys remain stable to avoid duplicate alerts or lost phone settings.
`NotificationUsageRefresher` coalesces deadline refresh requests with short reuse.
The desktop channel schedules a labelled stale-data fallback; phone delivery retries
failed refreshes. Alert schedules and suppression rules are in the [usage guide](usage.md#usage-alerts).

## Review execution

`ReviewLoopCoordinator` owns the state machine, separating review acceptance, fix
submission, and round completion. `ReviewPrompts` supplies execution prompts;
`ReviewReportContract` supplies and parses final Markdown contracts. It validates
explicit status, finding sections, addressed/withdrawn findings, and commits rather than
inferring success from prose. Review totals are derived from the parsed finding sections;
the review response does not include a separate total. Malformed reports explain the
format correction needed before resuming. Investigation and progress messages remain unrestricted.
`ReviewLoopPresentation` builds progress and previews; the renderer submits actions
and displays snapshots without owning execution.

`ReviewLoopDriver` uses the renderer's local app-server connection and reads bounded
turn/item pages. Review and fix turns use their separate saved model selections;
permission settings are not overridden. Priority filtering preserves the complete
report but submits only qualifying findings with original numbers when necessary.
Live testing adds instructions only when enabled; otherwise no test result is required
by the loop contract. Exact prompt wording lives in `ReviewPrompts`, not duplicated here.

`ReviewRepositoryCheckpoint` validates Git state through argument-based subprocesses.
A review must leave a clean checkout and unchanged HEAD. Fix completion requires the
original branch, clean tree, a reported commit matching HEAD, and ancestry from the
round's base commit. Optional remote push uses that verified commit without force.
Retries and restart reconciliation reuse the same fix rather than requesting another.

`ReviewLoopFileStore` atomically persists
`~/Library/Application Support/Codex Dashboard/review-loop.json`. Launch intent is
saved before each task/follow-up; unknown launches are never automatically resent.
Restart pauses running and waiting loops; stopping loops retain their checkout
reservation and retry interruption. Resume reconciles known tasks, including user
follow-up turns, under the same validation. Follow-ups do not consume another round.
Stop also handles turns whose submission acknowledgment arrives after cancellation.
A stopping loop keeps its checkout reserved until submission finishes and the latest
turn is confirmed inactive. Failed interruptions stay visible and are retried; only
confirmed stopped loops can be deleted or replaced.
Storage failures prevent further remote side effects. Operational recovery and
round-limit semantics are in the [usage guide](usage.md#review-loops).

## Compatibility

Local checks inspect storage and lifecycle contracts; renderer checks inspect host,
sidebar, unread, composer, and model-control contracts. Version changes trigger
checks automatically. Blocking drift prevents remounting; warnings and failed check
details propagate to the menu, notification, copied diagnostics, and Diagnostics
window. This integration uses private contracts that may require maintenance after
Codex updates.
