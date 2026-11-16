# Using Codex Dashboard

For installation and initial startup, see the [README](../README.md). Keep both
Codex and Dashboard running: Dashboard refreshes activity and restores its controls
after Codex reloads. Menu-bar actions open Chat overview, restart Codex, disable
integration, check compatibility, and open Diagnostics. Launch at Login is optional.

While Dashboard integration is enabled, the global **New chat** sidebar button
starts a chat without a project. Use the new-chat action beside a project's name
to start a chat in that project. Quick chat and keyboard shortcuts retain Codex's
normal behaviour.

## Chat overview

**Overview** keeps running chats in the **Active** section, with **Recent** underneath
on the same page. Recent stays clearly labelled when no chats are running.
**Load more** adds ten recent chats at a time from the loaded history. Dashboard loads the
500 most recent chats as a baseline, plus required unread chats and chats with activity
since the current Codex launch, including those now idle. Older history remains
available in Codex. **Unread** groups unread chats by project; **Mark all as read** uses
Codex's read-state action. **Local changes** shows projects with uncommitted changes
or unpushed commits, with separate labels for each.

Projects use Codex's saved names and roots. Removed projects' chats appear under
**Other chats**. Hover or focus a sidebar project to choose one of seven highlight
colours or **No highlight**. Projects remain individually collapsible. An amber Git
icon beside a sidebar project name indicates uncommitted changes or unpushed
commits; hover it for the status. It clears when the project is clean.

**Hide change indicators** hides a project's overview and sidebar Git indicators until restored. Hidden
projects remain under **Indicators hidden** in Local changes. **Commit** commits
the project's pending changes directly. **Push** publishes its unpushed commits.
Both use the same repository workflow as blank project chats and keep the dashboard
open. Progress and errors appear above the project list. Git status uses local
remote-tracking refs without fetching; repositories without a remote show only
uncommitted changes.

By default, Dashboard brings Codex forward and opens a chat when its response
finishes or it asks a structured question, including questions asked while work
continues. The menu bar has separate **Open completed chats automatically** and
**Open chats with questions automatically** toggles. Both can open the relevant
chat even when Codex is already frontmost. Review-loop chats, scheduled automation
chats, and chats whose preview contains the Chrome side-panel marker are excluded.
Typing, voice chat, and dictation suppress automatic focus changes. Suppressed
events and questions already present at startup do not trigger later focus changes.

## Dictation while editing a sent message

Open a sent message with its pencil/Edit action. Place the cursor or select words,
then choose **Dictate** beside that edit field. Choose **Stop dictation** to insert
the final transcript, review it, and select the native **Send** button yourself.
**Cancel dictation** discards the recording. Changing the text or leaving the
editor cancels pending insertion. The separate new-message draft is not used.

This feature reuses the host's built-in streaming dictation client and signed-in
service, without an API key or another transcription engine. It uses the host
renderer for microphone capture and existing audio processing. Recordings stop
automatically after two minutes. Undo/Redo use the editor's normal history.
The feature currently targets the English **Edit message** label. Host updates
can change its private integration contracts; unavailable contracts show an error.

## Prompts and to-dos

**Prompts**, beside the composer's Add button, opens the local library. Prompts can
be global or scoped to the current project, searched, grouped into collapsible
sections, and reordered by keyboard or drag and drop. Sections are shared across
the entire library. Renaming or deleting one affects prompts in every project,
including projects currently hidden. Deleting a section moves its prompts to
**General** without changing their project scope. `{{selection}}` and `{{clipboard}}` insert captured selection
and clipboard text. Inserting a prompt fills the draft without sending it.

Optional model settings select a model, reasoning effort, and Standard/Fast speed.
Unavailable or locked settings stop prompt insertion. Saved model identifiers
remain editable when Codex's model list changes. New prompt and to-do presets
default to **GPT-6.1 Terra**. Use Diagnostics to import, export, or reveal the native
prompt-library file; rolling backups are kept beside it.
Export saves queued prompt edits first. If the running Codex dashboard cannot be
read, export reports an error and leaves any existing destination file intact.
With Codex closed or integration disabled, export uses the saved native library.

**To-dos** stores tasks with details, tags, projects, linked chats, images, and model
settings. Right-click a sidebar chat and choose **Add to To-dos**; a chat already
linked to an open to-do shows **Already in To-dos**. Tasks can be edited, completed,
filtered, or deleted. Deleting a tag removes it from all to-dos.
**Save model settings** stores settings on the to-do for its next transfer to a chat.

For an open to-do with a project, **Paste into chat…** lets you choose a project
chat; linked chats are labelled. For an open to-do without a linked chat, **New chat**
populates a new chat in its assigned project, or a chat with no project when the
to-do has no project. Transfers include text, image, and model settings without
sending. If a new-chat transfer
cannot apply the preset, check the warning and model settings before sending.

## Accounts

1. In Codex's profile menu, choose **Accounts → Save current account**.
2. Choose **Add another account**. Codex restarts signed out; complete sign-in.
3. Save that account, then use **Switch** to change between saved accounts.

Finish or cancel running chats before switching the main window's account.
Dashboard does not merge accounts or rotate them automatically. Removing a saved
active account leaves Codex signed in. Save it again explicitly to restore it to
the list. Do not commit, export, or manually copy `~/.codex/auth.json`.

### Shared chats across account windows

Use the menu-bar app’s **Enable Shared Chats (Restarts Codex Windows)** to let saved
account windows continue the same existing chats. Dashboard queues activation
until all running windows have been idle for two checks, then closes the
independent instances and reconnects them to one
history writer. No chat database or rollout is copied or merged. A separate
profile containing its own chats blocks activation rather than hiding or merging
that history.

Each window keeps its own sign-in and allowance. When it starts a turn, Dashboard
waits for the previous writer process to exit, verifies the selected account,
resumes the original chat, and sends the turn once. Turns are serialized across
all windows. An overlapping send is rejected; send it again after the running
turn finishes. Both windows receive the live chat updates. A failed or timed-out
request is never automatically replayed.

Account information and usage are read with that window’s credentials. In the
main window, choose **Accounts → Switch** under a saved account. Dashboard
reopens the main window using that account and reconnects it to the same shared
history. The separate windows keep their own sign-ins. If Dashboard offers
**Update Shared Chats (Restarts Codex Windows)** in its menu, choose it once to
enable **Switch**. To add a new account, first use
**Disable Shared Chats (Restarts Codex Windows)**. Disabling retains all shared
history in the main window and restores independent secondary histories.

The broker continues running when Dashboard closes. Finder/Dock launches use the
same connection through a session-local `CODEX_APP_SERVER_WS_URL` launchd setting;
disabling restores the previous setting. After logout, a reboot, or a writer
failure, use **Reconnect Shared Chats** to reconnect all windows. Dashboard never starts a replacement
writer automatically beside an unmanaged desktop instance. A missing shared
endpoint fails closed; use the menu to reconnect rather than launching an
independent CLI writer against the shared history.

### Separate account windows

Choose **Open separate window** on a saved account, or use the menu-bar app's
**Open Account Window → account name**. This opens an independent desktop instance
without restarting the main window. Selecting it again focuses that account's
existing instance. Dashboard brings the specific account renderer to the front
and switches it into Codex mode. It verifies that the window is visible and
focused before reporting success. A running instance whose window was closed
is reopened. Keychain access may require approval
on the first launch.

Each account window has a persistent Codex home and desktop profile under
`~/Library/Application Support/Codex Dashboard/account-windows/<saved-account-id>/`.
With Shared Chats disabled, its chat history and settings are independent.
Its sign-in stays separate in both modes.
The local project list is shared automatically across the main window and running
account windows. Additions, names, folder roots, project metadata, pinned projects, ordering, and
removals propagate in both directions, normally within a few seconds. Closed
windows catch up when reopened. Existing registrations are adopted on the first
sync, including distinct project groups that point to the same folder.

Project removal unregisters the group in each window; it does not delete its files
or chat contents. Without Shared Chats, chats and thread assignments stay
separate. Sign-ins, remote connections, and account-specific global state stay separate. For simultaneous edits, changed fields
merge; if the same field changes in multiple windows, the last observed edit wins.
Removal wins over a stale offline copy.
The first launch seeds its sign-in from the saved account. Later launches preserve
its refreshed credentials and respect signing out. Sign in within that window if
its session expires. Credentials remain local, with private directory and file permissions.

Dashboard connects to each running account window automatically. Chat overview,
Git controls, prompts, to-dos, review loops, account controls, and usage tracking
operate against that window’s state; with Shared Chats enabled, chat controls
operate on the shared catalog. Prompts are seeded from the main library
once, then saved independently; to-dos and review loops also remain independent.
Saved-account registrations are shared, while the active account comes from each
window's sign-in. Open another account from its **Open separate window** button;
account switching in a secondary window opens or focuses that account's window.
Add saved accounts in the main window, and renew a secondary window's sign-in
through Codex's own account menu. Background allowance notifications remain managed
by the main Dashboard.

Use **Account Window Dashboards → account → Open Dashboard**, **Restart & Enable**,
or **Disable dashboard integration** in the menu bar to target a specific window.
Older account windows launched without a Dashboard connection need one scoped
restart. Dashboard waits for the window to be idle and in the background before
recovering it automatically; the main Codex window stays running.

Removing a saved account does not delete its independent profile or sign that
window out. Quit a secondary instance from its own app menu when finished.

**Restart to sign in…** restarts Codex signed out when a saved account needs
reauthentication. Sign in to that account, then choose **Save current account**
to update its saved credentials.

The panel shows five-hour and weekly allowance remaining, reset countdowns, and
available banked resets with their nearest known expiry.

When the active account reaches 0% allowance, a prominent notice stays visible in
Codex with a live reset countdown and reset timestamp. If both limits are
depleted, availability uses the later reset. Drag the notice by its heading to
move it, or use the chevron to collapse it to a compact countdown. Its position
and collapsed state stay in place during dashboard refreshes. The notice marks stale usage and
waits for a usage update after the reset time instead of claiming allowance has
returned. Use **Refresh usage** in the Accounts panel to check again.

Refresh individual accounts or other saved accounts without switching. Background refreshes may require a
manual Keychain approval. An account request that cannot reach Dashboard within
15 seconds expires and can be retried; it cannot switch accounts later.

## Usage alerts

macOS alerts and optional phone alerts use these rules:

| Alert | Trigger |
| --- | --- |
| Five-hour reset reminder | One hour before reset, while both limits have allowance |
| Weekly reset or banked-reset expiry reminder | 72, 48, 36, 24, 12, 5, and 1 hours before the deadline |
| Low five-hour allowance | Below 50% and 20% remaining |
| Low weekly allowance | Below 80%, 50%, and 20% remaining |
| Observed reset | Scheduled reset or an unexpected drop in usage before reset |
| Additional banked resets | An observed increase; the first observation establishes a baseline |
| Revised deadline | One time-update alert if the usual warning point has passed |

Thresholds fire once per reset window. When weekly allowance is exhausted, limit
alerts and phone retries are suppressed; banked-reset expiry alerts continue.
Limit alerts resume when allowance returns, including an observed weekly reset.

Deadline alerts refresh usage before delivery. A macOS fallback labels its deadline
as last recorded; check current usage. Phone delivery retries failed refreshes
rather than sending the old deadline.

Enable **Send usage alerts to my phone** in Diagnostics. In the ntfy app, choose
Add Subscription and enter the generated secret topic, then use **Send Test**.
Usage-alert titles and messages, including account names, are sent through
`ntfy.sh`. **New Topic** changes the subscription secret; subscribe to the replacement topic. Send Test remains
available even when usage alerts are suppressed.

## Review loops

Choose a local, single-folder project on **Review loops**, then a review type:
**Bugs and issues**, **Performance**, **Bugs and performance**, **Structure**,
**Structure and naming**, or **Content and quality**. Structure reviews cover code,
UI copy, documentation, prompts, and configuration; the naming option adds naming
review. Both offer **Keep UI copy unchanged**, off by default, to exclude visible
wording and UI names from findings and fixes while allowing internal refactors.
Content reviews also cover documents, CVs, and presentations.

Choose separate review and fix models, optional supported reasoning efforts,
Standard/Fast speed, and a round limit of 1–20 (default five). Bugs and performance
reviews offer general/personal project context and a finding priority limit. P0–P2
includes P0, P1, and P2. These types also offer **Live testing**, off by default, and
**Reload browser extension** under **Testing & publishing**, alongside
remote push settings. Review models come from Codex's live
model list. Select **Start review & fix** to begin the loop.

For a project that already has a loop, select **Queue review & fix** to save another
loop with its own settings. Queued loops run in creation order after earlier loops
for that project finish or are stopped. Paused, blocked, or extension-reload-waiting
loops hold the queue. Other projects can continue independently. Queues survive
Dashboard restarts; resume the preceding loop if the restart paused it. Select
**Cancel queued loop** on its card to remove it from the queue.

Expand **Configured prompt preview** or **Up next** to inspect instructions without
leaving the loop. The preview is generated from current settings, and setting
changes apply to subsequent prompts. **Loop settings** shows the saved
configuration, including project context and playback mute for live testing, for
current and historical loops. Prompt sections keep their expanded state during
refresh.

Each round starts a read-only review in a new chat. Git projects use the current
branch and checkout. Ordinary folders work without Git. Dashboard validates the
review report and automatically starts a separate fix turn in that chat when
qualifying findings remain. Git fixes are committed; folder fixes are
saved and verified within the fix task. Dashboard checks the fix report and folder
fingerprint before completing the round; it does not send a separate verification
turn for folder fixes. The priority limit restricts which findings the review is
asked to report. Saved reports retain any excluded findings already present, but
those findings are excluded from fixes and later verification decisions. Findings
are verified before fixes; invalid findings are withdrawn. All-withdrawn and no-qualifying-finding
reviews finish without a commit. A clean review is an assessment, not proof that
all defects are absent. Multiple projects can run loops, with one executing loop per
project and workspace. Avoid other edits in that workspace while a loop runs.

For ordinary folders, the dashboard fingerprints file contents, names, permissions,
and symlink destinations to detect changes during read-only reviews and between
rounds. Hidden files are included; Finder's `.DS_Store` is ignored. Symlinks are not
traversed. Folder loops never initialise Git or create commits, and remote push is
disabled. Fingerprints only identify file state. The fix task verifies that the
changes work. A paused loop that failed because its folder had no Git repository
can now be resumed.

With **Live testing** enabled, bug reviews use both code review and live testing
to find bugs and issues. For findings discovered through code review, live testing
is used to verify the bug and its fix only when necessary. Fixes for findings discovered through live testing
are verified with live testing. These rules also apply to resumed fix tasks and
later verification. Extension reloads during verification are needed only when
live verification is needed.

Enable **Mute test playback** to mute playback the agent starts for live testing, including autoplay in test tabs it opens. Your existing playback and mute/volume settings, including TikTok picture-in-picture, stay untouched. The agent mutes individual test tabs or players, never the whole browser or system audio.

Structure, naming, and content reviews do not request extension reloads.
Structure and naming loops explicitly use static review in both review and fix
turns. Fix verification can use relevant builds, type checks, and automated checks
that do not launch or drive a browser or application UI. Live browser testing,
Computer Use, and extension reloads require an explicit request for that task.

With **Reload browser extension** enabled, Codex reloads the extension before live
testing and again after fixes when live verification is needed. In your everyday
Chrome profile, it uses the extension card’s **Reload** button on `chrome://extensions`.
Chrome may ask you to approve a debugging connection. See
[extension testing details](development.md#review-loop-extension-testing) for the
agent’s installation checks and connection cleanup.

If the loop shows **Waiting for extension reload**, follow its instructions to
reload the named extension, then select **Extension reloaded — continue**. The
same chat and round resume with unfinished fixes preserved. Final review and
commit checks still run before the round can complete.

The review page overview counts unfinished loops, including queued, paused, blocked,
and extension-reload-waiting loops. The sidebar shows separate counts for running
or waiting loops, an amber pause icon for paused loops, an amber **!** for
blocked loops or loops awaiting an extension reload, and a green **✓** for completed
loops or loops that reached their round limit. Counts include only current loops;
moving a finished loop to history removes it from the count. Stopped loops are
excluded. Hover over a marker for its description.

The dashboard counts the finding sections in a review automatically. Review responses
use a completion or blocked heading, a summary, and one section per finding, without
a separate findings total. If an existing chat used the previous format, ask it to
return the same report with the `Findings: N` line removed, then select **Resume**.
Malformed reports show the specific format problem and how to correct it.

**Remote push** defaults to keeping commits local. When enabled, verified fix
commits are pushed after each round to the upstream branch, or the current branch
on `origin` or the sole remote. New branch pushes record an upstream. Pushes are
never forced. Before pushing, Dashboard fetches the destination branch. If it has
advanced separately, Dashboard merges its changes into the clean checkout and
runs read-only verification of the original findings before publishing the merged
HEAD. The original fix commit is preserved. Merge conflicts are aborted and block
the loop with instructions to resolve the histories in the review chat. Other push
failures block the loop; Resume retries without another fix prompt.

A completed fix is reconciled against Git history. If the clean original branch has
advanced and still contains the reported fix commit, the loop runs a read-only
verification of the original findings in the same chat. It completes the round only
when verification reports no remaining findings and HEAD is unchanged. A new HEAD
requires a new verification. The result records both the original fix commit and
the verified HEAD, which becomes the starting point for the next round. Remote push publishes only the reported
fix commit, excluding later commits unless publishing the reverified HEAD is needed
to preserve the remote history. Rewritten history, branch or checkout changes,
uncommitted work, and changes after an all-withdrawn report still require attention.
Resume retries a blocked checkpoint without repeating the completed fix task.

After a round completes, changes you commit on the same branch become the baseline
for the next review. The checkout must be clean. If a loop was blocked between
completed rounds because the project changed, select **Resume** to review the current
commit in the next round. The completed round keeps its original fix and verified
commit records. Changes during an unfinished round still require reconciliation.

**Pause after round** finishes the current round. **Stop loop** prevents new work
and interrupts its running turn. While **Stopping**, its workspace stays reserved;
interruption failures remain visible and retry automatically, or use **Retry Stop**.
If its chat was deleted, Stop confirms its absence in the local chat catalog
and releases the workspace. Catalog failures retain the workspace for another retry.
After a Dashboard restart, running and waiting loops pause while stopping loops
continue stopping. **Resume** reconciles known work first
and never duplicates an unconfirmed launch. If a turn failed or was interrupted
(for example, after running out of usage), restore access and select **Resume**.
Dashboard sends a continuation in the existing chat, preserving unfinished fixes
and the same round. A running turn or completed report is checked without sending
another prompt. For a completed report that needs attention, open its chat,
answer its question or resolve the blocker, then Resume. An unconfirmed launch requires inspection before starting another loop;
an unfinished old JSON-format report requires a new loop.

Dirty checkouts, unexpected branch/commit changes, malformed reports, interrupted
turns, and approval requests stop progression with an explanation. Review edits
block before any fix or push. Reaching the configured limit ends with **Round limit
reached**, which means the configured rounds finished, not that findings are absent.
Each loop card shows the latest round’s **Review → Fix & commit** stages (**Fix & verify** for ordinary folders),
with an active spinner, completed checks, and explicit paused or attention states.
Verification normally happens within the fix task. When the checkout advances
beyond the reported fix commit, a separate verification turn appears as
**Reverifying fixes** within the fix stage. Stages that are not needed are labelled
accordingly. The summary shows findings in the latest review, findings
addressed across successful fix rounds, and distinct fix commits. These counts
summarise recorded rounds and do not represent unique issues across reviews.
Motion follows the system’s reduced-motion preference.

Finished loops stay under **Current loops**, including after navigation or app restart.
Use **Move to history** on a finished loop to move it to history explicitly. Expand **Manage history** to delete saved loops and their
round records; the review chats remain available. **Delete loops created earlier**
uses creation order, regardless of the displayed last updated dates. **Delete all
finished loops** removes every finished loop. Both bulk deletion actions include
finished loops still shown under **Current loops**; unfinished loops are kept.

## Disable push without a remote

While a local **Commit or push** dialog is open, Dashboard checks the repository
selected in that dialog. When it has no Git remote, **Commit and push** and **Push**
are grayed out and blocked for mouse and keyboard input. **Commit** keeps its normal
behaviour. Checks use Codex's local Git metadata and never contact a remote. Opening the
modal requests a check immediately, without waiting for Dashboard's refresh cycle.
Clicking **Commit** in **Changed projects** starts the check during navigation,
so a completed result can disable push actions as soon as the dialog opens.
Results from the last five seconds are applied immediately on reopening and
rechecked in the background. Changes to remotes are also picked up while the
dialog stays open.

Remote-host dialogs are left to Codex. If Git cannot be read or the controls no
longer match the supported structure, Dashboard leaves Codex's controls unchanged.
The **Disable push without a remote** check appears in Diagnostics; changed controls
produce **Push controls changed in Codex; automatic disabling is unavailable.**
Only this feature stops applying changes. A supported dialog is checked again on
its next refresh. Disabling Dashboard restores the original controls.

## Compatibility and diagnostics

Codex updates can change the private contracts used by this unofficial integration.
Dashboard checks compatibility after version changes. Warning icons and Diagnostics
identify failed checks; **Unavailable** means a check could not complete, while
**Compatibility not checked** means no checks have run. Blocking drift prevents
remounting. Diagnostics also shows versions, refresh state, loaded chats, renderer
targets, and copyable details.

The **Git toolbar actions** check also runs during normal synchronization. It warns
when Commit, Commit & push, or Push is missing in a supported local Git chat,
including when Codex's toolbar anchor or native Git menu changes. Navigation gets
a short settling period. Dashboard pages, dialogs, and chats without a Git checkout, and chats outside a project
leave this check pending. The warning clears when the shortcuts return or you
leave the eligible chat.

**Disable dashboard integration** waits for current synchronization and review operations
to finish, then removes the injected controls. Remote publication can delay removal.
A normal Codex restart also removes the controls. The signed Codex application bundle
is never modified.

### Automatic dashboard recovery

While Codex is running in the background and no chats are running, Dashboard
restarts Codex automatically if its integration is missing, a mount fails, or the
menu-bar compatibility warning is showing.
Automatic restarts keep Codex in the background and pause while speech input is
active. Each attempt checks chat activity again before restarting. If chat activity
cannot be checked or a required compatibility check fails, Codex is left running.

Recovery stops after three actual restarts for the same failure. A successful
mount with no compatibility warnings resets the limit; **Restart & Enable** also starts a fresh attempt manually.
Recovery runs on the normal monitoring polls. **Disable dashboard integration**
turns off automatic recovery until you enable integration again. Checks run again
before restarting and after the new renderer mounts. Stale warnings that clear
during preflight do not restart an otherwise healthy mount.


## Git actions in the chat header

Dashboard adds **Commit**, **Commit & push**, and **Push** next to the chat’s
Share and Summary buttons, including when the summary panel is closed.
Commit starts Codex’s native commit workflow directly, leaving the message blank
so Codex generates it automatically. Commit & push starts Codex’s combined
commit-and-push workflow directly. The intermediate menus stay hidden for both actions.
Push hands off to
Codex’s native push workflow. Native availability checks still apply; unavailable shortcuts leave the
menu visible with the disabled action and its explanation.

Commit and Commit & push are disabled when there are no changes to commit. Push
is disabled when there are no unpushed commits. These states update with
Dashboard’s repository status snapshots. Unknown repository status disables
shortcuts until it is available.

Push and Commit & push stay disabled until a remote is confirmed and remain
disabled when none is configured. The Git menu’s Push action follows the same rule.

Buttons follow the selected local project chat’s primary repository. They appear
in project chats with a supported Git checkout, including the blank new-chat
screen before the first message. New chats check the selected project's Git status
and run actions directly through Codex's Git worker. Commit and Commit & push
include staged, unstaged, and untracked changes. Codex generates the commit message
in a temporary read-only session. Progress and errors appear beneath the shortcuts.
A failed push preserves the local commit for retry with Push. Project or branch
changes cancel any remaining steps before the next Git write.
The shortcuts disappear on Dashboard pages. A running response keeps Git shortcuts
available until repository files differ from the last normally completed response.
New edits block all three shortcuts until a response finishes normally; stopping,
interrupting, or reaching a usage limit does not release that block. Staging or
committing existing files alone does not count as a new file edit. If Dashboard
has not observed a completed response checkpoint, shortcuts wait for one.
Dashboard restores the controls after navigation or
header replacement and removes them when the integration is disabled.
