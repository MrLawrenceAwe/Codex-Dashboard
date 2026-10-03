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
| `Accounts` | Account popover presentation and actions |
| `Composer` | Text/image insertion, model selection, and shared preset validation and labels |
| `Threads` | Chat overview, thread indexing, unread reconciliation, and completion indicators |
| `Todos` | To-do storage, list rendering, creation drafts, tags, images, and composer transfer |
| `Sidebar` | Project highlights, interruption indicators, and chat context-menu to-do actions |
| `Prompts` | Prompt storage, contracts, dialogs, rendering, and reordering |
| `Reviews` | Review page controls, setup, cards, history, and app-server requests |

`dashboard-bridge.js` wires feature controllers to `createDashboardLifecycle` and
catalog lookups. `dashboard-navigation.js` switches pages; feature controllers own
their mounting and teardown. `todo-list-view.js` owns filter markup, and the to-do
composer layout lives in CSS with a `has-image` class for the image draft.
`codex-ui-contracts.js` shares React fiber lookup and ancestor traversal while
keeping committed-fiber resolution explicit for read-state inspection.

See [architecture and behaviour](architecture.md) for refresh, persistence,
account transactions, notifications, and review execution. Keep behavioural
explanations there rather than duplicating them in the module map.

## Renderer contracts

Internal Codex data uses `Thread`; UI copy uses **chat** and **to-do**. Chat overview
operations use `ChatOverview` names so they do not imply control of every dashboard
page. `RendererThread` exposes `checkoutPath` for the original directory,
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
Review model cards resolve display names and use saved identifiers only when the
model is no longer available. Navigation counts describe running or waiting loops.

Review display snapshots add the computed `completedRoundCount`; saved documents
retain round data without duplicating that count. Required runtime and DevTools
operations have explicit implementations; test doubles supply their own stubs.
The DevTools convenience overload uses a four-second timeout.

## Storage migrations

Prompt-library version 4 migrates version 3 presets from `light` to `low` when
loading or importing a native document. Native migration creates a backup before
rewriting. Renderer cached libraries and durable pending edits are migrated before
validation and merging, so queued edits survive an upgrade.

To-do version 9 makes the same preset conversion for versions 1–8. Version 8 added
presets; version 7 added `project` and `thread`. Older readers convert `projectTag`,
`projectBadge`, and the version 6 `chat` field. Failed migration writes leave the
stored document intact. Preference loading converts `collapsedProjects` to
`collapsedProjectPaths`, former ignored/muted paths to
`hiddenChangeIndicatorPaths`, and the `recent`/`home` filters to `all` (**All chats**).

Review-loop version 3 renames the `naming` focus to `organisationAndNaming`.
Version 1 and older unversioned single-loop/array documents also migrate remote
push, prompt context, and model selection fields at the file-store boundary.
The coordinator writes the current version after a successful load.

Confine old identifiers to migration boundaries and legacy fixtures. Retain
readers while supported installs may still contain personal data in those formats;
establish a safe migration cutoff before removing them. Existing view-preference
storage keys remain unchanged to preserve saved filters and collapsed projects.

## Testing

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
