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
retain their no-interaction policy. Existing Keychain items and their UUIDs stay
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

`chat-overview-list-view.js` renders chat rows and project groups, including Git
cards and actions.
`dashboard-bridge.js` wires feature controllers to `createDashboardLifecycle` and
catalog lookups. `dashboard-navigation.js` switches pages; feature controllers own
their mounting and teardown. `todo-list-view.js` owns filter markup; `todo-query.js` selects matching items,
`todo-form-controller.js` binds creation events and maintains draft project/chat selection.
`todo-preset-reader.js` reads model settings for new and existing to-dos.
`usage-reset-notice.js` owns the usage notice, countdown, dragging, collapse state,
and timer/resize cleanup; `account-popover.js` supplies usage snapshots.
Image and tag presentation live in `todo-image-view.js` and `todo-tag-view.js`;
`todo-dialog-host.js` mounts their shared overlay host.
The to-do composer layout lives in CSS with a `has-image` class for the image draft.
`codex-ui-contracts.js` owns speech detection and shares React fiber lookup and
ancestor traversal while keeping committed-fiber resolution explicit for read-state inspection.

See [architecture](architecture.md) for refresh, persistence,
account transactions, notifications, and review execution. Keep implementation explanations there rather than duplicating them in the module
map. User-facing instructions belong in [Using Codex Dashboard](usage.md).

## Renderer contracts

Internal Codex data uses `Thread`; UI copy uses **chat** and **to-do**. Chat overview
operations, including the renderer’s `openChatOverview` entry point, use
`ChatOverview` names so they do not imply control of every dashboard page.
`RendererThread` exposes `projectID` for saved-project identity,
`checkoutPath` for the original directory,
`projectGroupPath` for grouping and Git checks, and `projectGitStatus` for
uncommitted changes and unpushed commits. Preview fixtures include the same fields.

Sidebar entries mount after the outer New chat action row, outside Quick chat and
its tooltip trigger; the icon rail is excluded. Mounting and repairs share one
operation. Native macOS context-menu integration preserves Codex callbacks and
submenus; previews exercise the DOM menu path.

Composer transfers wait for the destination composer's identity, recheck project
membership, and cancel when navigation changes. Prompt placeholders preserve
literal selection and clipboard text, including dollar signs. Current presets
use `low` for reasoning effort, displayed as **Low** in all three features.
To-do views receive project choices from their controller; removed assigned
projects remain visible as unavailable.
Account popover snapshots carry labelled usage rows and separate status notes;
the renderer does not parse formatted strings.
They also carry the active account's exhausted windows with Unix reset timestamps
in milliseconds, independently of saved accounts. The persistent usage notice
counts down to the latest blocking reset and retains the exhausted state until
fresh usage confirms recovery.
`review-presentation.js` supplies shared labels independently of setup rendering.
Reasoning order and labels come from the shared composer preset schema and
presentation helpers. Chat rows and review model cards resolve display names and
fall back to identifiers when no display name is known. Navigation counts describe running or waiting loops.

`ReviewPageSnapshot` supplies the review page through `applyReviewPageSnapshot`;
`ReviewLoopsDocument` defines the current saved document independently of migrations.
Review display snapshots add the computed `completedRoundCount`; saved documents
retain round data without duplicating that count. Required runtime and DevTools
operations have explicit implementations; test doubles supply their own stubs.
The DevTools convenience overload uses a four-second timeout.

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
`hiddenChangeIndicatorPaths`, and the `recent`/`home` filters to `all` (**All chats**).

Review-loop version 10 renames `focus` to `reviewType` when loading earlier saved
loops, preserving their settings and round history. Current actions, snapshots,
and saved documents use only `reviewType`.

Version 9 adds `muteMedia`, defaulting existing loops to off while preserving all other version 8 fields. Review and fix prompts scope muting to playback started by the agent, including autoplay in its test tabs, and explicitly preserve existing user playback and mute/volume settings. They prohibit browser-wide or system muting. These instructions are included when live testing and this preference are enabled. Active cards save changes through `setMuteMedia` for the next prompt.

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

Review tests are split into coordinator, bridge, presentation, prompts, migration,
and file-store suites, with doubles in `Reviews/ReviewLoopTestSupport.swift`.
Thread fixtures live in `Threads/ThreadSummaryFixtures.swift`.

Run `swift test` for the complete native and WebKit suite. Web tests await to-do
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
