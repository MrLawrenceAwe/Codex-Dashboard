const reviewPresentation = (() => {
  function reviewTypeLabel(reviewType, reviewTypes) {
    return reviewTypes.find(type => type.id === reviewType)?.label || reviewType || '';
  }

  function promptContextLabel(context) {
    switch (context?.kind) {
      case 'general': return 'General project';
      case 'personal': return 'Personal project';
      case 'savedContext': return `Saved context: ${context.context}`;
      default: return 'Project context not recorded';
    }
  }

  function roundStatus(round, pushToRemote, workspaceKind) {
    let label;
    switch (round.result?.outcome) {
      case 'clean':
        label = round.review?.findings?.length ? 'No qualifying findings' : 'No findings';
        break;
      case 'fixed':
        label = workspaceKind === 'folder' ? 'Fixes applied & verified' : pushToRemote ? 'Fixes committed & pushed' : 'Fixes committed';
        break;
      case 'withdrawn':
        label = 'Findings withdrawn';
        break;
      case 'blocked':
        label = 'Blocked';
        break;
      default:
        if (round.fixRequested) label = 'Addressing findings';
        else if (round.review) label = `${round.review.findings.length} findings`;
        else label = 'Reviewing';
    }
    return round.result?.fixCommit ? `${label} · ${round.result.fixCommit.slice(0, 8)}` : label;
  }

  function roundStages(loop) {
    const round = loop.rounds.at(-1);
    const outcome = round?.result?.outcome;
    const current = round?.fixVerification || round?.fixRequested || round?.review?.outcome === 'reviewed' ? 1 : 0;
    const labels = ['Review', loop.workspaceKind === 'folder' ? 'Fix & verify' : 'Fix & commit'];
    const states = ['pending', 'pending'];
    if (outcome && outcome !== 'blocked') {
      states[0] = 'done';
      states[1] = outcome === 'clean' ? 'skipped' : 'done';
    } else {
      for (let index = 0; index < current; index++) states[index] = 'done';
      states[current] = ({ running: 'active', blocked: 'blocked', awaitingExtensionReload: 'blocked',
        paused: 'paused', stopping: 'stopping', stopped: 'stopped', queued: 'waiting', waiting: 'waiting' })[loop.phase] || 'incomplete';
    }
    const descriptions = { pending: 'Up next', done: 'Done', skipped: 'Not needed',
      active: 'In progress', blocked: 'Needs attention', paused: 'Paused', stopping: 'Stopping',
      stopped: 'Stopped', waiting: 'Waiting', incomplete: 'Incomplete' };
    return labels.map((label, index) => {
      let description = descriptions[states[index]];
      if (index === 1 && states[index] === 'active' && round?.fixVerification) {
        description = 'Reverifying fixes';
      } else if (index === 1 && outcome === 'withdrawn') {
        description = loop.workspaceKind === 'folder' ? 'Findings withdrawn; files unchanged' : 'Findings withdrawn; no commit needed';
      }
      return { label, state: states[index], description };
    });
  }

  function phaseLabel(loop) {
    if (loop.phase === 'awaitingExtensionReload') return 'Waiting for extension reload';
    return loop.phase === 'limitReached' ? 'Round limit reached' : loop.phase.charAt(0).toUpperCase() + loop.phase.slice(1);
  }

  function priorityLabel(priority) {
    return priority ? (priority === 'P0' ? 'P0' : `P0–${priority}`) : '';
  }

  function modelSelectionLabel(label, selection, models) {
    if (!selection) return `${label}: Not recorded`;
    const name = models.find(model => model.modelID === selection.modelID)?.displayName || selection.modelID;
    const effort = selection.reasoningEffort ? ` · ${composerPresets.reasoningLabel(selection.reasoningEffort)}` : '';
    return `${label}: ${name}${effort}`;
  }

  function settingsLabels(loop, models, reviewTypes) {
    return [
      reviewTypeLabel(loop.reviewType, reviewTypes),
      promptContextLabel(loop.promptContext),
      ...(loop.priorityLimit ? [priorityLabel(loop.priorityLimit)] : []),
      ...(loop.preserveUICopy ? ['UI copy unchanged'] : []),
      ...(loop.liveTesting ? ['Live testing enabled', `Mute test playback: ${loop.muteTestPlayback ? 'On' : 'Off'}`] : []),
      ...(loop.reloadExtensionBeforeTesting ? ['Extension reload enabled'] : []),
      loop.speed === 'fast' ? 'Fast' : 'Standard',
      loop.workspaceKind === 'folder' ? 'Save and verify folder changes'
        : loop.pushToRemote ? 'Push fixes to remote' : 'Keep commits local',
      modelSelectionLabel('Review', loop.reviewSelection, models),
      modelSelectionLabel('Fix', loop.fixSelection, models),
    ];
  }

  function controls(loop, retained) {
    const stop = { action: 'stop', label: 'Stop loop' };
    if (loop.phase === 'queued') return [{ action: 'stop', label: 'Cancel queued loop' }];
    if (loop.phase === 'stopping') return [{ action: 'stop', label: 'Retry Stop' }];
    if (loop.isFinished) return retained ? [{ clear: loop.id, label: 'Move to history' }] : [];
    if (loop.phase === 'awaitingExtensionReload') {
      return [{ action: 'resume', label: 'Extension reloaded — continue' }, stop];
    }
    if (['paused', 'blocked'].includes(loop.phase)) return [{ action: 'resume', label: 'Resume' }, stop];
    return [{ action: 'pause', disabled: !!loop.pauseRequested,
      label: loop.pauseRequested ? 'Pausing after round…' : loop.phase === 'running' ? 'Pause after round' : 'Pause' }, stop];
  }

  function metrics(loop) {
    const latest = loop.rounds.at(-1);
    return {
      roundLabel: latest ? `Round ${latest.number}` : 'First round',
      findings: latest?.review ? latest.review.findings.length : '—',
      addressed: loop.rounds.reduce((total, round) => total + (round.result?.outcome === 'fixed' ? round.result.addressedFindingCount || 0 : 0), 0),
      commits: new Set(loop.rounds.filter(round => round.result?.outcome === 'fixed' && round.result.fixCommit).map(round => round.result.fixCommit)).size,
    };
  }

  function updatedAtLabel(timestamp) {
    if (typeof timestamp !== 'number' || !Number.isFinite(timestamp)) return 'Not recorded';
    const date = new Date(timestamp * 1000);
    if (Number.isNaN(date.getTime())) return 'Not recorded';
    return new Intl.DateTimeFormat(undefined, { dateStyle: 'medium', timeStyle: 'short' }).format(date);
  }

  return { reviewTypeLabel, promptContextLabel, roundStatus, roundStages, phaseLabel, priorityLabel, settingsLabels, controls, metrics, updatedAtLabel };
})();
