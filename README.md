# Codex Dashboard

Codex Dashboard is a native macOS menu-bar utility that adds a chat overview
to the local Codex app. It relaunches Codex with a loopback-only DevTools connection
and injects a removable dashboard into the main renderer.

This is an independent personal project and is not affiliated with OpenAI.

## Project overview

- **Chat monitoring:** recent activity, unread status, completion tracking, uncommitted files and unpushed Git commits.
- **Review loops:** concurrent project reviews with automatic fixes and commits, separate model choices, pause/resume/stop controls, and optional remote pushing. See [review-loop behaviour](docs/architecture.md#review-loops).
- **Workflow tools:** a reusable prompt library and a persistent to-do list with tags, projects and images.
- **Implementation:** Swift 6, AppKit and JavaScript, with a native coordinator and a modular renderer interface.
- **Automated testing:** XCTest and WebKit tests cover state changes, persistence, migration failures, UI behaviour and screenshot-based visual regression.

Chat overview groups chats using Codex’s current saved projects, combining symlink aliases. Chats from removed projects remain under **Other chats**, without project change indicators.

Chat overview’s **Local changes** filter includes uncommitted files and unpushed commits, with separate status labels. Unpushed status uses local remote-tracking refs without fetching; a branch without an upstream is compared with all known remote refs. Repositories without a remote show only uncommitted changes.

The project explores reliable desktop workflow automation, including file-change
monitoring, scheduled refresh, asynchronous persistence and recovery after failed
writes. Test fixtures use synthetic data.

The DevTools connection is limited to the local machine. New Codex launches use a new
high port; Dashboard reuses that port when reconnecting to the running Codex process.
Chromium DevTools does not authenticate local clients.
Use this utility only on a trusted personal macOS account; do not leave Codex running
with the dashboard enabled when untrusted local software has access to your account.

## Install

Run:

```sh
./install.sh
```

This runs the test suite, builds and signs `Codex Dashboard.app`, then
atomically installs it in `$HOME/Applications`, preserving the previous bundle until the replacement is verified. Use `./install.sh --relaunch` to open the
new build, or `--skip-tests` during local iteration. `--no-launch` is the
default and is also accepted explicitly.

Local installs create and reuse a **Codex Dashboard Local Development** signing
certificate in your login Keychain. Saved-account credentials are accessed by a
separately signed helper whose approvals persist across Dashboard-only rebuilds.
Choose **Always Allow** when macOS first asks the helper to access a saved account;
each account is a separate Keychain item. Changes to the helper or signing
certificate may require approval again.

To use an existing signing certificate, set `SIGNING_IDENTITY` to its name or SHA-1
fingerprint when running the installer. The installer stops if signing fails.
See [local signing](docs/development.md#local-signing) for certificate trust,
Keychain partition identities, and approval persistence details.

To uninstall without permanently deleting the bundle, run `./uninstall.sh`.
It moves the installed app to the Trash.

## Use

1. Open **Codex Dashboard** from `$HOME/Applications`; it appears in the menu bar.
2. Finish any active response in Codex.
3. Select **Restart & Enable**.
4. Select **Chat overview** directly in the Codex sidebar. It opens in
   the main content pane while the rest of Codex navigation stays available.

Select **To-dos** in the same sidebar area to keep a personal task list in Codex's
local renderer storage.
Right-click a sidebar chat and select **Add to To-dos** to save its title
and link, including its project when available. Chats with an open linked to-do
show **Already in To-dos**.
Each to-do can be edited, completed, filtered, or deleted without leaving the app.
New prompt-library and to-do model settings default to **GPT-6.1 Sol**.
The shared model selector also offers the other models; saved presets keep their
selected model. Review-loop model and reasoning choices come from Codex's live
model list, including GPT-6.1 Sol when available to the signed-in account.
For an open to-do with a project assigned, select **Paste into chat…** to choose
a chat from an inline dropdown and insert the to-do into its draft. Linked chats
are labelled in the dropdown. Pasting includes the title, details, image, and model settings when
present; it does not send the message.

The application runs without a main window and must remain open to refresh thread activity and restore the dashboard after renderer reloads.
All controls are available from the menu bar, with a separate Diagnostics window available on demand. Launch at Login is optional. By default, the utility brings Codex to the foreground and opens the completed chat when its response finishes, except for review loop chats and chats started in the ChatGPT Chrome extension; automatic focus changes are suppressed during typing, voice chat, and dictation (including startup and transcription). Suppressed completions are not opened later. This can be disabled from the menu bar. Use
**Disable dashboard integration** to unload the injected UI immediately. A normal Codex restart also
removes it.

## Development

See [architecture and behaviour](docs/architecture.md) for runtime, storage, refresh,
and notification details. See [development and testing](docs/development.md) for
renderer previews, resource organisation, migrations, and visual baselines.

## Account switching

1. While signed in to Codex, open **Codex profile menu → Accounts → Save current account**. The dashboard uses the authenticated account's name automatically.
2. Choose **Add another account**. Codex restarts signed out; complete the normal OpenAI sign-in in Codex.
3. Save the second account. You can then switch between the saved accounts from **Codex profile menu → Accounts**.

If an account request cannot reach the dashboard within 15 seconds, it expires and the Accounts panel enables retry. Expired requests cannot switch accounts later. The dashboard reconnects after renderer timeouts and rediscovers unavailable windows. Finish or cancel running Codex chats before switching accounts.

Codex still uses one active account at a time. The switcher does not merge accounts, transfer subscriptions or usage, or rotate accounts automatically. Do not commit, export, or manually copy `~/.codex/auth.json`.
