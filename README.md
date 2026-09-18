# Codex Dashboard

Codex Dashboard is a native macOS menu-bar utility that adds a recent-task dashboard
to the local Codex app. It relaunches Codex with a loopback-only DevTools connection
and injects a removable dashboard into the main renderer.

This is an independent personal project and is not affiliated with OpenAI.

## Project overview

- **Task monitoring:** recent activity, unread status, completion tracking and Git working-tree changes.
- **Workflow tools:** a reusable prompt library and a persistent to-do list with tags, projects and images.
- **Implementation:** Swift 6, AppKit and JavaScript, with a native coordinator and a modular renderer interface.
- **Automated testing:** XCTest and WebKit tests cover state changes, persistence, migration failures, UI behaviour and screenshot-based visual regression.

The project explores reliable desktop workflow automation, including file-change
monitoring, scheduled refresh, asynchronous persistence and recovery after failed
writes. Test fixtures use synthetic data.

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

## Development

See [architecture and behaviour](docs/architecture.md) for runtime, storage, refresh,
and notification details. See [development and testing](docs/development.md) for
renderer previews, resource organisation, migrations, and visual baselines.

## Account switching

1. While signed in to Codex, choose **Accounts → Save Current Account**. The dashboard uses the authenticated account's name automatically.
2. Choose **Sign In to Another Account…**. Codex restarts signed out; complete the normal OpenAI sign-in in Codex.
3. Save the second account. You can then switch between the saved accounts from the menu bar or the account selector in **Task Dashboard**.

Codex still uses one active account at a time. The switcher does not merge accounts, transfer subscriptions or usage, or rotate accounts automatically. Do not commit, export, or manually copy `~/.codex/auth.json`.
