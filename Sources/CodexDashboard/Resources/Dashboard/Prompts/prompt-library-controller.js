function createPromptLibrary({ findThread }) {
  const dialogOwner = Symbol('codex-dashboard.prompt-dialog-owner');
  const insertionGuard = Symbol.for('codex-dashboard.prompt-insertion-guard');
  let dialogState = { mode: 'list' };
  let returnFocusElement;
  let searchTerm = '';
  let capturedSelectionText = '';
  let composerProject;
  let libraryGeneration = 0;
  let editedPromptValues;

  function showDialogError(message) {
    const error = document.querySelector('[data-prompt-storage-error]');
    if (error) {
      if (message) error.textContent = message;
      error.hidden = false;
    }
  }

  function stageLibraryUpdate(nextPrompts = promptStore.prompts, nextSections = promptStore.sections) {
    if (promptStore.stageLibraryUpdate(nextPrompts, nextSections)) return true;
    showDialogError();
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
    showDialogError(message);
  }

  function openLibrary() {
    libraryGeneration += 1;
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
    composerProject = codexHost.composerProject(findThread);
    presentDialog();
  }

  function expandedPromptContent(content, clipboardText = '') {
    // Expand only template tokens; inserted text may contain literal tokens.
    return content.replace(/\{\{(selection|clipboard)\}\}/g, (_, placeholder) => (
      placeholder === 'selection' ? capturedSelectionText : clipboardText
    ));
  }

  function closeLibrary({ restoreFocus = true } = {}) {
    libraryGeneration += 1;
    dialogState = { mode: 'list' };
    document.getElementById(dashboardElements.elementIDs.promptDialog)?.remove();
    const returnFocus = returnFocusElement;
    returnFocusElement = undefined;
    if (restoreFocus && returnFocus?.isConnected) returnFocus.focus();
  }

  function readPromptValues(form) {
    const values = new FormData(form);
    const name = String(values.get('name') || '').trim();
    const content = String(values.get('content') || '').trim();
    const section = promptStore.resolveSection(values.get('section'));
    const scope = values.get('scope') === 'project' && composerProject
      ? { type: 'project', projectPath: composerProject.path }
      : { type: 'global' };
    const preset = values.has('hasPreset')
      ? composerPresets.normalize({
        model: String(values.get('presetModel') || ''),
        reasoningEffort: String(values.get('presetReasoningEffort') || ''),
        speed: String(values.get('presetSpeed') || ''),
      })
      : undefined;
    return { name, content, section, scope, preset };
  }

  function stagePrompt(form) {
    const values = readPromptValues(form);
    if (!values.name || !values.content) return;
    let nextPrompts;
    if (dialogState.mode === 'edit') {
      // The form stays untouched during shared-library refreshes. Compare with
      // its opening values so untouched fields retain those newer updates.
      nextPrompts = promptStore.prompts.map((prompt) => {
        if (prompt.id !== dialogState.promptID) return prompt;
        const merged = { ...prompt };
        for (const key of Object.keys(values)) {
          if (JSON.stringify(values[key]) === JSON.stringify(editedPromptValues[key])) continue;
          if (values[key] === undefined) delete merged[key];
          else merged[key] = values[key];
        }
        return merged;
      });
    } else {
      nextPrompts = [...promptStore.prompts, {
        id: globalThis.crypto?.randomUUID?.() || `prompt-${Date.now()}`,
        ...values,
      }];
    }
    // Section normalization adds only sections used by the merged prompts.
    if (!stageLibraryUpdate(nextPrompts)) return;
    dialogState = { mode: 'list' };
    renderDialog();
  }

  function createPromptSection(form) {
    const values = new FormData(form);
    const name = String(values.get('sectionName') || '').trim();
    if (!name) return;
    const section = promptStore.createSection(name);
    if (!section) {
      showDialogError();
      return;
    }
    dialogState = { mode: 'list' };
    renderDialog();
    [...document.querySelectorAll('[data-prompt-section-toggle]')]
      .find((button) => button.dataset.promptSectionToggle === section)?.focus();
  }

  function renamePromptSection(form) {
    const name = String(new FormData(form).get('sectionName') || '').trim();
    if (!name) return;
    const result = promptStore.renameSection(dialogState.section, name);
    if (result === 'conflict') {
      showDialogError('A section with that name already exists.');
      return;
    }
    if (result === 'failed') {
      showDialogError();
      return;
    }
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
    if (form.matches('[data-prompt-form]')) stagePrompt(form);
    else if (form.matches('[data-prompt-section-form]')) createPromptSection(form);
    else if (form.matches('[data-prompt-section-rename-form]')) renamePromptSection(form);
  }

  async function insertSavedPrompt(prompt) {
    const generation = libraryGeneration;
    const composer = codexUIContracts.composer(dashboardElements.elementIDs.promptDialog);
    const threadID = codexUIContracts.activeComposerThreadID();
    const projectID = codexUIContracts.activeComposerProjectID();
    const isCurrent = () => generation === libraryGeneration && !!composer
      && codexUIContracts.composer(dashboardElements.elementIDs.promptDialog) === composer
      && codexUIContracts.activeComposerThreadID() === threadID
      && codexUIContracts.activeComposerProjectID() === projectID;
    const cancel = () => {
      if (generation === libraryGeneration) hideDialog();
      return false;
    };
    const insert = (clipboardText = '') => {
      if (!isCurrent()) return cancel();
      if (!composerAdapter.insert(expandedPromptContent(prompt.content, clipboardText))) return false;
      closeLibrary({ restoreFocus: false });
      return true;
    };
    if ((!prompt.usePreset || !prompt.preset) && !prompt.content.includes('{{clipboard}}')) return insert();
    let clipboardText = '';
    if (prompt.content.includes('{{clipboard}}')) {
      try { clipboardText = await navigator.clipboard.readText(); } catch (_) { /* use empty text */ }
    }
    if (!isCurrent()) return cancel();
    hideDialog();
    if (!await composerModelPicker.applyPreset(prompt.usePreset ? prompt.preset : undefined, { isCurrent })) {
      if (!isCurrent()) return cancel();
      restoreDialog('Could not apply this prompt’s model settings. The prompt was not inserted.');
      return false;
    }
    return insert(clipboardText);
  }

  function toggleSection(section) {
    promptStore.toggleSection(section);
    renderDialog();
    [...document.querySelectorAll('[data-prompt-section-toggle]')]
      .find((button) => button.dataset.promptSectionToggle === section)?.focus();
  }

  function deleteSection(section) {
    if (!promptStore.deleteSection(section)) {
      showDialogError();
      return;
    }
    renderDialog();
  }

  function deletePrompt(id) {
    const nextPrompts = promptStore.prompts.filter((prompt) => prompt.id !== id);
    if (stageLibraryUpdate(nextPrompts)) renderDialog();
  }

  function confirmDeletion(button, attribute, id, label) {
    button.setAttribute(attribute, id);
    button.textContent = 'Confirm delete';
    button.setAttribute('aria-label', label);
  }

  function setDialogState(state) {
    dialogState = state;
    renderDialog();
    editedPromptValues = state.mode === 'edit'
      ? readPromptValues(document.querySelector('[data-prompt-form]')) : undefined;
  }

  function togglePreset(checkbox) {
    const nextPrompts = promptStore.prompts.map((prompt) => (
      prompt.id === checkbox.dataset.promptUsePreset
        ? { ...prompt, usePreset: checkbox.checked || undefined }
        : prompt
    ));
    if (!stageLibraryUpdate(nextPrompts)) checkbox.checked = !checkbox.checked;
  }

  function usePrompt(button) {
    const id = button.dataset.promptUse;
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
      showDialogError('Could not insert this prompt. Please try again.');
    });
  }

  // Confirmation selectors precede the original delete selectors on the same button.
  const clickActions = [
    ['close', () => closeLibrary()],
    ['section-toggle', (button) => toggleSection(button.dataset.promptSectionToggle)],
    ['new-section', () => setDialogState({ mode: 'createSection' })],
    ['section-rename', (button) => setDialogState({ mode: 'renameSection', section: button.dataset.promptSectionRename })],
    ['section-delete-confirm', (button) => deleteSection(button.dataset.promptSectionDeleteConfirm)],
    ['section-delete', (button) => confirmDeletion(button, 'data-prompt-section-delete-confirm', button.dataset.promptSectionDelete,
      `Confirm section deletion; prompts will move to ${promptLibraryContract.defaultSection}`)],
    ['move-up', (button) => movePrompt(button.dataset.promptMoveUp, -1)],
    ['move-down', (button) => movePrompt(button.dataset.promptMoveDown, 1)],
    ['new', () => setDialogState({ mode: 'create' })],
    ['cancel', () => setDialogState({ mode: 'list' })],
    ['edit', (button) => setDialogState({ mode: 'edit', promptID: button.dataset.promptEdit })],
    ['delete-confirm', (button) => deletePrompt(button.dataset.promptDeleteConfirm)],
    ['delete', (button) => confirmDeletion(button, 'data-prompt-delete-confirm', button.dataset.promptDelete, 'Confirm prompt deletion')],
    ['use-preset', togglePreset],
    ['use', usePrompt],
  ];

  function handlePromptClick(target) {
    for (const [action, handle] of clickActions) {
      const button = target.closest(`[data-prompt-${action}]`);
      if (!button) continue;
      handle(button);
      return;
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
    promptLibraryButton.mount(openLibrary);
    window.addEventListener('storage', handleStorageChange);
    promptInteractionEventTypes.forEach((type) => {
      document.addEventListener(type, handlePromptInteraction, true);
    });
  }

  function unmount() {
    window.removeEventListener('storage', handleStorageChange);
    promptInteractionEventTypes.forEach((type) => {
      document.removeEventListener(type, handlePromptInteraction, true);
    });
    promptLibraryButton.unmount();
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

  function handleStorageChange(event) {
    if (promptStore.isSharedStorageKey(event.key) && promptStore.refreshFromSharedStorage()) {
      refresh();
    }
  }

  return { mount, refresh, unmount };
}
