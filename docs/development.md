# Development and testing

## Build toolchain

GitHub Actions selects Xcode 26.6 explicitly on macOS 26 and runs the test suite
followed by a release build. The WebKit tests require Safari 26.4 or newer's
CSS zoom coordinate behavior; older WebKit versions report unscaled rectangles.
Use Xcode 26.6 for development; the application's deployment target remains macOS 14.

## Local signing

`install.sh` resolves its signing certificate through `Packaging/signing-identity.sh`.
The first local install creates a dedicated self-signed certificate in the login
Keychain, trusted for code signing. Later installs reuse that certificate; they do
not fall back to ad-hoc signing. Set `SIGNING_IDENTITY` to use an existing certificate.
When the login keychain password is unavailable, run
`python3 Packaging/signing-keychain.py --create` once. This creates an isolated
`codex-dashboard-build.keychain-db` with a generated password kept under
`~/Library/Application Support/Codex Dashboard/build-signing/` with private file
permissions. Later installs unlock and reuse it automatically. The password is
passed to `security` on stdin and never included in process arguments or build logs.
Only Apple signing tools are authorized to use its non-extractable signing key.
The user's default keychain is retained. The signing keychain is added to the
search list only for each signing command; the previous list is restored afterward.

Set `SIGNING_KEYCHAIN` to select another build-signing keychain. It must already
be unlocked; the installer searches and signs explicitly with that keychain.
This supports builds when the login keychain password is unavailable, without
resetting the login keychain. A new signing certificate can require saved-account
access to be approved again; existing credentials remain in their original keychain.
An invalid existing local identity fails installation so an unexpected certificate
replacement cannot silently change the app’s designated signing requirement. The certificate
and non-extractable private key stay in Keychain; temporary key files are removed.
This is a local development identity, not a Developer ID distribution identity.
Its stable designated requirement does not imply a stable Keychain partition:
macOS uses `cdhash:` for self-signed apps and an Apple-verified `teamid:` for
Apple development/Developer ID apps. Changed resources alter the code hash, so
self-signed rebuilds can still prompt. An unchanged rebuild is not a valid test
of approval persistence across code or resource changes.

`DashboardKeychainProtocol` defines shared Codable request/response messages and typed operations.
`CodexDashboardKeychainHelper` owns all saved-account Keychain operations. Its
native vault lives in the independent `DashboardKeychain` target so dashboard code
and resource changes do not change its executable. The installer signs the helper
individually, then signs the containing app without recursively re-signing it.
The helper checks the calling process's Dashboard identifier and certificate against
its own certificate before accepting a single JSON request on stdin. Credential
bytes travel over pipes, never argv or environment variables. Background calls
retain their no-interaction policy: the single-request helper disables traditional
Keychain Services UI, and queries fail instead of prompting or skipping protected
items. Existing Keychain items and their UUIDs stay
in place; previous protected items retain their recovery path to avoid data loss.
Helper or toolchain changes can change its code hash and require reauthorization.

After `swift build -c release`, run `python3 Packaging/verify-keychain-helper.py`
to exercise a disposable item under a fixed probe service. The test changes the
calling app's resources, verifies its code hash changed while the helper's did not,
then reads and writes without interaction. It also rejects an unsigned caller
and removes its disposable item. It never accesses saved-account credentials.

## Preview

Run `./DashboardPreview/generate.sh`, then open `DashboardPreview/index.html` in a
browser. Regenerate after changing renderer resources or the prompt schema. The
ignored `injection.js` is built by the production `InjectionBundle` loader, including
the Swift-defined prompt schema; preview fixtures use the current thread contract.
Generation exits before starting the menu-bar application.

## Code organisation

Swift source and tests mirror the application, account, compatibility, composer,
prompt, review, runtime, and thread boundaries. Filesystem watchers and activity
monitors live in `App/Monitoring`; diagnostics views live in `App/Diagnostics`.
`DesktopNotificationCenter.swift` owns the macOS notification adapter and its
protocol; `DesktopUsageNotifier.swift` owns usage-alert scheduling and delivery.
`Support/FileSystemPath.swift` defines canonical path identity for catalog grouping,
review checkout checks, file links, and monitoring. Project event matching separately
retains lexical standardisation so it does not resolve symlinks for each event.

Renderer resources are listed in `injection-manifest.json`:

| Folder | Responsibility |
| --- | --- |
| `Core` | Injection, host contracts, lifecycle, navigation, visibility, and shared DOM helpers |
| `Accounts` | Account popover presentation, actions, and usage-reset notice |
| `Composer` | Text/image insertion, model selection, and shared preset validation, labels, and form fields |
| `Threads` | Chat overview, thread indexing, unread reconciliation, and completion indicators |
| `Todos` | To-do storage, list rendering, creation drafts, tags, images, and composer transfer |
| `Sidebar` | Project highlights, interruption indicators, and chat context-menu to-do actions |
| `Prompts` | Prompt storage, contracts, dialogs, rendering, and reordering |
| `Reviews` | Review page controls, setup, cards, history, and app-server requests |

Shared page title sizes, corner radii, control height, focus color, and default top spacing live in
`Core/dashboard-theme.css`, loaded before feature styles. Injected surfaces inherit
the host font. Derive fallback surface and secondary text colors from the host
foreground and background so both light and dark themes remain legible. Prefer unboxed list rows and muted section headings; reserve borders
for inputs, dialogs, and meaningful separators. Keep unread emphasis to the dot and
title weight, with actions visible on hover and keyboard focus.

Feature controllers own mounting and teardown; views own markup and presentation.
See [architecture](architecture.md) for refresh, persistence, account transactions,
notifications and review execution, and [usage](usage.md) for user controls.
`ReviewWorkspaceCheckpoint` inspects Git checkouts and ordinary folders through
`workspace(at:)`, returning `ReviewWorkspaceState`. Its optional `git` metadata
holds the branch and clean-tree state; ordinary folders have no Git metadata.
`ReviewFolderCheckpoint` owns
folder fingerprints. `ReviewWorkspaceChecking` exposes read-only workspace and
ancestry inspection; `ReviewGitPublishing` and `ReviewGitPublisher` own remote fetch,
merge/abort, push, and upstream configuration. `ReviewLoopDriver` receives these as
separate dependencies. Both implementations use `ReviewGitCommand` for subprocesses.
`ReviewFixCheckpoint` validates finding accounting and commit ancestry; the review
coordinator owns publication intent, verification scheduling, and final state writes.

## Renderer contracts

Internal Codex data uses `Thread`; UI copy uses **chat** and **to-do**. Chat overview
operations, including the renderer’s `openChatOverview` entry point, use
`ChatOverview` names so they do not imply control of every dashboard page.
`RendererThread` exposes `projectID` for saved-project identity,
`checkoutPath` for the original directory,
`projectGroupPath` for grouping and Git checks, and `projectGitStatus` for
uncommitted changes and unpushed commits. `sharesProjectRepository` describes
repository membership; Git action readiness also requires an idle chat.
Preview fixtures include the same fields.

Sidebar entries mount after the outer New chat action row, outside Quick chat and
its tooltip trigger; the icon rail is excluded. Mounting and repairs share one
operation. Native macOS context-menu integration preserves Codex callbacks and
submenus; previews exercise the DOM menu path.

Composer transfer, prompt placeholders and preset defaults are described in
[architecture](architecture.md#persistence) and [usage](usage.md). Renderer popovers
receive structured usage rows and Unix reset timestamps in milliseconds; no
formatted text is parsed. To-do controllers supply project choices, retaining
removed assignments as unavailable.
The `restartForSignIn` action uses `prepareForSignIn` to prepare a signed-out
state for either a new account or reauthentication. Accounts are saved separately
through `saveCurrentAccount`.
`codex-ui-contracts.js` owns sidebar project-row selectors, metadata access, and
observed attributes; project highlights and to-do monitoring consume that contract.
Its `sidebarThreads` contract owns thread selectors, local ID decoding, title lookup,
and mutation detection for lifecycle repair, to-do actions, and usage-limit indicators.
`review-loop-setup-view.js` owns setup markup, rendering, and settings extraction;
`review-loop-page.js` validates submissions and queues actions.
`review-presentation.js` supplies shared labels independently of setup rendering.
Reasoning order and labels come from the shared composer preset schema and
presentation helpers. Chat rows and review model cards resolve display names and
fall back to identifiers when no display name is known. Navigation counts describe running or waiting loops.

`ReviewPageSnapshot` supplies the review page through `applyReviewPageSnapshot`;
`ReviewLoopsDocument` defines the current saved document independently of migrations.
Review display snapshots add the computed `completedRoundCount` and `isFinished`
fields to each loop; saved documents retain round and phase data without duplicating
those derived values. Required runtime and DevTools
operations have explicit implementations; test doubles supply their own stubs.
The DevTools convenience overload uses a four-second timeout.
The **Open completed chats automatically** preference retains its original
`foregroundOnTaskCompletion` storage key to preserve saved choices.

## Review-loop extension testing

With **Reload browser extension** enabled, Codex reloads the extension before live
testing and, when live verification is needed, again after building fixes. In the
everyday Chrome profile, it uses Chrome Computer Use on `chrome://extensions` and
the extension card’s **Reload** button. DevTools installation and reload tools are
reserved for explicitly temporary test profiles, where removal on restart is intended.

The agent identifies the installed extension ID and source folder before reloading,
then verifies the same ID and enabled state, refreshes affected test pages, and
reopens extension UI as needed. Persistent installations must not have the
`INSTALLED_VIA_CDP` creation flag (bit 32768). Restoring a missing registration
requires backing up its registration and storage, retaining its original folder/key,
and using **Load unpacked**. Live Chrome preferences are not edited, and Chrome is
not restarted solely to test persistence.

The globally configured `chrome-devtools` MCP server is used for read-only inventory
and debugging that requires DevTools. Chrome may ask you to approve its connection.
When debugging finishes, including on failure or cancellation, the agent disconnects
its own session, verifies its debugging socket closed, and checks that the automation
banner disappears when no other sessions remain. It leaves Chrome and your tabs open.
If safe disconnection is unavailable, it explains the remaining connection and how
to disconnect it.

If a required reload cannot be completed, the loop waits for a manual reload and
shows the reason and steps. Unavailable MCP tools are reported with any required
chat reconnect/restart or Chrome connection approval. The chat reports
`# Extension reload required` with a `## Summary` containing the browser, extension,
steps, and reason; Dashboard shows **Waiting for extension reload**. Select
**Extension reloaded — continue** after reloading to resume the same chat and round,
preserving unfinished fixes. Final review and commit checks still run before the
round can complete.

## Storage migrations

`PromptLibraryMigration` upgrades native version 3 presets from `light` to `low`
when loading or importing a native document. Native migration creates a backup
before rewriting. Renderer cached libraries and durable pending edits are migrated before
validation and merging, so queued edits survive an upgrade.

To-do version 9 makes the same preset conversion for versions 1–8. Version 8 added
presets; version 7 added `project` and `thread`. Older readers convert `projectTag`,
`projectBadge`, and the version 6 `chat` field. Failed migration writes leave the
stored document intact. Preference loading converts `collapsedProjects` to
`collapsedProjectPaths`, former ignored/muted paths to
`hiddenChangeIndicatorPaths`, and the `recent`/`home` filters to `all` (**Recent and running**).

Review-loop version 16 renames `checkoutRoot` to `workspaceRoot` for Git and ordinary-folder
loops. Migration preserves the root and reservation alongside all saved settings and
round history; current documents write only `workspaceRoot`.

Review-loop version 15 separates optional `fixCommit` from `verifiedRevision`.
Only committed fixes have a `fixCommit`; clean, withdrawn, and folder rounds do not.
Migration preserves old fix commits and unchanged HEAD revisions from the former
`commit` field, retaining any separately verified revision already recorded.

Review-loop version 14 adds ordinary-folder checkpoints and persists the workspace
kind once selected. Shared checkpoint fields use `baseRevision`, `expectedRevision`,
`targetRevision`, and `verifiedRevision`; Git fix IDs remain separate from these
checkpoint revisions. Migration renames earlier checkpoint fields and marks previously
started loops as Git loops, preserving their history and pending verification.
Previously unstarted loops retain automatic mode detection so paused non-Git projects
can resume. Fingerprints are change identities, not stored copies of project files.

Review-loop version 13 separates the names of two existing continuation states:
`allowsFollowUpTurns` permits reconciliation of additional chat turns, while
`extensionReloadContinuationPending` records a confirmed reload awaiting continuation
submission. Migration maps the former `continuationRequested` and
`reloadContinuationRequested` fields without losing pending requests or round history.
Old names are confined to the migration boundary and legacy fixtures.

Review-loop version 12 renames the saved verification target from `commit` to
`targetCommit`, preserving pending verification and round history. Version 14 moves
this checkpoint to `targetRevision`. Version 15 renames the original Git fix's
result field to `fixCommit`.

Review-loop version 11 renames `muteMedia` to `muteTestPlayback` at the storage
boundary, preserving saved preferences and round history. Current actions, snapshots,
and saved documents use `muteTestPlayback` and `setMuteTestPlayback`.

Review-loop version 10 renames `focus` to `reviewType` when loading earlier saved
loops, preserving their settings and round history. Current actions, snapshots,
and saved documents use only `reviewType`.

Version 9 introduced the playback preference as `muteMedia`, defaulting existing
loops to off while preserving other version 8 fields. See the
[usage guide](usage.md#review-loops) for playback scope and controls.

Version 8 adds the durable `stopping` phase so checkout reservations
survive interruption failures and restarts. Version 7 renames `isExtension` to `reloadExtensionBeforeTesting`, preserving the saved reload preference.
Version 6 renames saved round-result `findings` to
`addressedFindingCount`, preserving existing history at the migration boundary.
Version 3 renames the `naming` review type to `organisationAndNaming`.
Version 1 and older unversioned single-loop/array documents also migrate remote
push, prompt context, and model selection fields at the file-store boundary.
The coordinator writes the current version after a successful load.

Confine old identifiers to migration boundaries and legacy fixtures. Retain
readers while supported installs may still contain personal data in those formats;
establish a safe migration cutoff before removing them. Existing view-preference
storage keys remain unchanged to preserve saved filters and collapsed projects.

## Testing

Review tests are split into coordinator, driver, workspace checkpoint, folder checkpoint,
bridge, presentation, prompts, migration, and file-store suites, with doubles in
`Reviews/ReviewLoopTestSupport.swift`. Driver tests cover app-server requests and
response decoding, including the shared `ReviewTurnStatus` enum; checkpoint tests
cover filesystem and Git inspection, and prompt and migration tests stay in their
respective suites.
Thread fixtures live in `Threads/ThreadSummaryFixtures.swift`.

Run `swift test` for the complete native and WebKit suite. For renderer presentation
and composer-transfer checks without a browser or UI, run
`node --test Tests/Renderer/*.test.cjs`. Web tests await to-do
save completion; they do not assume persistence finishes during a DOM event.
Persistence instrumentation requires each source anchor to match exactly once
and fails on missing or duplicate anchors. Save waiters are required calls.

## Visual baselines

The web suite compares wide dark, medium light, and narrow dark screenshots with
committed baselines. Snapshots use two pixels per point so Retina and headless CI
displays produce the same dimensions.

After an intentional visual change, regenerate and inspect them with:

```sh
UPDATE_VISUAL_BASELINES=1 swift test --filter DashboardVisualRegressionTests
```
