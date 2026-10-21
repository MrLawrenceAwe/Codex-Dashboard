const reviewPresentation = (() => {
  function reviewTypeLabel(reviewType, reviewTypes) {
    return reviewTypes.find(type => type.id === reviewType)?.label || reviewType || '';
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
        paused: 'paused', stopping: 'stopping', stopped: 'stopped', waiting: 'waiting' })[loop.phase] || 'incomplete';
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

  function updatedAtLabel(timestamp) {
    if (typeof timestamp !== 'number' || !Number.isFinite(timestamp)) return 'Not recorded';
    const date = new Date(timestamp * 1000);
    if (Number.isNaN(date.getTime())) return 'Not recorded';
    return new Intl.DateTimeFormat(undefined, { dateStyle: 'medium', timeStyle: 'short' }).format(date);
  }

  return { reviewTypeLabel, roundStatus, roundStages, updatedAtLabel };
})();
