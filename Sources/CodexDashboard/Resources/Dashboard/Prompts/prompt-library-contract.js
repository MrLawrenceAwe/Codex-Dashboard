const promptLibraryContract = (() => {
  function normalizeSection(value) {
    return String(value || '').trim() || PROMPT_LIBRARY_SCHEMA.defaultSection;
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

  function scopeKey(scope) {
    const normalized = normalizeScope(scope);
    return normalized.type === 'project' ? `project:${normalized.projectPath}` : 'global';
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
      && prompt.id.length > 0
      && typeof prompt.name === 'string'
      && prompt.name.length > 0
      && typeof prompt.content === 'string'
      && prompt.content.length > 0
      && (prompt.section === undefined || typeof prompt.section === 'string')
      && isValidScope(prompt.scope)
      && (prompt.preset === undefined || composerPresets.isValid(prompt.preset))
      && (prompt.usePreset === undefined || typeof prompt.usePreset === 'boolean');
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
      && library.version === PROMPT_LIBRARY_SCHEMA.version;
  }

  function normalizePrompts(storedPrompts) {
    if (!Array.isArray(storedPrompts)) return [];
    return storedPrompts.filter(isValidPrompt).map((prompt) => {
      const { preset: storedPreset, usePreset: storedUsePreset, ...storedPrompt } = prompt;
      const preset = composerPresets.normalize(storedPreset);
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
    defaultSection: PROMPT_LIBRARY_SCHEMA.defaultSection,
    isValidLibrary,
    normalizePrompts,
    normalizeScope,
    scopeKey,
    normalizeSection,
    normalizeSections,
    version: PROMPT_LIBRARY_SCHEMA.version,
  };
})();
