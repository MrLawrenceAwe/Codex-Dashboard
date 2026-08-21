const promptLibraryContract = (() => {
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
      && (prompt.scope === undefined || isValidScope(prompt.scope));
  }

  function hasValidContents(library) {
    if (!library || typeof library !== 'object' || Array.isArray(library)) return false;
    if (!Array.isArray(library.prompts) || !Array.isArray(library.sections)) return false;
    if (!library.prompts.every(isValidPrompt)) return false;
    if (!library.sections.every((section) => typeof section === 'string')) return false;
    return new Set(library.prompts.map((prompt) => prompt.id)).size === library.prompts.length;
  }

  function isValidLibrary(library) {
    return hasValidContents(library) && (library.version === undefined || library.version === 2);
  }

  function isValidExport(payload) {
    if (!hasValidContents(payload)) return false;
    if (payload.version === 1) return true;
    return payload.version === 2 && payload.prompts.every((prompt) => isValidScope(prompt.scope));
  }

  function normalizePrompts(storedPrompts) {
    if (!Array.isArray(storedPrompts)) return [];
    return storedPrompts.filter(isValidPrompt).map((prompt) => ({
      ...prompt,
      section: normalizeSection(prompt.section),
      scope: normalizeScope(prompt.scope),
    }));
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
    normalizeScope,
    normalizeSection,
    normalizeSections,
  };
})();
