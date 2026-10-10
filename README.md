# Codex Dashboard

[![CI](https://github.com/MrLawrenceAwe/Codex-Dashboard/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/MrLawrenceAwe/Codex-Dashboard/actions/workflows/ci.yml)

A native macOS menu-bar utility that brings chat activity, unfinished work and project changes into one dashboard inside Codex.

**Stack:** Swift 6, AppKit, JavaScript, XCTest and WebKit.

This is an independent personal project and is not affiliated with OpenAI.

![Chat overview showing running work, unread chats and project changes](docs/images/chat-overview.png)

*Screenshot from the automated visual test fixture; all chats and projects are synthetic.*

## Features

- **Chat monitoring:** recent activity, unread status, completion tracking, uncommitted files and unpushed Git commits.
- **Review loops:** project reviews with automatic fixes and commits, separate model choices, pause/resume/stop controls, and optional remote pushing.
- **Workflow tools:** a reusable prompt library and a persistent to-do list with tags, projects and images.

See [Using Codex Dashboard](docs/usage.md) for feature behaviour and controls.

The DevTools connection is limited to the local machine. New Codex launches use a new
high port; Dashboard reuses that port when reconnecting to the running Codex process.
Chromium DevTools does not authenticate local clients.
Use this utility only on a trusted personal macOS account; do not leave Codex running
with the dashboard enabled when untrusted local software has access to your account.

## Install

Requires macOS 14+, the Codex desktop app, and a Swift 6 toolchain. CI uses macOS 26 and Xcode 26.6 for WebKit visual baselines.

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

Keep Dashboard running to refresh activity and restore its controls after Codex
reloads. Use the menu bar for Diagnostics, Launch at Login, automatic completion
focus, and **Disable dashboard integration**.

See [Using Codex Dashboard](docs/usage.md) for chat filters, prompts, to-dos,
accounts, usage alerts, review loops, and recovery instructions.

## Development

See [architecture and behaviour](docs/architecture.md) for runtime, storage, refresh,
and notification details. See [development and testing](docs/development.md) for
renderer previews, resource organisation, migrations, and visual baselines.

See [review-loop extension testing](docs/usage.md#review-loops) for automatic reloads,
manual recovery, and static-review rules.
