const reviewPresentation = (() => {
  function focusLabel(focus, reviewTypes) {
    return reviewTypes.find(type => type.id === focus)?.label || focus || '';
  }

  function reasoningLabel(value) {
    return value === 'xhigh' ? 'Extra high' : value.charAt(0).toUpperCase() + value.slice(1);
  }

  return { focusLabel, reasoningLabel };
})();
