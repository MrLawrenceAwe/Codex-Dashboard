const composerPresets = (() => {
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
  const reasoningEfforts = COMPOSER_PRESET_SCHEMA.reasoningEfforts
    .map((value) => [value, optionLabels[value]]);
  const speeds = COMPOSER_PRESET_SCHEMA.speeds.map((value) => [value, optionLabels[value]]);

  function label(options, value) {
    return options.find(([option]) => option === value)?.[1];
  }

  function isValid(preset) {
    if (!preset || typeof preset !== 'object' || Array.isArray(preset)) return false;
    return (preset.model === undefined || (typeof preset.model === 'string' && Boolean(preset.model.trim())))
      && (preset.reasoningEffort === undefined || COMPOSER_PRESET_SCHEMA.reasoningEfforts.includes(preset.reasoningEffort))
      && (preset.speed === undefined || COMPOSER_PRESET_SCHEMA.speeds.includes(preset.speed));
  }

  function normalize(preset) {
    if (!isValid(preset)) return undefined;
    const normalized = {};
    if (preset.model) normalized.model = preset.model;
    if (preset.reasoningEffort) normalized.reasoningEffort = preset.reasoningEffort;
    if (preset.speed) normalized.speed = preset.speed;
    return Object.keys(normalized).length ? normalized : undefined;
  }

  function summary(preset) {
    if (!preset) return [];
    return [
      preset.model && (label(models, preset.model) || `Saved model · ${preset.model}`),
      label(reasoningEfforts, preset.reasoningEffort),
      label(speeds, preset.speed),
    ].filter(Boolean);
  }

  function selectOptions(options, selected) {
    const choices = selected && !options.some(([value]) => value === selected)
      ? [[selected, `Saved model · ${selected}`], ...options] : options;
    return choices.map(([value, optionLabel]) => (
      `<option value="${domUtils.escapeHTML(value)}"${value === selected ? ' selected' : ''}>${domUtils.escapeHTML(optionLabel)}</option>`
    )).join('');
  }

  return { defaults: COMPOSER_PRESET_SCHEMA.defaults, isValid, label, models, normalize, reasoningEfforts, selectOptions, speeds, summary };
})();
