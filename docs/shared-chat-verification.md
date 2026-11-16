# Shared chat verification — 16 November 2026

The live tests used saved Lawrence and Oluwatoyin credentials in private,
disposable homes. Existing chat databases and rollouts were not modified.
The model was selected from the live catalog (`gpt-6-luna`).

- Direct SDK test: Lawrence → Oluwatoyin → Lawrence completed three turns on
  one account-scoped, paginated chat. Later turns recalled the original random
  marker without including it in their prompts.
- Broker test: the same sequence succeeded through authenticated WebSockets,
  with one catalog row and one rollout. Each server restart checked the selected
  credential's account identity before sending the next turn.
- Desktop test: two isolated native profiles opened in Codex mode, returned
  distinct account identities, displayed the same project and chat, and read the
  same history. The second and third turns went through each desktop window's
  native `electronBridge` request channel and completed with the original marker.
- Project transition test: changing the secondary window from independent IDs
  to shared-server IDs preserved the existing registration. Creating, pinning,
  reordering, renaming, and removing a disposable project propagated through
  both native sidebars, without producing duplicate shared identities.
- Composer check: the chat was opened in each native sidebar; both composers
  were available and neither reported a workspace-settings load error.
- Regression tests exercise simultaneous sends, child-turn boundaries, steering,
  settings reads during turns, mismatched credentials, separate approval IDs,
  binary and text WebSocket messages, and exclusion of a second broker. A fake
  server's write log contains only the admitted A → B → A turns.

An early desktop test caught a private writer restart emitting `account/updated`:
Codex retired an accepted request while its turn still completed. The broker now
keeps client identity stable, reads account information with each client's own
credentials, and consumes the writer's internal account-change notifications.
The successful desktop test was run after that fix.

The production enable/disable controls check idle windows before restarting
native instances. Activation is a separate menu action because the current chat
cannot be restarted while its implementation turn is running. No production
history was moved, copied, or merged by these tests. Usage percentages are rounded;
account selection was verified through distinct credentials and authenticated
successful requests, rather than inferring exact billing from a percentage change.
