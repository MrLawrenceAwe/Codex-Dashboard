const reviewPresentation = (() => {
  function reviewTypeLabel(reviewType, reviewTypes) {
    return reviewTypes.find(type => type.id === reviewType)?.label || reviewType || '';
  }

  function roundStatus(round, pushToRemote) {
    let label;
    switch (round.result?.outcome) {
      case 'clean':
        label = round.review?.findings?.length ? 'No qualifying findings' : 'No findings';
        break;
      case 'fixed':
        label = pushToRemote ? 'Fixes committed & pushed' : 'Fixes committed';
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
    return round.result?.commit ? `${label} · ${round.result.commit.slice(0, 8)}` : label;
  }

  function roundStages(loop) {
    const round = loop.rounds.at(-1);
    const outcome = round?.result?.outcome;
    const current = round?.fixVerification ? 2 : round?.fixRequested || round?.review?.outcome === 'reviewed' ? 1 : 0;
    const labels = ['Review', 'Fix & commit', 'Verify'];
    const states = ['pending', 'pending', 'pending'];
    if (outcome && outcome !== 'blocked') {
      states[0] = 'done';
      states[1] = outcome === 'clean' ? 'skipped' : 'done';
      states[2] = round.result.verifiedCommit ? 'done' : outcome === 'fixed' ? 'unrecorded' : 'skipped';
    } else {
      for (let index = 0; index < current; index++) states[index] = 'done';
      states[current] = ({ running: 'active', blocked: 'blocked', awaitingExtensionReload: 'blocked',
        paused: 'paused', stopping: 'stopping', stopped: 'stopped', waiting: 'waiting' })[loop.phase] || 'incomplete';
    }
    const descriptions = { pending: 'Up next', done: 'Done', skipped: 'Not needed', unrecorded: 'Not recorded',
      active: 'In progress', blocked: 'Needs attention', paused: 'Paused', stopping: 'Stopping',
      stopped: 'Stopped', waiting: 'Waiting', incomplete: 'Incomplete' };
    return labels.map((label, index) => ({ label, state: states[index], description: descriptions[states[index]] }));
  }

  function updatedAtLabel(timestamp) {
    if (typeof timestamp !== 'number' || !Number.isFinite(timestamp)) return 'Not recorded';
    const date = new Date(timestamp * 1000);
    if (Number.isNaN(date.getTime())) return 'Not recorded';
    return new Intl.DateTimeFormat(undefined, { dateStyle: 'medium', timeStyle: 'short' }).format(date);
  }

  return { reviewTypeLabel, roundStatus, roundStages, updatedAtLabel };
})();
