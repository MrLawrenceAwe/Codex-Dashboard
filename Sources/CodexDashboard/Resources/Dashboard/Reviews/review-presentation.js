const reviewPresentation = (() => {
  function focusLabel(focus, reviewTypes) {
    return reviewTypes.find(type => type.id === focus)?.label || focus || '';
  }

  function reasoningLabel(value) {
    return value === 'xhigh' ? 'Extra high' : value.charAt(0).toUpperCase() + value.slice(1);
  }

  function updatedAtLabel(timestamp) {
    if (typeof timestamp !== 'number' || !Number.isFinite(timestamp)) return 'Not recorded';
    const date = new Date(timestamp * 1000);
    if (Number.isNaN(date.getTime())) return 'Not recorded';
    return new Intl.DateTimeFormat(undefined, { dateStyle: 'medium', timeStyle: 'short' }).format(date);
  }

  return { focusLabel, reasoningLabel, updatedAtLabel };
})();
