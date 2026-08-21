const promptLibraryContract = (() => {
  const modelValues = new Set([
    'gpt-5.6-sol', 'gpt-5.6-terra', 'gpt-5.6-luna', 'gpt-5.5', 'gpt-5.4', 'gpt-5.4-mini',
  ]);
  const reasoningEffortValues = new Set(['low', 'medium', 'high', 'xhigh']);
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
      // A missing scope is the version-one storage contract and migrates to Global.
      && (prompt.scope === undefined || isValidScope(prompt.scope))
      && (prompt.preset === undefined || isValidPreset(prompt.preset));
  }

  function isValidPreset(preset) {
    if (!preset || typeof preset !== 'object' || Array.isArray(preset)) return false;
    return (preset.model === undefined || modelValues.has(preset.model))
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
    // Version 2 must validate until mount migrates it; rejecting it could restore an older backup
    // over newer user prompts before the prompt store gets a chance to upgrade the library.
    return hasValidContents(library)
      && (library.version === undefined || library.version === 2 || library.version === 3);
  }

  function isValidExport(payload) {
    if (!hasValidContents(payload)) return false;
    if (payload.version === 1) return true;
    if (payload.version === 2) return payload.prompts.every((prompt) => isValidScope(prompt.scope));
    return payload.version === 3
      && payload.prompts.every((prompt) => isValidScope(prompt.scope));
  }

  function normalizePrompts(storedPrompts) {
    if (!Array.isArray(storedPrompts)) return [];
    return storedPrompts.filter(isValidPrompt).map((prompt) => {
      const { preset: storedPreset, ...storedPrompt } = prompt;
      const preset = normalizePreset(storedPreset);
      return {
        ...storedPrompt,
        section: normalizeSection(prompt.section),
        scope: normalizeScope(prompt.scope),
        ...(preset ? { preset } : {}),
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
    isValidExport,
    isValidLibrary,
    normalizePrompts,
    normalizePreset,
    normalizeScope,
    normalizeSection,
    normalizeSections,
  };
})();
