# Review-loop migration history

For the current saved format and data-preservation rules, see
[Storage migrations](development.md#storage-migrations). This reference records
the earlier formats handled by `ReviewLoopDocumentMigration`.

Review-loop version 17 adds `preserveUICopy` for structure reviews. Migration defaults
the field to `false` when absent, preserving the earlier behaviour of allowing UI
copy changes, and retains any saved value alongside the other settings and history.

Review-loop version 16 renames `checkoutRoot` to `workspaceRoot` for Git and ordinary-folder
loops. Migration preserves the root and reservation alongside all saved settings and
round history; current documents write only `workspaceRoot`.

Review-loop version 15 separates optional `fixCommit` from `verifiedRevision`.
Only committed fixes have a `fixCommit`; clean, withdrawn, and folder rounds do not.
Migration preserves old fix commits and unchanged HEAD revisions from the former
`commit` field, retaining any separately verified revision already recorded.

Review-loop version 14 adds ordinary-folder checkpoints and persists the workspace
kind once selected. Shared checkpoint fields use `baseRevision`, `expectedRevision`,
`targetRevision`, and `verifiedRevision`; Git fix IDs remain separate from these
checkpoint revisions. Migration renames earlier checkpoint fields and marks previously
started loops as Git loops, preserving their history and pending verification.
Previously unstarted loops retain automatic mode detection so paused non-Git projects
can resume. Fingerprints are change identities, not stored copies of project files.

Review-loop version 13 separates the names of two existing continuation states:
`allowsFollowUpTurns` permits reconciliation of additional chat turns, while
`extensionReloadContinuationPending` records a confirmed reload awaiting continuation
submission. Migration maps the former `continuationRequested` and
`reloadContinuationRequested` fields without losing pending requests or round history.
Old names are confined to the migration boundary and legacy fixtures.

Review-loop version 12 renames the saved verification target from `commit` to
`targetCommit`, preserving pending verification and round history. Version 14 moves
this checkpoint to `targetRevision`. Version 15 renames the original Git fix's
result field to `fixCommit`.

Review-loop version 11 renames `muteMedia` to `muteTestPlayback` at the storage
boundary, preserving saved preferences and round history. Current actions, snapshots,
and saved documents use `muteTestPlayback` and `setMuteTestPlayback`.

Review-loop version 10 renames `focus` to `reviewType` when loading earlier saved
loops, preserving their settings and round history. Current actions, snapshots,
and saved documents use only `reviewType`.

Version 9 introduced the playback preference as `muteMedia`, defaulting existing
loops to off while preserving other version 8 fields. See the
[usage guide](usage.md#review-loops) for playback scope and controls.

Version 8 adds the durable `stopping` phase so checkout reservations
survive interruption failures and restarts. Version 7 renames `isExtension` to `reloadExtensionBeforeTesting`, preserving the saved reload preference.
Version 6 renames saved round-result `findings` to
`addressedFindingCount`, preserving existing history at the migration boundary.
Version 3 renames the `naming` review type to `organisationAndNaming`.
Version 1 and older unversioned single-loop/array documents also migrate remote
push, prompt context, and model selection fields at the file-store boundary.
The coordinator writes the current version after a successful load.

