# Codex Dashboard

Codex Dashboard is a native macOS controller for an active-task dashboard
inside the Codex experience in ChatGPT. It follows the useful part of Attune's
architecture—a normal app relaunch with a loopback-only DevTools bridge—while
keeping functional UI extensions separate from Attune's deliberately CSS-only
safety contract.

## Install

Run:

```sh
./build.sh
```

This builds and ad-hoc signs `Codex Dashboard.app`, then installs it in
`/Users/lawrenceawe/Applications`.

## Use

1. Open **Codex Dashboard** from `/Users/lawrenceawe/Applications`.
2. Finish any active response in ChatGPT.
3. Select **Restart Codex & Enable Dashboard**.
4. Select **Dashboard** directly in the Codex sidebar. The dashboard opens in
   the main content pane while the rest of Codex navigation stays available.

The controller must remain open to refresh task activity and restore the dashboard after renderer reloads. Use
**Remove** to unload the injected UI immediately. A normal ChatGPT restart also
removes it.

## Architecture

- Native SwiftUI control panel; no browser controller or Node runtime.
- Loopback-only Chromium DevTools connection.
- Versioned adapter resources under `Resources/Adapter`.
- Local task metadata from `state_5.sqlite` and live activity from `logs_2.sqlite`.
- No modification of `/Applications/ChatGPT.app` or its code signature.
- A native-looking **Dashboard** sidebar item is inserted beside Codex's other
  top-level destinations; there is no floating launcher.
- Host selectors are isolated in `canvas.js` for maintenance after Codex UI updates.

This is an unofficial personal integration. ChatGPT updates can require adapter
maintenance.
