# Development and testing

## Build toolchain

GitHub Actions selects Xcode 26.6 explicitly on macOS 26 and runs the test suite
followed by a release build. The WebKit tests require Safari 26.4 or newer's
CSS zoom coordinate behavior; older WebKit versions report unscaled rectangles.
Use Xcode 26.6 for development; the application's deployment target remains macOS 14.

## Preview

Run `./DashboardPreview/generate.sh`, then open `DashboardPreview/index.html` in a
browser. Regenerate after changing renderer resources or the prompt schema. The
ignored `injection.js` is built by the production `InjectionBundle` loader, including
the Swift-defined prompt schema; preview fixtures use the current thread contract.
Generation exits before starting the menu-bar application.

Shared page visibility, navigation-button construction, and icons live in `Core`. Initial mounting and renderer repairs share one mounting operation. `Threads/thread-presentation-state.js` owns unread reconciliation, completion ticks, and polling. `Threads/thread-catalog.js` owns sorting, project matching, and the thread-ID index; dashboard, to-do, and prompt controllers receive its lookup operations during startup. The bridge applies each snapshot to the catalog before refreshing the pages. The prompt controller receives an
explicit thread lookup for composer context. Native import/export and renderer
persistence share the prompt store constructed by the application coordinator.

Internal Codex data uses `Thread` terminology; UI copy uses **Task**. Renderer
snapshots use `RendererThread`; native completion detection uses `ThreadCompletionTracker`.
Shared visibility application lives in `Core/page-visibility-controller.js`.
Composer text/image insertion and model-picker interaction live in `Composer/`.

`Todos/todo-store.js` owns normalisation, migration, and a serial `Promise<boolean>`
save queue. Item and tag mutations share optimistic rendering and rollback. Image
writes finish before metadata is committed; obsolete images are pruned after a
successful commit. `todo-image-controller.js` owns image validation, draft state, and
reader cleanup; `todo-tag-controller.js` owns tag drafts and tag management. The list
controller coordinates these with persistence. To-dos can save a model, effort, and
speed preset; both new-task and linked-task actions apply it before inserting content
through `insertTodoIntoComposer`. Image formats are validated through the store’s
`isAcceptedImageType`, and `loadImages` retrieves deferred image data. Teardown disconnects project
observation, aborts image readers, and prevents pending callbacks from changing a
replacement UI.

To-do schema version 8 adds the optional `preset` to items. Version 7 introduced
`project` and `thread` for a linked task. Loading migrates
older `projectTag` and `projectBadge` fields, and the version 6 `chat` field. Preference
loading migrates `collapsedProjects` to `collapsedProjectPaths`, and both
`ignoredProjectPaths` and `mutedProjectPaths` to `hiddenChangeIndicatorPaths`. Successful
migrations write only current fields; failed migration writes leave stored data intact.
Keep old field names confined to migration code and legacy fixtures.

Run `swift test` for the complete native and WebKit test suite. Web tests await to-do
save completion instead of assuming that persistence finishes during a DOM event.

## Code organisation

Application filesystem watchers, refresh scheduling, and activity monitors live in
`App/Monitoring`; diagnostics presentation lives in `App/Diagnostics`. Tests mirror
these folders. `NotificationUsageRefresher` owns request coalescing, freshness checks,
and the short-lived cache shared by desktop and phone notification delivery.
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
