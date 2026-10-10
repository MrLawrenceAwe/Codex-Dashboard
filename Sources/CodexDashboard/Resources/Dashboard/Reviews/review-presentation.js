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

  function updatedAtLabel(timestamp) {
    if (typeof timestamp !== 'number' || !Number.isFinite(timestamp)) return 'Not recorded';
    const date = new Date(timestamp * 1000);
    if (Number.isNaN(date.getTime())) return 'Not recorded';
    return new Intl.DateTimeFormat(undefined, { dateStyle: 'medium', timeStyle: 'short' }).format(date);
  }

  return { reviewTypeLabel, roundStatus, updatedAtLabel };
})();
