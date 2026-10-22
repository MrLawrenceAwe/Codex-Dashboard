# Using Codex Dashboard

For installation and initial startup, see the [README](../README.md). Keep both
Codex and Dashboard running: Dashboard refreshes activity and restores its controls
after Codex reloads. Menu-bar actions open Chat overview, restart Codex, disable
integration, check compatibility, and open Diagnostics. Launch at Login is optional.

## Chat overview

**Recent and running** puts running chats above recent chats. **Load more** adds
ten recent chats at a time from the loaded history. Dashboard loads up to 500
recent chats, plus required unread and active chats; older history remains available
in Codex. **Unread** groups unread chats by project; **Mark all as read** uses
Codex's read-state action. **Local changes** shows projects with uncommitted changes
or unpushed commits, with separate labels for each.

Projects use Codex's saved names and roots. Removed projects' chats appear under
**Other chats**. Hover or focus a sidebar project to choose one of seven highlight
colours or **No highlight**. Projects remain individually collapsible.

**Hide change indicators** hides a project's indicators until restored. Hidden
projects remain under **Indicators hidden** in Local changes. **Commit or push**
opens Codex's native Commit flow through an idle chat in the same repository when
there are uncommitted changes, or selects its Push action when only unpushed commits
remain. Chats in separate nested repositories cannot handle their parent project's
Git actions. The handoff stops if you switch chats, including while the initial chat
selection is pending. Git status uses local remote-tracking refs without fetching;
repositories without a remote show only uncommitted changes.

By default, Dashboard brings Codex forward and opens a chat when its response
finishes or it asks a structured question, including questions asked while work
continues. The menu bar has separate **Open completed chats automatically** and
**Open chats with questions automatically** toggles. Both can open the relevant
chat even when Codex is already frontmost. Review-loop chats and chats started in the ChatGPT Chrome extension are excluded. Typing, voice chat, and
dictation suppress automatic focus changes; suppressed events are not opened
later. Existing questions at Dashboard startup do not trigger focus changes.

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
default to **GPT-6.1 Sol**. Use Diagnostics to import, export, or reveal the native
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

Finish or cancel running chats before switching. Codex uses one active account;
Dashboard does not merge accounts or rotate them automatically. Removing a saved
active account leaves Codex signed in. Save it again explicitly to restore it to
the list. Do not commit, export, or manually copy `~/.codex/auth.json`.

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
review. Content reviews also cover documents, CVs, and presentations.

Choose separate review and fix models, optional supported reasoning efforts,
Standard/Fast speed, and a round limit of 1–20 (default five). Bugs and performance
reviews offer general/personal project context and a finding priority limit. P0–P2
includes P0, P1, and P2. These types also offer **Live testing**, off by default, and
**Reload browser extension** before testing under **Testing & publishing**, alongside
remote push settings. Review models come from Codex's live
model list. Select **Start review & fix** to begin the loop.

Expand **Configured prompt preview** or **Up next** to inspect instructions without
leaving the loop. **Loop settings** shows the saved configuration, including project context and the
playback mute setting for live testing, for current and historical loops. Prompt sections
keep their expanded state during refresh.

**Configured prompt preview** shows instructions generated from the current loop
settings. It does not record the exact prompt submitted to a chat; setting changes
apply to subsequent prompts.

Each round starts a read-only review in a new chat. Git projects use the current
branch and checkout; ordinary folders work without Git. Qualifying findings trigger
a separate fix follow-up in that chat. Git fixes are committed; folder fixes are
saved and verified within the fix task. Dashboard checks the fix report and folder
fingerprint before completing the round; it does not send a separate verification
turn for folder fixes. Excluded priorities remain visible but are not fixed. Findings are verified
before fixes; invalid findings are withdrawn. All-withdrawn and no-qualifying-finding
reviews finish without a commit. A clean review is an assessment, not proof that
all defects are absent. Multiple projects can run loops, with one active loop per
project and workspace. Avoid other edits in that workspace while a loop runs.

For ordinary folders, the dashboard fingerprints file contents, names, permissions,
and symlink destinations to detect changes during read-only reviews and between
rounds. Hidden files are included; Finder's `.DS_Store` is ignored. Symlinks are not
traversed. Folder loops never initialise Git or create commits, and remote push is
disabled. Fingerprints identify changes; they are not backups or an undo history.
Avoid other edits while the loop runs: fingerprints detect changes but do not
establish that a fix works. A paused loop that failed because its
folder had no Git repository can now be resumed.

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

The sidebar shows separate counts for running or waiting loops, an amber **!** for
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

Finished loops move to history. Expand **Manage history** to delete saved loops and their
round records; the review chats remain available. **Delete loops created earlier**
uses creation order, regardless of the displayed last updated dates.

## Compatibility and diagnostics

Codex updates can change the private contracts used by this unofficial integration.
Dashboard checks compatibility after version changes. Warning icons and Diagnostics
identify failed checks; **Unavailable** means a check could not complete, while
**Compatibility not checked** means no checks have run. Blocking drift prevents
remounting. Diagnostics also shows versions, refresh state, loaded chats, renderer
targets, and copyable details.
**Disable dashboard integration** immediately removes all injected controls; a normal
Codex restart also removes them. The signed Codex application bundle is never modified.
