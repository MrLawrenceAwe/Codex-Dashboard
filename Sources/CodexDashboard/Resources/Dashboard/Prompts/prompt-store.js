const promptStore = (() => {
  const libraryStorageKey = 'codex-dashboard.prompt-library';
  const collapsedSectionsStorageKey = 'codex-dashboard.collapsed-prompt-sections';

  const {
    normalizePrompts,
    normalizePreset,
    normalizeScope,
    normalizeSection,
    normalizeSections,
  } = promptLibraryContract;

  function readJSON(key, fallback) {
    try {
      return JSON.parse(localStorage.getItem(key) || JSON.stringify(fallback));
    } catch (_) {
      return fallback;
    }
  }

  function writeJSON(key, value) {
    try {
      localStorage.setItem(key, JSON.stringify(value));
      return true;
    } catch (_) {
      return false;
    }
  }

  function loadLegacyLibrary() {
    const storedLibrary = readJSON(libraryStorageKey, null);
    if (!promptLibraryContract.isValidLibrary(storedLibrary)) {
      return { version: 3, prompts: [], sections: [] };
    }
    return {
      version: 3,
      prompts: normalizePrompts(storedLibrary.prompts),
      sections: normalizeSections(storedLibrary.sections, storedLibrary.prompts),
    };
  }

  const library = loadLegacyLibrary();
  const storedCollapsedSections = readJSON(collapsedSectionsStorageKey, []);
  const store = {
    prompts: library.prompts,
    sections: library.sections,
    collapsedSections: new Set(
      Array.isArray(storedCollapsedSections)
        ? storedCollapsedSections.filter((item) => typeof item === 'string')
        : [],
    ),

    normalizeSection,
    normalizePrompts,
    normalizePreset,
    normalizeScope,
    normalizeSections,

    resolveSection(section) {
      const normalizedSection = normalizeSection(section);
      return store.sections.find(
        (item) => item.localeCompare(normalizedSection, undefined, { sensitivity: 'accent' }) === 0,
      ) || normalizedSection;
    },

    commitLibrary(nextPrompts = store.prompts, nextSections = store.sections) {
      const sections = normalizeSections(nextSections, nextPrompts);
      store.prompts = nextPrompts;
      store.sections = sections;
      return true;
    },

    saveCollapsedSections(sections = store.collapsedSections) {
      return writeJSON(collapsedSectionsStorageKey, [...sections]);
    },

    exportLibrary() {
      return {
        version: 3,
        prompts: store.prompts,
        sections: normalizeSections(store.sections, store.prompts),
      };
    },

    applyLibrary(library) {
      if (!promptLibraryContract.isValidLibrary(library)) return false;
      store.prompts = normalizePrompts(library.prompts);
      store.sections = normalizeSections(library.sections, library.prompts);
      try { localStorage.removeItem(libraryStorageKey); } catch (_) {}
      return true;
    },
  };
  return store;
})();
