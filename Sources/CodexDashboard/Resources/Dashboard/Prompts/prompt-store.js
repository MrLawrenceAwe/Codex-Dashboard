const promptStore = (() => {
  const libraryStorageKey = 'codex-dashboard.prompt-library';
  const legacyPromptStorageKey = 'codex-dashboard.saved-prompts';
  const collapsedSectionsStorageKey = 'codex-dashboard.collapsed-prompt-sections';
  const legacySectionsStorageKey = 'codex-dashboard.prompt-sections';

  const {
    normalizePrompts,
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
    if (storedLibrary && typeof storedLibrary === 'object') {
      const prompts = normalizePrompts(storedLibrary.prompts);
      const migratedLibrary = {
        version: 2,
        prompts,
        sections: normalizeSections(storedLibrary.sections, prompts),
      };
      if (storedLibrary.version !== 2 || storedLibrary.prompts?.some((prompt) => !prompt.scope)) {
        writeJSON(libraryStorageKey, migratedLibrary);
      }
      return migratedLibrary;
    }

    // Retained to prevent users of the previous storage contract from losing prompts.
    const legacyPrompts = normalizePrompts(readJSON(legacyPromptStorageKey, []));
    const migratedLibrary = {
      version: 2,
      prompts: legacyPrompts,
      sections: normalizeSections(readJSON(legacySectionsStorageKey, []), legacyPrompts),
    };
    writeJSON(libraryStorageKey, migratedLibrary);
    return migratedLibrary;
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
        version: 2,
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
