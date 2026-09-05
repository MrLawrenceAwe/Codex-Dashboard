const promptLibrary = (() => {
  const dialogOwner = Symbol('codex-dashboard.prompt-dialog-owner');
  const insertionGuard = Symbol.for('codex-dashboard.prompt-insertion-guard');
  let dialogState = { mode: 'list' };
  let returnFocusElement;
  let searchTerm = '';
  let capturedSelectionText = '';
  let composerProject;

  function showStorageError(message) {
    const error = document.querySelector('[data-prompt-storage-error]');
    if (error) {
      if (message) error.textContent = message;
      error.hidden = false;
    }
  }

  function stageLibraryUpdate(nextPrompts = promptStore.prompts, nextSections = promptStore.sections) {
    if (promptStore.stageLibraryUpdate(nextPrompts, nextSections)) return true;
    showStorageError();
    return false;
  }


  const promptInteractionEventTypes = [
  'pointerdown', 'mousedown', 'click', 'keydown', 'input', 'search', 'change', 'submit',
  'dragstart', 'dragover', 'dragleave', 'drop', 'dragend',
];

  function renderDialog({ searchSelection } = {}) {
    promptLibraryView.render({
      dialogState,
      composerProject,
      searchTerm,
      searchSelection,
    });
  }

function presentDialog() {
  const dialog = promptLibraryDialog.create(dialogOwner);
  document.body.append(dialog);
  renderDialog();
}

function hideDialog() {
  document.getElementById(dashboardElements.elementIDs.promptDialog)?.remove();
}

function restoreDialog(message) {
  presentDialog();
  showStorageError(message);
}

function openLibrary() {
  const composer = codexUIContracts.composer(dashboardElements.elementIDs.promptDialog);
  if (composer instanceof HTMLTextAreaElement || composer instanceof HTMLInputElement) {
    const start = composer.selectionStart ?? 0;
    const end = composer.selectionEnd ?? start;
    capturedSelectionText = composer.value.slice(start, end);
  } else {
    const selection = window.getSelection();
    capturedSelectionText = selection?.rangeCount && composer?.contains(selection.anchorNode)
      ? selection.toString()
      : '';
  }
  hideDialog();
  returnFocusElement = document.activeElement instanceof HTMLElement
    ? document.activeElement
    : undefined;
  dialogState = { mode: 'list' };
  searchTerm = '';
  composerProject = taskDashboard.resolveComposerProject();
  presentDialog();
}

function expandedPromptContent(content, clipboardText = '') {
  return content
    .replaceAll('{{selection}}', capturedSelectionText)
    .replaceAll('{{clipboard}}', clipboardText);
}

function closeLibrary({ restoreFocus = true } = {}) {
  dialogState = { mode: 'list' };
  document.getElementById(dashboardElements.elementIDs.promptDialog)?.remove();
  const returnFocus = returnFocusElement;
  returnFocusElement = undefined;
  if (restoreFocus && returnFocus?.isConnected) returnFocus.focus();
}

function savePrompt(form) {
  const values = new FormData(form);
  const name = String(values.get('name') || '').trim();
  const content = String(values.get('content') || '').trim();
  if (!name || !content) return;
  const section = promptStore.resolveSection(values.get('section'));
  const scope = values.get('scope') === 'project' && composerProject
    ? { type: 'project', projectPath: composerProject.path }
    : { type: 'global' };
  const preset = values.has('hasPreset')
    ? promptStore.normalizePreset({
      model: String(values.get('presetModel') || ''),
      reasoningEffort: String(values.get('presetReasoningEffort') || ''),
      speed: String(values.get('presetSpeed') || ''),
    })
    : undefined;
  let nextPrompts;
  if (dialogState.mode === 'edit') {
    nextPrompts = promptStore.prompts.map((prompt) => (
      prompt.id === dialogState.promptID
        ? { ...prompt, name, section, scope, content, preset }
        : prompt
    ));
  } else {
    nextPrompts = [...promptStore.prompts, {
      id: globalThis.crypto?.randomUUID?.() || `prompt-${Date.now()}`,
      name,
      section,
      scope,
      content,
      preset,
    }];
  }
  const nextSections = promptStore.sections.includes(section)
    ? promptStore.sections
    : [...promptStore.sections, section];
  if (!stageLibraryUpdate(nextPrompts, nextSections)) return;
  dialogState = { mode: 'list' };
  renderDialog();
}

function createPromptSection(form) {
  const values = new FormData(form);
  const name = String(values.get('sectionName') || '').trim();
  if (!name) return;
  const section = promptStore.resolveSection(name);
  const nextSections = promptStore.sections.includes(section)
    ? promptStore.sections
    : [...promptStore.sections, section];
  if (!stageLibraryUpdate(promptStore.prompts, nextSections)) return;
  const nextCollapsedSections = new Set(promptStore.collapsedSections);
  nextCollapsedSections.delete(section);
  promptStore.saveCollapsedSections(nextCollapsedSections);
  promptStore.collapsedSections = nextCollapsedSections;
  dialogState = { mode: 'list' };
  renderDialog();
  [...document.querySelectorAll('[data-prompt-section-toggle]')]
    .find((button) => button.dataset.promptSectionToggle === section)?.focus();
}

function renamePromptSection(form) {
  const name = String(new FormData(form).get('sectionName') || '').trim();
  if (!name) return;
  const source = dialogState.section;
  const destination = promptStore.normalizeSection(name);
  const conflictingSection = promptStore.sections.find((section) => (
    section !== source
      && section.localeCompare(destination, undefined, { sensitivity: 'accent' }) === 0
  ));
  if (conflictingSection) {
    showStorageError('A section with that name already exists.');
    return;
  }
  const nextPrompts = promptStore.prompts.map((prompt) => (
    promptStore.normalizeSection(prompt.section) === source
      ? { ...prompt, section: destination }
      : prompt
  ));
  const nextSections = promptStore.sections.map((section) => (
    section === source ? destination : section
  ));
  if (!stageLibraryUpdate(nextPrompts, nextSections)) return;
  promptStore.collapsedSections.delete(source);
  promptStore.saveCollapsedSections();
  dialogState = { mode: 'list' };
  renderDialog();
}

function movePrompt(promptID, offset) {
  if (!promptReordering.moveByOffset(promptID, offset, stageLibraryUpdate)) return;
  renderDialog();
  document.querySelector(`[data-prompt-row-id="${CSS.escape(promptID)}"] [data-prompt-move-${offset < 0 ? 'up' : 'down'}]`)?.focus();
}

function handlePromptSubmit(event, form) {
  event.preventDefault();
  if (form.matches('[data-prompt-form]')) savePrompt(form);
  else if (form.matches('[data-prompt-section-form]')) createPromptSection(form);
  else if (form.matches('[data-prompt-section-rename-form]')) renamePromptSection(form);
}

async function insertSavedPrompt(prompt) {
  const insert = (clipboardText = '') => {
    if (!composerAdapter.insert(expandedPromptContent(prompt.content, clipboardText))) return false;
    closeLibrary({ restoreFocus: false });
    return true;
  };
  if ((!prompt.usePreset || !prompt.preset) && !prompt.content.includes('{{clipboard}}')) return insert();
  let clipboardText = '';
  if (prompt.content.includes('{{clipboard}}')) {
    try { clipboardText = await navigator.clipboard.readText(); } catch (_) { /* use empty text */ }
  }
  hideDialog();
  if (!await composerAdapter.applyPreset(prompt.usePreset ? prompt.preset : undefined)) {
    restoreDialog('Could not apply this prompt’s composer preset. The prompt was not inserted.');
    return false;
  }
  return insert(clipboardText);
}

function handlePromptClick(target) {
  if (target.closest('[data-prompt-close]')) closeLibrary();
  else if (target.closest('[data-prompt-section-toggle]')) {
    const toggle = target.closest('[data-prompt-section-toggle]');
    const section = toggle.dataset.promptSectionToggle;
    if (promptStore.collapsedSections.has(section)) promptStore.collapsedSections.delete(section);
    else promptStore.collapsedSections.add(section);
    promptStore.saveCollapsedSections();
    renderDialog();
    [...document.querySelectorAll('[data-prompt-section-toggle]')]
      .find((button) => button.dataset.promptSectionToggle === section)?.focus();
  } else if (target.closest('[data-prompt-new-section]')) {
    dialogState = { mode: 'createSection' };
    renderDialog();
  } else if (target.closest('[data-prompt-section-rename]')) {
    dialogState = {
      mode: 'renameSection',
      section: target.closest('[data-prompt-section-rename]').dataset.promptSectionRename,
    };
    renderDialog();
  } else if (target.closest('[data-prompt-section-delete-confirm]')) {
    const section = target.closest('[data-prompt-section-delete-confirm]').dataset.promptSectionDeleteConfirm;
    const nextPrompts = promptStore.prompts.map((prompt) => (
      promptStore.normalizeSection(prompt.section) === section
        ? { ...prompt, section: promptLibraryContract.defaultSection }
        : prompt
    ));
    const nextSections = promptStore.sections.filter((item) => item !== section);
    if (!stageLibraryUpdate(nextPrompts, nextSections)) return;
    promptStore.collapsedSections.delete(section);
    promptStore.saveCollapsedSections();
    renderDialog();
  } else if (target.closest('[data-prompt-section-delete]')) {
    const button = target.closest('[data-prompt-section-delete]');
    button.dataset.promptSectionDeleteConfirm = button.dataset.promptSectionDelete;
    button.textContent = 'Confirm delete';
    button.setAttribute(
      'aria-label',
      `Confirm section deletion; prompts will move to ${promptLibraryContract.defaultSection}`,
    );
  } else if (target.closest('[data-prompt-move-up]')) {
    movePrompt(target.closest('[data-prompt-move-up]').dataset.promptMoveUp, -1);
  } else if (target.closest('[data-prompt-move-down]')) {
    movePrompt(target.closest('[data-prompt-move-down]').dataset.promptMoveDown, 1);
  } else if (target.closest('[data-prompt-new]')) {
    dialogState = { mode: 'create' };
    renderDialog();
  } else if (target.closest('[data-prompt-cancel]')) {
    dialogState = { mode: 'list' };
    renderDialog();
  } else if (target.closest('[data-prompt-edit]')) {
    dialogState = {
      mode: 'edit',
      promptID: target.closest('[data-prompt-edit]').dataset.promptEdit,
    };
    renderDialog();
  } else if (target.closest('[data-prompt-delete-confirm]')) {
    const id = target.closest('[data-prompt-delete-confirm]').dataset.promptDeleteConfirm;
    const nextPrompts = promptStore.prompts.filter((prompt) => prompt.id !== id);
    if (!stageLibraryUpdate(nextPrompts, promptStore.sections)) return;
    renderDialog();
  } else if (target.closest('[data-prompt-delete]')) {
    const button = target.closest('[data-prompt-delete]');
    button.dataset.promptDeleteConfirm = button.dataset.promptDelete;
    button.textContent = 'Confirm delete';
    button.setAttribute('aria-label', 'Confirm prompt deletion');
  } else if (target.closest('[data-prompt-use-preset]')) {
    const checkbox = target.closest('[data-prompt-use-preset]');
    const nextPrompts = promptStore.prompts.map((prompt) => (
      prompt.id === checkbox.dataset.promptUsePreset
        ? { ...prompt, usePreset: checkbox.checked || undefined }
        : prompt
    ));
    if (!stageLibraryUpdate(nextPrompts, promptStore.sections)) checkbox.checked = !checkbox.checked;
  } else if (target.closest('[data-prompt-use]')) {
    const id = target.closest('[data-prompt-use]').dataset.promptUse;
    const prompt = promptStore.prompts.find((item) => item.id === id);
    const now = performance.now();
    const previousInsertion = window[insertionGuard];
    if (
      previousInsertion?.promptID === id
        && now - previousInsertion.timestamp < 500
    ) return;
    window[insertionGuard] = { promptID: id, timestamp: now };
    if (!prompt) {
      delete window[insertionGuard];
      return;
    }
    void insertSavedPrompt(prompt).then((inserted) => {
      if (!inserted) delete window[insertionGuard];
    }).catch(() => {
      delete window[insertionGuard];
      if (!document.getElementById(dashboardElements.elementIDs.promptDialog)) presentDialog();
      showStorageError('Could not insert this prompt. Please try again.');
    });
  }
}

function handlePromptInteraction(event) {
  const target = event.target instanceof Element ? event.target : null;
  if (
    event.type === 'keydown'
      && event.key === 'Escape'
      && document.getElementById(dashboardElements.elementIDs.promptDialog)
  ) {
    promptLibraryDialog.handleKeyboard(
      event,
      document.getElementById(dashboardElements.elementIDs.promptDialog),
      closeLibrary,
    );
    return;
  }
  const dialog = target?.closest(`#${dashboardElements.elementIDs.promptDialog}`);
  if (!dialog || dialog[dialogOwner] !== true) return;
  if (promptReordering.handle(event, target, dialog, stageLibraryUpdate, renderDialog)) return;
  if (event.type === 'keydown') {
    if (event.target.matches('[data-prompt-search]') && event.key === 'ArrowDown') {
      event.preventDefault();
      dialog.querySelector('[data-prompt-use]')?.focus();
    } else promptLibraryDialog.handleKeyboard(event, dialog, closeLibrary);
  }
  else if (
    (event.type === 'input' || event.type === 'search')
      && event.target.matches('[data-prompt-search]')
  ) {
    searchTerm = event.target.value;
    renderDialog({
      searchSelection: {
        start: event.target.selectionStart ?? searchTerm.length,
        end: event.target.selectionEnd ?? searchTerm.length,
      },
    });
  }
  else if (event.type === 'change') {
    if (event.target.matches('[name="hasPreset"]')) {
      const form = event.target.closest('[data-prompt-form]');
      const fields = form?.querySelector('[data-prompt-preset-fields]');
      if (fields) fields.disabled = !event.target.checked;
    }
  }
  else if (event.type === 'submit') handlePromptSubmit(event, target);
  else if (event.type === 'click') handlePromptClick(target);
}

function mount() {
  promptLauncher.mount(openLibrary);
  promptInteractionEventTypes.forEach((type) => {
    document.addEventListener(type, handlePromptInteraction, true);
  });
}

function unmount() {
  promptInteractionEventTypes.forEach((type) => {
    document.removeEventListener(type, handlePromptInteraction, true);
  });
  promptLauncher.unmount();
  closeLibrary({ restoreFocus: false });
}

function refresh() {
  const dialog = document.getElementById(dashboardElements.elementIDs.promptDialog);
  if (!dialog || dialogState.mode !== 'list') return;
  const search = dialog.querySelector('[data-prompt-search]');
  const searchSelection = document.activeElement === search
    ? {
      start: search.selectionStart ?? searchTerm.length,
      end: search.selectionEnd ?? searchTerm.length,
    }
    : undefined;
  renderDialog({ searchSelection });
}

  return { mount, refresh, unmount };
})();
