const presetOptions = (() => {
  const models = [
    ['gpt-5.6-sol', '5.6 Sol'],
    ['gpt-5.6-terra', '5.6 Terra'],
    ['gpt-5.6-luna', '5.6 Luna'],
    ['gpt-5.5', '5.5'],
    ['gpt-5.4', '5.4'],
    ['gpt-5.4-mini', '5.4 Mini'],
  ];
  const reasoningEfforts = [
    ['light', 'Light'],
    ['medium', 'Medium'],
    ['high', 'High'],
    ['xhigh', 'Extra High'],
  ];
  const speeds = [['standard', 'Standard'], ['fast', 'Fast']];

  function label(options, value) {
    return options.find(([option]) => option === value)?.[1];
  }

  return { label, models, reasoningEfforts, speeds };
})();
