const promptStore = (() => {
  const libraryStorageKey = 'codex-dashboard.prompt-library';
  const pendingLibraryStorageKey = 'codex-dashboard.pending-prompt-library';
  const collapsedSectionsStorageKey = 'codex-dashboard.collapsed-prompt-sections';

  const {
    normalizePrompts,
    normalizePreset,
    normalizeScope,
    normalizeSection,
    normalizeSections,
  } = promptLibraryContract;
  const { version } = promptLibraryContract;

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
      return { version, prompts: [], sections: [] };
    }
    return {
      version,
      prompts: normalizePrompts(storedLibrary.prompts),
      sections: normalizeSections(storedLibrary.sections, storedLibrary.prompts),
    };
  }

  function normalizedLibrary(library) {
    if (!promptLibraryContract.isValidLibrary(library)) return null;
    return {
      version,
      prompts: normalizePrompts(library.prompts),
      sections: normalizeSections(library.sections, library.prompts),
    };
  }

  function pendingLibrary() {
    return normalizedLibrary(readJSON(pendingLibraryStorageKey, null));
  }

  function canonicalize(value) {
    if (Array.isArray(value)) return value.map(canonicalize);
    if (value && typeof value === 'object') {
      return Object.fromEntries(Object.keys(value).sort().map((key) => [key, canonicalize(value[key])]));
    }
    return value;
  }

  function librariesMatch(left, right) {
    return JSON.stringify(canonicalize(left)) === JSON.stringify(canonicalize(right));
  }

  const library = pendingLibrary() || loadLegacyLibrary();
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

    // Queue a renderer edit; PromptLibraryBridge persists and acknowledges it.
    stageLibraryUpdate(nextPrompts = store.prompts, nextSections = store.sections) {
      const sections = normalizeSections(nextSections, nextPrompts);
      const library = { version, prompts: nextPrompts, sections };
      if (!writeJSON(pendingLibraryStorageKey, library)) return false;
      store.prompts = nextPrompts;
      store.sections = sections;
      return true;
    },

    saveCollapsedSections(sections = store.collapsedSections) {
      return writeJSON(collapsedSectionsStorageKey, [...sections]);
    },

    exportLibrary() {
      return {
        version,
        prompts: store.prompts,
        sections: normalizeSections(store.sections, store.prompts),
      };
    },

    matchesLibrary(library) {
      const normalized = normalizedLibrary(library);
      return normalized ? librariesMatch(store.exportLibrary(), normalized) : false;
    },

    pendingLibrary,

    discardPendingLibrary() {
      try { localStorage.removeItem(pendingLibraryStorageKey); } catch (_) { return false; }
      return true;
    },

    acknowledgePendingLibrary(library) {
      const pending = pendingLibrary();
      if (!pending) return true;
      if (!librariesMatch(pending, library)) return false;
      try { localStorage.removeItem(pendingLibraryStorageKey); } catch (_) { return false; }
      return true;
    },

    applyLibrary(library) {
      if (!promptLibraryContract.isValidLibrary(library)) return false;
      if (!store.matchesLibrary(library)) {
        store.prompts = normalizePrompts(library.prompts);
        store.sections = normalizeSections(library.sections, library.prompts);
      }
      try { localStorage.removeItem(libraryStorageKey); } catch (_) {}
      return true;
    },
  };
  return store;
})();
