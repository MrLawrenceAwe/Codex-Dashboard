const reviewPresentation = (() => {
  function reviewTypeLabel(reviewType, reviewTypes) {
    return reviewTypes.find(type => type.id === reviewType)?.label || reviewType || '';
  }

  function updatedAtLabel(timestamp) {
    if (typeof timestamp !== 'number' || !Number.isFinite(timestamp)) return 'Not recorded';
    const date = new Date(timestamp * 1000);
    if (Number.isNaN(date.getTime())) return 'Not recorded';
    return new Intl.DateTimeFormat(undefined, { dateStyle: 'medium', timeStyle: 'short' }).format(date);
  }

  return { reviewTypeLabel, updatedAtLabel };
})();
