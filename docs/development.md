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

Shared page visibility, navigation-button construction, and icons live in `Core`. Sidebar navigation is scoped to the left panel and excludes the app icon rail. Injected entries follow the outer New chat action row, outside its Quick chat controls and tooltip trigger. Initial mounting and renderer repairs share one mounting operation. `Threads/thread-unread-state.js` owns unread reconciliation and polling; `Threads/thread-completion-indicators.js` owns completion tick expiry. `Sidebar/thread-interruption-indicators.js` owns native sidebar interruption markers and their cleanup. The native thread catalog supplies recency-sorted snapshots; `Threads/thread-catalog.js` owns project matching and the thread-ID index. `Core/dashboard-bridge.js` creates the dashboard, to-do, and prompt controllers with the catalog lookups they need, then applies each thread snapshot to those controllers. `Core/dashboard-bridge.js` also wires feature mounting, host repairs, composer updates, and teardown into `createDashboardLifecycle`. `Core/dashboard-navigation.js` owns page switching; lifecycle observers and DOM repair remain in `Core/dashboard-lifecycle.js`. The prompt controller receives an
explicit thread lookup for composer context. Native import/export and renderer
persistence share the prompt store constructed by the application coordinator.

Internal Codex data uses `Thread` terminology; UI copy uses **chat** for conversations and **to-do** for checklist items. Renderer
snapshots use `RendererThread`; native completion detection uses `ThreadCompletionTracker`.
Shared visibility application lives in `Core/page-visibility-controller.js`.
Composer text/image insertion, model-picker interaction, and shared preset validation and rendering live in `Composer/`. To-do composer transfer lives in `Todos/todo-composer-actions.js`.

`Todos/todo-store.js` owns normalisation, migration, and a serial `Promise<boolean>`
save queue. Item and tag mutations share optimistic rendering and rollback. Image
writes finish before metadata is committed; obsolete images are pruned after a
successful commit. `todo-image-store.js` owns IndexedDB image persistence;
`todo-image-controller.js` owns image validation, draft state, and
reader cleanup; `todo-tag-controller.js` owns tag drafts and tag management. `todo-create-form.js` owns creation drafts, project and thread assignments, submission, and reset decisions. The list
controller coordinates these with persistence. `Sidebar/thread-todo-actions.js` adds
an action to the sidebar chat context menu, snapshots the selected task
before the menu opens, supports keyboard navigation, and
uses the list controller’s persistence and rollback flow. Codex's installed
ContextMenu uses `electronBridge.showContextMenu` on macOS. The to-do controller
reads the host menu provider and its Intl formatter from the row's React fiber,
adds a native menu entry, and retains the host callbacks and submenus. Browser
previews use the DOM menu path. Regression tests cover both menu implementations. To-dos can save a model, effort, and
speed preset; both new-task and selected-task actions apply it before inserting content
through `insertTodoIntoComposer`. The inline paste dropdown resolves the saved project ID
against current sidebar projects, lists threads with that project's exact path,
and rechecks project membership before navigation. Choosing a destination does
not change the saved task link or submit the chat draft. Transfers wait for the
destination task's composer identity; selecting its sidebar row alone is insufficient.
Navigation changes cancel pending preset selections and insertion into another task.
Prompt placeholders preserve literal selection and clipboard text, including dollar signs.
Image formats are validated through the store’s
`isAcceptedImageType`, and `todoImageStore.load` retrieves deferred image data. Teardown disconnects project
observation, aborts image readers, and prevents pending callbacks from changing a
replacement UI.

To-do schema version 8 adds the optional `preset` to items. Version 7 introduced
`project` and `thread` for a linked task. Loading migrates
older `projectTag` and `projectBadge` fields, and the version 6 `chat` field. Preference
loading migrates `collapsedProjects` to `collapsedProjectPaths`, and both
`ignoredProjectPaths` and `mutedProjectPaths` to `hiddenChangeIndicatorPaths`. Successful
migrations write only current fields; failed migration writes leave stored data intact.
Task filter preferences migrate `recent` and `home` to `all`, displayed as **All chats**.
Keep old field names confined to migration code and legacy fixtures.

Review loops use version 2 of the `review-loop.json` document. The file-store
boundary migrates version 1 with remote pushing disabled, and converts older unversioned single-loop and array documents, including
former prompt-context and model-selection fields, before decoding current models.
The coordinator writes version 2 after a successful load. Keep that conversion
until a release can establish that all supported installs have loaded and rewritten
their older files; only then remove the unversioned reader and its fixtures. The
to-do store likewise retains versions 1–7 because those documents may still hold
personal items. Do not remove a reader solely because the current writer has moved
on; first establish a migration cutoff that protects saved data.

Run `swift test` for the complete native and WebKit test suite. Web tests await to-do
save completion instead of assuming that persistence finishes during a DOM event. To-do web tests are split by presets, tags, projects, images, storage failures, and navigation.

## Code organisation

Application filesystem watchers, refresh scheduling, and activity monitors live in
`App/Monitoring`; diagnostics presentation lives in `App/Diagnostics`. Tests mirror
these folders. `NotificationUsageRefresher` owns request coalescing, freshness checks,
and the short-lived cache shared by desktop and phone notification delivery.
`UsageNotificationUpdateCoordinator` serialises each channel’s updates and prepares plans with its own delivery history. Each notifier stores its scheduled notification and task together in one delivery entry; phone delivery entries also retain their retry attempt. Disabling integration reports renderer availability explicitly; the application checks whether Codex is running before showing a disconnected or closed status.
Required runtime and DevTools operations have explicit implementations; test doubles
provide their own stub behaviour. The DevTools convenience overload supplies a real
four-second timeout to the required timed operation.

## Visual baselines

The web test suite compares wide dark, medium light, and narrow dark screenshots against committed baselines.
Snapshots explicitly use two pixels per point so Retina and headless CI displays
produce the same dimensions.

After an intentional visual change, regenerate them with:

```sh
UPDATE_VISUAL_BASELINES=1 swift test --filter DashboardVisualRegressionTests
```

Review page controls live in `Reviews/review-loop-page.js`; status rendering lives in `Reviews/review-loop-view.js`, and app-server requests live in `Reviews/review-rpc-client.js`.
