const presetOptions = (() => {
  const models = [
    ['gpt-6-astra', 'GPT-6 Astra'],
    ['gpt-6-sol', 'GPT-6 Sol'],
    ['gpt-6-luna', 'GPT-6 Luna'],
    ['gpt-5.6-sol', 'GPT-5.6 Sol'],
    ['gpt-5.6-terra', 'GPT-5.6 Terra'],
    ['gpt-5.6-luna', 'GPT-5.6 Luna'],
    ['gpt-5.5', 'GPT-5.5'],
    ['gpt-5.4-mini', 'GPT-5.4 Mini'],
  ];
  const optionLabels = {
    light: 'Light',
    medium: 'Medium',
    high: 'High',
    xhigh: 'Extra High',
    max: 'Max',
    ultra: 'Ultra',
    standard: 'Standard',
    fast: 'Fast',
  };
  const reasoningEfforts = PROMPT_LIBRARY_SCHEMA.reasoningEfforts
    .map((value) => [value, optionLabels[value]]);
  const speeds = PROMPT_LIBRARY_SCHEMA.speeds.map((value) => [value, optionLabels[value]]);

  function label(options, value) {
    return options.find(([option]) => option === value)?.[1];
  }

  return { label, models, reasoningEfforts, speeds };
})();
