const promptStore = (() => {
  const libraryStorageKey = 'codex-dashboard.prompt-library';
  const pendingLibraryStorageKey = 'codex-dashboard.pending-prompt-library';
  const pendingChangePrefix = 'codex-dashboard.pending-prompt-change.';
  const collapsedSectionsStorageKey = 'codex-dashboard.collapsed-prompt-sections';
  let lastChangeMillis = 0;

  const {
    normalizePrompts,
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

  function normalizedLibrary(library) {
    if (!promptLibraryContract.isValidLibrary(library)) return null;
    return {
      version,
      prompts: normalizePrompts(library.prompts),
      sections: normalizeSections(library.sections, library.prompts),
    };
  }

  // Upgrade saved caches and durable pending edits before validating current data.
  function readStoredLibrary(value) {
    if (value?.version === 3 && Array.isArray(value.prompts)) {
      value = {
        ...value,
        version,
        prompts: value.prompts.map(prompt => prompt?.preset?.reasoningEffort === 'light'
          ? { ...prompt, preset: { ...prompt.preset, reasoningEffort: 'low' } } : prompt),
      };
    }
    return normalizedLibrary(value);
  }

  function canonicalize(value) {
    if (Array.isArray(value)) return value.map(canonicalize);
    if (value && typeof value === 'object') {
      return Object.fromEntries(Object.keys(value).sort().map((key) => [key, canonicalize(value[key])]));
    }
    return value;
  }

  function jsonValuesEqual(left, right) {
    return JSON.stringify(canonicalize(left)) === JSON.stringify(canonicalize(right));
  }

  function loadCachedLibrary() {
    return readStoredLibrary(readJSON(libraryStorageKey, null))
      || { version, prompts: [], sections: [] };
  }

  function pendingChangeKeys() {
    const keys = [];
    try {
      for (let index = 0; index < (localStorage.length || 0); index += 1) {
        const key = localStorage.key(index);
        if (key?.startsWith(pendingChangePrefix)) keys.push(key);
      }
    } catch (_) { return []; }
    return keys.sort();
  }

  function mergeLibrary(base, desired, current) {
    const basePrompts = new Map(base.prompts.map(prompt => [prompt.id, prompt]));
    const desiredPrompts = new Map(desired.prompts.map(prompt => [prompt.id, prompt]));
    const removed = new Set(base.prompts.filter(prompt => !desiredPrompts.has(prompt.id)).map(prompt => prompt.id));
    const changed = new Map(desired.prompts.filter(prompt =>
      !basePrompts.has(prompt.id) || !jsonValuesEqual(basePrompts.get(prompt.id), prompt))
      .map(prompt => [prompt.id, prompt]));
    const prompts = current.prompts.filter(prompt => !removed.has(prompt.id))
      .map(prompt => {
        const local = changed.get(prompt.id);
        if (!local) return prompt;
        const previous = basePrompts.get(prompt.id);
        if (!previous) return local;
        const merged = { ...prompt };
        for (const key of new Set([...Object.keys(previous), ...Object.keys(local)])) {
          if (jsonValuesEqual(previous[key], local[key])) continue;
          if (Object.prototype.hasOwnProperty.call(local, key)) merged[key] = local[key];
          else delete merged[key];
        }
        return merged;
      });
    const present = new Set(prompts.map(prompt => prompt.id));
    // A stale edit must not recreate a prompt deleted by another window.
    prompts.push(...desired.prompts.filter(prompt => !basePrompts.has(prompt.id) && !present.has(prompt.id)));
    if (!jsonValuesEqual(base.prompts.map(prompt => prompt.id), desired.prompts.map(prompt => prompt.id))) {
      const order = new Map(desired.prompts.map((prompt, index) => [prompt.id, index]));
      prompts.sort((left, right) => (order.get(left.id) ?? Infinity) - (order.get(right.id) ?? Infinity));
    }

    const removedSections = new Set(base.sections.filter(section => !desired.sections.includes(section)));
    const concurrentlyDeletedSections = new Set(base.sections.filter(section => !current.sections.includes(section)));
    const sections = current.sections.filter(section => !removedSections.has(section));
    sections.push(...desired.sections.filter(section => !base.sections.includes(section) && !sections.includes(section)));
    if (!jsonValuesEqual(base.sections, desired.sections)) {
      const order = new Map(desired.sections.map((section, index) => [section, index]));
      sections.sort((left, right) => (order.get(left) ?? Infinity) - (order.get(right) ?? Infinity));
    }
    // Keep new or moved prompts without restoring their deleted destination section.
    const survivingPrompts = prompts.map(prompt => concurrentlyDeletedSections.has(normalizeSection(prompt.section))
      ? { ...prompt, section: promptLibraryContract.defaultSection } : prompt);
    return normalizedLibrary({ version, prompts: survivingPrompts, sections });
  }

  function pendingLibrary(keys = pendingChangeKeys()) {
    const legacy = readStoredLibrary(readJSON(pendingLibraryStorageKey, null));
    if (!legacy && !keys.length) return null;
    let current = legacy || loadCachedLibrary();
    for (const key of keys) {
      const change = readJSON(key, null);
      const base = readStoredLibrary(change?.base);
      const desired = readStoredLibrary(change?.desired);
      if (base && desired) current = mergeLibrary(base, desired, current);
    }
    return current;
  }

  const library = pendingLibrary() || loadCachedLibrary();
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
    normalizeScope,

    resolveSection(section) {
      const normalizedSection = normalizeSection(section);
      return store.sections.find(
        (item) => item.localeCompare(normalizedSection, undefined, { sensitivity: 'accent' }) === 0,
      ) || normalizedSection;
    },

    createSection(name) {
      const section = store.resolveSection(name);
      const sections = store.sections.includes(section)
        ? store.sections : [...store.sections, section];
      if (!store.stageLibraryUpdate(store.prompts, sections)) return null;
      store.collapsedSections.delete(section);
      store.saveCollapsedSections();
      return section;
    },

    renameSection(source, name) {
      const destination = normalizeSection(name);
      const conflict = store.sections.some((section) => section !== source
        && section.localeCompare(destination, undefined, { sensitivity: 'accent' }) === 0);
      if (conflict) return 'conflict';
      const prompts = store.prompts.map((prompt) => normalizeSection(prompt.section) === source
        ? { ...prompt, section: destination } : prompt);
      const sections = store.sections.map((section) => section === source ? destination : section);
      if (!store.stageLibraryUpdate(prompts, sections)) return 'failed';
      store.collapsedSections.delete(source);
      store.saveCollapsedSections();
      return 'saved';
    },

    deleteSection(section) {
      const prompts = store.prompts.map((prompt) => normalizeSection(prompt.section) === section
        ? { ...prompt, section: promptLibraryContract.defaultSection } : prompt);
      const sections = store.sections.filter((item) => item !== section);
      if (!store.stageLibraryUpdate(prompts, sections)) return false;
      store.collapsedSections.delete(section);
      store.saveCollapsedSections();
      return true;
    },

    toggleSection(section) {
      if (store.collapsedSections.has(section)) store.collapsedSections.delete(section);
      else store.collapsedSections.add(section);
      store.saveCollapsedSections();
    },

    // Queue a renderer edit; PromptLibraryBridge persists and acknowledges it.
    stageLibraryUpdate(nextPrompts = store.prompts, nextSections = store.sections) {
      const sections = normalizeSections(nextSections, nextPrompts);
      const desired = { version, prompts: nextPrompts, sections };
      const base = store.exportLibrary();
      lastChangeMillis = Math.max(Date.now(), lastChangeMillis + 1);
      const uniqueID = globalThis.crypto?.randomUUID?.() || `${performance.now()}-${Math.random()}`;
      const key = `${pendingChangePrefix}${String(lastChangeMillis).padStart(13, '0')}.${uniqueID}`;
      if (!writeJSON(key, { base, desired })) return false;
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
      return normalized ? jsonValuesEqual(store.exportLibrary(), normalized) : false;
    },

    pendingLibrary,

    discardPendingLibrary() {
      try {
        for (const key of pendingChangeKeys()) localStorage.removeItem(key);
        localStorage.removeItem(pendingLibraryStorageKey);
      } catch (_) { return false; }
      return true;
    },

    acknowledgePendingLibrary(library) {
      const keys = pendingChangeKeys();
      const pending = pendingLibrary(keys);
      if (!pending) return true;
      // A new edit may have arrived while native storage was being written.
      // Leave it queued for the next synchronization.
      if (!jsonValuesEqual(pending, library)) return true;
      try {
        for (const key of keys) localStorage.removeItem(key);
        localStorage.removeItem(pendingLibraryStorageKey);
      } catch (_) { return false; }
      return true;
    },

    refreshFromSharedStorage() {
      const library = pendingLibrary() || loadCachedLibrary();
      if (store.matchesLibrary(library)) return false;
      store.prompts = library.prompts;
      store.sections = library.sections;
      return true;
    },

    isSharedStorageKey(key) {
      return key === libraryStorageKey || key === pendingLibraryStorageKey
        || key?.startsWith(pendingChangePrefix);
    },

    applyLibrary(library) {
      if (!promptLibraryContract.isValidLibrary(library)) return false;
      const queued = pendingLibrary();
      if (!writeJSON(libraryStorageKey, normalizedLibrary(library)) && queued) return false;
      const current = pendingLibrary() || normalizedLibrary(library);
      if (!store.matchesLibrary(current)) {
        store.prompts = current.prompts;
        store.sections = current.sections;
      }
      return true;
    },
  };
  return store;
})();
