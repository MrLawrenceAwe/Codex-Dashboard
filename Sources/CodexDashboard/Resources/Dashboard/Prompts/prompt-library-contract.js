const promptLibraryContract = (() => {
  const reasoningEffortValues = new Set(['light', 'medium', 'high', 'xhigh']);
  const speedValues = new Set(['standard', 'fast']);

  function normalizeSection(value) {
    return String(value || '').trim() || 'General';
  }

  function normalizeScope(scope) {
    if (
      scope?.type === 'project'
        && typeof scope.projectPath === 'string'
        && scope.projectPath.trim()
    ) {
      return { type: 'project', projectPath: scope.projectPath.trim() };
    }
    return { type: 'global' };
  }

  function isValidScope(scope) {
    return scope?.type === 'global'
      || (
        scope?.type === 'project'
          && typeof scope.projectPath === 'string'
          && Boolean(scope.projectPath.trim())
      );
  }

  function isValidPrompt(prompt) {
    return prompt && typeof prompt === 'object' && !Array.isArray(prompt)
      && typeof prompt.id === 'string'
      && typeof prompt.name === 'string'
      && typeof prompt.content === 'string'
      && (prompt.section === undefined || typeof prompt.section === 'string')
      && isValidScope(prompt.scope)
      && (prompt.preset === undefined || isValidPreset(prompt.preset))
      && (prompt.usePreset === undefined || typeof prompt.usePreset === 'boolean');
  }

  function isValidPreset(preset) {
    if (!preset || typeof preset !== 'object' || Array.isArray(preset)) return false;
    return (preset.model === undefined || (typeof preset.model === 'string' && Boolean(preset.model.trim())))
      && (preset.reasoningEffort === undefined || reasoningEffortValues.has(preset.reasoningEffort))
      && (preset.speed === undefined || speedValues.has(preset.speed));
  }

  function normalizePreset(preset) {
    if (!isValidPreset(preset)) return undefined;
    const normalized = {};
    if (preset.model) normalized.model = preset.model;
    if (preset.reasoningEffort) normalized.reasoningEffort = preset.reasoningEffort;
    if (preset.speed) normalized.speed = preset.speed;
    return Object.keys(normalized).length ? normalized : undefined;
  }

  function hasValidContents(library) {
    if (!library || typeof library !== 'object' || Array.isArray(library)) return false;
    if (!Array.isArray(library.prompts) || !Array.isArray(library.sections)) return false;
    if (!library.prompts.every(isValidPrompt)) return false;
    if (!library.sections.every((section) => typeof section === 'string')) return false;
    return new Set(library.prompts.map((prompt) => prompt.id)).size === library.prompts.length;
  }

  function isValidLibrary(library) {
    return hasValidContents(library)
      && library.version === 3
      && library.prompts.every((prompt) => isValidScope(prompt.scope));
  }

  function normalizePrompts(storedPrompts) {
    if (!Array.isArray(storedPrompts)) return [];
    return storedPrompts.filter(isValidPrompt).map((prompt) => {
      const { preset: storedPreset, usePreset: storedUsePreset, ...storedPrompt } = prompt;
      const preset = normalizePreset(storedPreset);
      return {
        ...storedPrompt,
        section: normalizeSection(prompt.section),
        scope: normalizeScope(prompt.scope),
        ...(preset ? { preset } : {}),
        ...(preset && storedUsePreset === true ? { usePreset: true } : {}),
      };
    });
  }

  function normalizeSections(storedSections, storedPrompts) {
    const sections = Array.isArray(storedSections)
      ? storedSections.filter((item) => typeof item === 'string')
      : [];
    return [...new Set([
      ...sections.map(normalizeSection),
      ...storedPrompts.map((prompt) => normalizeSection(prompt.section)),
    ])];
  }

  return {
    isValidLibrary,
    normalizePrompts,
    normalizePreset,
    normalizeScope,
    normalizeSection,
    normalizeSections,
  };
})();
