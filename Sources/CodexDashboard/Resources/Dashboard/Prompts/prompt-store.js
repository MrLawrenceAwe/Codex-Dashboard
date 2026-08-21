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

  function loadLibrary() {
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

  const library = loadLibrary();
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

    saveLibrary(nextPrompts = store.prompts, nextSections = store.sections) {
      return writeJSON(libraryStorageKey, {
        version: 3,
        prompts: nextPrompts,
        sections: normalizeSections(nextSections, nextPrompts),
      });
    },

    commitLibrary(nextPrompts = store.prompts, nextSections = store.sections) {
      const sections = normalizeSections(nextSections, nextPrompts);
      if (!store.saveLibrary(nextPrompts, sections)) return false;
      store.prompts = nextPrompts;
      store.sections = sections;
      return true;
    },

    saveCollapsedSections(sections = store.collapsedSections) {
      return writeJSON(collapsedSectionsStorageKey, [...sections]);
    },
  };
  return store;
})();
