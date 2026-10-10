# Using Codex Dashboard

For installation and initial startup, see the [README](../README.md). Keep both
Codex and Dashboard running: Dashboard refreshes activity and restores its controls
after Codex reloads. Menu-bar actions open Chat overview, restart Codex, disable
integration, check compatibility, and open Diagnostics. Launch at Login is optional.

## Chat overview

**All chats** puts running chats above recent chats. **Load more** adds ten recent
chats at a time. **Unread** groups unread chats by project; **Mark all as read** uses
Codex's read-state action. **Local changes** shows projects with uncommitted changes
or unpushed commits, with separate labels for each.

Projects use Codex's saved names and roots. Removed projects' chats appear under
**Other chats**. Hover or focus a sidebar project to choose one of seven highlight
colours or **No highlight**. Projects remain individually collapsible.

**Hide change indicators** hides a project's indicators until restored. Hidden
projects remain under **Indicators hidden** in Local changes. **Commit or push**
opens Codex's native Git dialog through an idle project chat. Git status uses local
remote-tracking refs without fetching; repositories without a remote show only
uncommitted changes.

By default, Dashboard brings Codex forward and opens a chat when its response
finishes. Disable this from the menu bar if unwanted. Review-loop chats and chats
started in the ChatGPT Chrome extension are excluded. Typing, voice chat, and
dictation suppress automatic focus changes; suppressed completions are not opened
later.

## Prompts and to-dos

**Prompts**, beside the composer's Add button, opens the local library. Prompts can
be global or scoped to the current project, searched, grouped into collapsible
sections, and reordered by keyboard or drag and drop. Deleting a section moves its
prompts to **General**. `{{selection}}` and `{{clipboard}}` insert captured selection
and clipboard text. Inserting a prompt fills the draft without sending it.

Optional model settings select a model, reasoning effort, and Standard/Fast speed.
Unavailable or locked settings stop prompt insertion. Saved model identifiers
remain editable when Codex's model list changes. New prompt and to-do presets
default to **GPT-6.1 Sol**. Use Diagnostics to import, export, or reveal the native
prompt-library file; rolling backups are kept beside it.

**To-dos** stores tasks with details, tags, projects, linked chats, images, and model
settings. Right-click a sidebar chat and choose **Add to To-dos**; a chat already
linked to an open to-do shows **Already in To-dos**. Tasks can be edited, completed,
filtered, or deleted. Deleting a tag removes it from all to-dos.

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
Only alert titles and messages are sent through `ntfy.sh`. **New Topic** changes the
subscription secret; subscribe to the replacement topic. Send Test remains
available even when usage alerts are suppressed.

## Review loops

A completed fix is reconciled against Git history. If the clean original branch has
advanced and still contains the reported fix commit, the loop runs a read-only
verification of the original findings in the same chat. It completes the round only
when verification reports no remaining findings and HEAD is unchanged. A new HEAD
requires a new verification. The result records both the original fix commit and
the verified HEAD, which becomes the starting point for the next round. Remote push publishes only the reported
fix commit, excluding later commits. Rewritten history, branch or checkout changes,
uncommitted work, and changes after an all-withdrawn report still require attention.
Resume retries a blocked checkpoint without repeating the completed fix task.


The sidebar shows separate counts for running or waiting loops, an amber **!** for
blocked loops or loops awaiting an extension reload, and a green **✓** for completed
loops or loops that reached their round limit. Counts include only current loops;
moving a finished loop to history removes it from the count. Stopped loops are
excluded. Hover over a marker for its description.

Enable **Mute test playback** to mute playback the agent starts for live testing, including autoplay in test tabs it opens. Your existing playback and mute/volume settings, including TikTok picture-in-picture, stay untouched. The agent mutes individual test tabs or players, never the whole browser or system audio.

Choose a local, single-folder project on **Review loops**, then a review type:
**Bugs and issues**, **Performance**, **Bugs and performance**, **Structure**,
**Structure and naming**, or **Content and quality**. Structure reviews cover code,
UI copy, documentation, prompts, and configuration; the naming option adds naming
review. Content reviews also cover documents, CVs, and presentations.

Choose separate review and fix models, optional supported reasoning efforts,
Standard/Fast speed, and a round limit of 1–20 (default five). Bugs and performance
reviews offer general/personal project context and a finding priority limit. P0–P2
includes P0, P1, and P2. These types also offer **Live testing**, off by default, and
**Reload browser extension** before testing. Review models come from Codex's live
model list.

Structure, naming, and content reviews do not request extension reloads.
Structure and naming loops explicitly use static review in both review and fix
turns. Fix verification can use relevant builds, type checks, and automated checks
that do not launch or drive a browser or application UI. Live browser testing,
Computer Use, and extension reloads require an explicit request for that task.

With **Reload browser extension** enabled, Codex uses Chrome DevTools to reload
Chrome extensions before live testing and again after building fixes. It checks
that the reload succeeded, refreshes affected test pages, and reopens extension
UI as needed. The `chrome-devtools` MCP server must be configured in Codex with
extension tools enabled; Chrome may ask you to approve the connection. If the
tools are unavailable or a reload fails, the loop waits for a manual reload and
shows the reason and steps. The chat reports `# Extension reload required` with a
`## Summary` containing the browser, extension, steps, and reason; Dashboard shows
**Waiting for extension reload**. Select **Extension reloaded — continue** after
reloading to resume the same chat and round, preserving unfinished fixes. Final
review and commit checks still run before the round can complete.

Each round starts a read-only review in a new chat on the current branch and
checkout. Qualifying findings trigger a separate fix-and-commit follow-up in that
chat. Excluded priorities remain visible but are not fixed. Findings are verified
before fixes; invalid findings are withdrawn. All-withdrawn and no-qualifying-finding
reviews finish without a commit. A clean review is an assessment, not proof that
all defects are absent. Multiple projects can run loops, with one active loop per
project and checkout. Avoid other edits in that checkout while a loop runs.

The dashboard counts the finding sections in a review automatically. Review responses
use a completion or blocked heading, a summary, and one section per finding, without
a separate findings total. If an existing chat used the previous format, ask it to
return the same report with the `Findings: N` line removed, then select **Resume**.
Malformed reports show the specific format problem and how to correct it.

**Remote push** defaults to keeping commits local. When enabled, verified fix
commits are pushed after each round to the upstream branch, or the current branch
on `origin` or the sole remote. New branch pushes record an upstream. Pushes are
never forced. A push failure blocks the loop; Resume retries that verified commit
without another fix prompt.

**Pause after round** finishes the current round. **Stop loop** prevents new work
and interrupts its running turn. While **Stopping**, its checkout stays reserved;
interruption failures remain visible and retry automatically, or use **Retry Stop**.
If its chat was deleted, Stop confirms its absence in the local chat catalog
and releases the checkout. Catalog failures retain the checkout for another retry.
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
Finished loops move to history. History controls delete saved loops and their
round records; the review chats remain available.

## Compatibility and diagnostics

Codex updates can change the private contracts used by this unofficial integration.
Dashboard checks compatibility after version changes. Warning icons and Diagnostics
identify failed checks; blocking drift prevents remounting. Diagnostics also shows
versions, refresh state, loaded chats, renderer targets, and copyable details.
**Disable dashboard integration** immediately removes all injected controls; a normal
Codex restart also removes them. The signed Codex application bundle is never modified.
