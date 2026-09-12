# Development and testing

## Preview

Run `./DashboardPreview/generate.sh`, then open `DashboardPreview/index.html` in a
browser. Regenerate after changing renderer resources or the prompt schema. The
ignored `injection.js` is built by the production `InjectionBundle` loader, including
the Swift-defined prompt schema; preview fixtures use the current thread contract.
Generation exits before starting the menu-bar application.

Shared page visibility, navigation-button construction, and icons live in `Core`. Initial mounting and renderer repairs share one mounting operation. `Threads/thread-unread-state.js` owns unread reconciliation, completion ticks, polling, and the snapshot thread-ID index. The prompt controller receives an
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
controller coordinates these with persistence. Teardown disconnects project
observation, aborts image readers, and prevents pending callbacks from changing a
replacement UI.

To-do schema version 5 uses `project`; older `projectTag` and `projectBadge` values
are migrated when loading. Preference loading migrates `collapsedProjects` to
`collapsedProjectPaths` and `ignoredProjectPaths` to `mutedProjectPaths`. Successful
migrations write only current fields; failed migration writes leave stored data intact.
Keep old field names confined to migration code and legacy fixtures.

Run `swift test` for the complete native and WebKit test suite. Web tests await to-do
save completion instead of assuming that persistence finishes during a DOM event.

## Visual baselines

The web test suite compares wide dark, medium light, and narrow dark screenshots against committed baselines. After an intentional visual change, regenerate them with:

```sh
UPDATE_VISUAL_BASELINES=1 swift test --filter DashboardVisualRegressionTests
```
