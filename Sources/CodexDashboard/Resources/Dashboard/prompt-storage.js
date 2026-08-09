const promptStorageKey = 'codex-dashboard.saved-prompts';
const collapsedSectionsStorageKey = 'codex-dashboard.collapsed-prompt-sections';
const promptSectionsStorageKey = 'codex-dashboard.prompt-sections';
let prompts = loadPrompts();
let promptSections = loadPromptSections();
let promptMenuSyncQueued = false;
let promptDialogState = { mode: 'list' };
let draggedPromptID;
let collapsedSections = loadCollapsedSections();
let returnFocusElement;

function normalizePromptSection(value) {
  return String(value || '').trim() || 'General';
}

function readStoredJSON(key, fallback) {
  try {
    return JSON.parse(localStorage.getItem(key) || JSON.stringify(fallback));
  } catch (_) {
    return fallback;
  }
}

function writeStoredJSON(key, value, reportError = true) {
  try {
    localStorage.setItem(key, JSON.stringify(value));
    return true;
  } catch (_) {
    if (reportError) showPromptStorageError();
    return false;
  }
}

function loadPrompts() {
  const storedPrompts = readStoredJSON(promptStorageKey, []);
  if (!Array.isArray(storedPrompts)) return [];
  return storedPrompts.filter((prompt) => (
      prompt && typeof prompt.id === 'string'
        && typeof prompt.name === 'string'
        && typeof prompt.content === 'string'
  )).map((prompt) => ({
    ...prompt,
    section: normalizePromptSection(prompt.section),
  }));
}

function loadCollapsedSections() {
  const storedSections = readStoredJSON(collapsedSectionsStorageKey, []);
  return new Set(
    Array.isArray(storedSections)
      ? storedSections.filter((item) => typeof item === 'string')
      : [],
  );
}

function loadPromptSections() {
  const storedValue = readStoredJSON(promptSectionsStorageKey, []);
  const storedSections = Array.isArray(storedValue)
    ? storedValue.filter((item) => typeof item === 'string')
    : [];
  return [...new Set([
    ...storedSections.map(normalizePromptSection),
    ...prompts.map((prompt) => normalizePromptSection(prompt.section)),
  ])];
}

function showPromptStorageError() {
  const error = document.querySelector('[data-prompt-storage-error]');
  if (error) error.hidden = false;
}

function storePromptSections(sections = promptSections) {
  return writeStoredJSON(promptSectionsStorageKey, sections);
}

function resolvePromptSection(section) {
  const normalizedSection = normalizePromptSection(section);
  const existingSection = promptSections.find(
    (item) => item.localeCompare(normalizedSection, undefined, { sensitivity: 'accent' }) === 0,
  );
  return existingSection || normalizedSection;
}

function storeCollapsedSections(sections = collapsedSections) {
  return writeStoredJSON(collapsedSectionsStorageKey, [...sections], false);
}

function storePrompts(nextPrompts = prompts) {
  return writeStoredJSON(promptStorageKey, nextPrompts);
}
