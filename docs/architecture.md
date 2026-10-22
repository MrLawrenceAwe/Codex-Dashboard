# Architecture

For controls and operational guidance, see [Using Codex Dashboard](usage.md).
For source ownership, build instructions, and migrations, see [Development](development.md).

## Runtime and integration

The native Swift menu-bar application coordinates local thread data, accounts,
compatibility checks, and renderer synchronization. `CodexDashboardRuntime`
manages Codex's process and `DashboardRenderer` maintains the injected resources
through a loopback-only Chromium DevTools connection. Single-instance arbitration
prevents older controllers from overwriting the active dashboard. Codex's signed
application bundle is not modified.

The injection manifest defines runtime resources and the renderer compatibility
contract bundle. Swift supplies the prompt-library and shared composer-preset schemas;
the injection version hashes the assembled payload. The renderer bridge connects
snapshots to feature controllers and restores pages after host reloads. Feature
controllers own mounting and teardown.

Subprocess deadlines include termination and complete stdout/stderr draining.
The shared `AsyncPipeReader` closes on timeout or cancellation even if descendants
retain pipe write ends; account app-server reads use it as well.

`FileSignature` shares size/modification-time reads across catalog, unread-state,
and filesystem monitoring. `JWTClaimsDecoder.decodeUnverifiedClaims` shares token
payload decoding for account and unread identity lookup; it does not verify signatures.

## Thread snapshots

`CodexThreadCatalogProvider` reads `state_5.sqlite` and orders chats by indexed
recency. The recent-history limit is 500; required unread chats and currently active
chats can extend that catalog. `RolloutActivityReader` reads explicit lifecycle
events and reconciles them against the current Codex launch so interrupted work
does not stay running indefinitely. `RolloutQuestionReader` observes structured async
question items and blocking question calls, with replies and interruptions clearing
the previous question. Both readers share a cached reverse JSONL scanner.
`ThreadQuestionTracker` consumes each newly observed question once; initial
snapshots establish a baseline without opening historical questions.

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
`ProjectGitChangeMonitor` owns project and Git metadata watches, with recursive
project events from `RecursiveProjectChangeMonitor`. Debounce policies remain
separate. `isFileChangeMonitoringConfigured` describes monitor configuration, not
whether individual filesystem watches successfully started. Git metadata watches
follow linked-worktree pointers. Codex activation
refreshes unread state and the catalog. With file monitoring configured, Git status
uses filesystem events and periodic polling; activation does not request another
Git scan. Without monitoring configured, activation requests a cache-aware Git
status update. Newly discovered projects receive their own initial Git refresh.
`refreshThreadState` applies the latest snapshot and observes completions and
questions; normal synchronization explicitly calls `handleThreadActivity` for
usage refresh and automatic chat opening. Questions and completions can navigate
to their chat even when Codex is already frontmost. Recent typing, dictation, or
voice chat suppress activation and navigation; suppressed events are consumed
without replay. Restart and account-switch preflights consume the snapshot
without those actions.

`RefreshScheduler.Schedule` defines waits after each operation completes:

| Refresh | Active | Background |
| --- | --- | --- |
| Thread catalog | 2 seconds | 8 seconds |
| Unread state, file monitoring configured | 15 seconds | 60 seconds |
| Unread state, file monitoring disabled | 500 milliseconds | 1 second |
| Git status fallback | 15 seconds | 60 seconds |
| Active-account usage | 2 minutes | Skipped |
| Inactive-account usage | 5 minutes | 5 minutes |

Renderer unread reconciliation runs 1.5 seconds after a native snapshot, then every
3 seconds with Chat overview open, 10 seconds closed, or 30 seconds hidden.

## Persistence

Prompt-library edits use durable pending changes in renderer storage. Each edit
captures a base and desired document. `PromptLibraryBridge` supplies the current
native library to each renderer. `prompt-store.js` merges the pending edits against
that document; the bridge persists the merged result and acknowledges the queued
changes. Native storage is
`~/Library/Application Support/Codex Dashboard/prompt-library.json` with
rolling backups. Concurrent prompt/section deletions beat stale edits; new or moved
prompts targeting a concurrently deleted section move to General.

To-dos live in renderer storage, with image data in IndexedDB and an inline fallback.
`todoStore.create` accepts a complete draft object and normalises text, image, tags,
project, linked thread, and model preset before the controller queues persistence.
Writes merge changed fields into the latest shared document, preserving other
windows' edits and image references. Image saves check immutable attachment keys in
IndexedDB and write only missing keys, restoring pruned data when it is still in memory
without rewriting existing image payloads for text edits. Concurrent deletion beats stale edits;
storage notifications refresh open windows. Text saves update existing rows so click targets
and keyboard focus survive the save. Draft protection prevents replacement of an
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

Account-menu requests have unique IDs and remain in the renderer until native
handling explicitly completes them. Polling reads without consuming; native receipt
is recorded before acknowledging the UI. Completed results are retained for the
latest 64 requests so a lost completion response can be redelivered without repeating
an account change. Unacknowledged requests expire after 15 seconds and allow retry.

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

Deadline alerts use `UsageDeadlineNotificationID` for account/kind grouping,
lead times, revised-deadline keys, and refreshed-delivery keys. The planner and desktop
cleanup share that contract. Existing identifier strings remain unchanged because
saved delivery history uses them to prevent duplicate alerts.

`UsageNotificationPlanner` builds one pure plan per observation time.
`UsageNotificationUpdateCoordinator` serializes updates. `DesktopUsageNotifier` and
`NtfyUsageNotifier` deliver through separate channels and maintain independent
`UsageNotificationHistory` records. Delivery on one channel never acknowledges the
other. Durable keys remain stable to avoid duplicate alerts or lost phone settings.
`NotificationUsageRefresher` coalesces deadline refresh requests with short reuse.
The desktop channel schedules a labelled stale-data fallback; phone delivery retries
failed refreshes. Alert schedules and suppression rules are in the [usage guide](usage.md#usage-alerts).
Immediate delivery history retains 30 days plus current observed windows and alerts
still eligible for retry. Planning precedes pruning so stale retries remain deduplicated.
Removed-account observations and deadline histories are pruned; a missing usage
snapshot for a saved account retains its last observation.

## Review execution

`ReviewLoopCoordinator` owns the state machine, separating review acceptance, fix
submission, and round completion. `ReviewPrompts` supplies execution prompts;
`ReviewReportContract` supplies and parses final Markdown contracts. It validates
explicit status, finding sections, addressed/withdrawn findings, and commits rather than
inferring success from prose. Review totals are derived from the parsed finding sections;
the review response does not include a separate total. Malformed reports explain the
format correction needed before resuming. Investigation and progress messages remain unrestricted.
`ReviewLoopPresentation` builds progress and configured prompt previews from current
settings. These previews are not records of submitted turns. The renderer submits actions
and displays snapshots without owning execution. Review inspection, remote publication,
choice loading, and stop requests run outside snapshot synchronization, so slow work
does not hold up chat updates or control receipt. Restart, disable, and account-change
preflights drain those operations before checking active chats or tearing down the renderer.
Unchanged review controls and round details retain their DOM elements and keyboard focus.

`ReviewLoopDriver` uses the renderer's local app-server connection and reads bounded
turn/item pages. It loads reports for the first and latest turns and the saved checkpoint
turn IDs, retaining the original fix report during subsequent verification. Review and
fix turns use their separate saved model selections;
permission settings are not overridden. Priority filtering preserves the complete
report but submits only qualifying findings with original numbers when necessary.
Live testing adds instructions only when enabled; otherwise no test result is required
by the loop contract. Exact prompt wording lives in `ReviewPrompts`, not duplicated here.

`ReviewWorkspaceCheckpoint` detects Git working trees and ordinary folders. Folder
state uses a SHA-256 fingerprint of content, paths, permissions, and symlink targets;
`ReviewFolderCheckpoint` reads the tree twice off the main actor and rejects unstable
snapshots. Read-only reviews must preserve this revision. Folder fix reports use
`# Fixes applied` without a commit. The fix task performs verification; the
coordinator validates finding accounting and requires a changed fingerprint for
applied fixes or an unchanged fingerprint when all findings are withdrawn. It
records the current fingerprint as `verifiedRevision` without submitting a separate
verification turn. The fingerprint identifies file state, not fix correctness.
Folder mode never initialises Git or publishes. Reservations reject overlapping
parent/child folders as well as identical roots.

For Git projects, `ReviewWorkspaceCheckpoint` validates Git state through argument-based subprocesses.
A review must leave a clean checkout and unchanged HEAD. Fix completion requires the
original branch, clean tree, a reported commit matching HEAD, and ancestry from the
round's base commit. `ReviewGitPublisher.reconcileAndPublishFix` fetches the
destination and returns either `published` or `verificationRequired` with the merged
checkout. Remote reconciliation can
create a local merge commit; publication waits for read-only verification of that
HEAD. The verification's `targetRevision` identifies this HEAD independently of the
original fix commit. Results record an optional `fixCommit` only for committed fixes;
`verifiedRevision` records the checked file state, including clean and withdrawn
rounds. Publication never forces a push.
Retries and restart reconciliation reuse the same fix rather than requesting another.

`ReviewLoopFileStore` atomically persists
`~/Library/Application Support/Codex Dashboard/review-loop.json`. Launch intent is
saved before each task/follow-up; unknown launches are never automatically resent.
Restart pauses running and waiting loops; stopping loops retain their workspace
reservation and retry interruption. Resume reconciles known tasks, including user
follow-up turns, under the same validation. An explicit Resume sends one continuation
when the latest known turn failed or was interrupted. Reviews require unchanged HEAD
and a clean tree; fix continuations preserve unfinished changes on the original branch.
Running turns and completed reports are reconciled without new prompts.
Interrupted and extension-reload continuations share one submission sequence that
persists intent before submission and records the acknowledged turn ID afterward;
each path retains its own preflight checks. Continuations
do not consume another round, and polling never retries a failed submission.
Stop also handles turns whose submission acknowledgment arrives after cancellation.
A stopping loop keeps its workspace reserved until submission finishes and the latest
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
