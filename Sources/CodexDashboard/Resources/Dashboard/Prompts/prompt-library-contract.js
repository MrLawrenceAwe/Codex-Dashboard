const promptLibraryContract = (() => {
  function normalizeSection(value) {
    return String(value || '').trim() || 'General';
  }

  function isValidPrompt(prompt) {
    return prompt && typeof prompt === 'object' && !Array.isArray(prompt)
      && typeof prompt.id === 'string'
      && typeof prompt.name === 'string'
      && typeof prompt.content === 'string'
      && (prompt.section === undefined || typeof prompt.section === 'string');
  }

  function isValidLibrary(library) {
    if (!library || typeof library !== 'object' || Array.isArray(library)) return false;
    if (!Array.isArray(library.prompts) || !Array.isArray(library.sections)) return false;
    if (!library.prompts.every(isValidPrompt)) return false;
    if (!library.sections.every((section) => typeof section === 'string')) return false;
    return new Set(library.prompts.map((prompt) => prompt.id)).size === library.prompts.length;
  }

  function isValidExport(payload) {
    return isValidLibrary(payload) && payload.version === 1;
  }

  function normalizePrompts(storedPrompts) {
    if (!Array.isArray(storedPrompts)) return [];
    return storedPrompts.filter(isValidPrompt).map((prompt) => ({
      ...prompt,
      section: normalizeSection(prompt.section),
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
    normalizeSection,
    normalizeSections,
  };
})();
