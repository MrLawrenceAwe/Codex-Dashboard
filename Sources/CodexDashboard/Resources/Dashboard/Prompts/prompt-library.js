const promptLibrary = (() => {
  const dialogOwner = Symbol('codex-dashboard.prompt-dialog-owner');
  const insertionGuard = Symbol.for('codex-dashboard.prompt-insertion-guard');
  let dialogState = { mode: 'list' };
  let returnFocusElement;
  let promptSearchTerm = '';
  let capturedSelectionText = '';

  function showStorageError(message) {
    const error = document.querySelector('[data-prompt-storage-error]');
    if (error) {
      if (message) error.textContent = message;
      error.hidden = false;
    }
  }

  function persistLibrary(nextPrompts = promptStore.prompts, nextSections = promptStore.sections) {
    if (promptStore.saveLibrary(nextPrompts, nextSections)) return true;
    showStorageError();
    return false;
  }

  const promptInteractionEventTypes = [
  'pointerdown', 'mousedown', 'click', 'keydown', 'input', 'change', 'submit',
  'dragstart', 'dragover', 'dragleave', 'drop', 'dragend',
];

function createDialogElement() {
  const dialog = document.createElement('div');
  dialog[dialogOwner] = true;
  dialog.id = dashboardDOM.elementIDs.promptDialog;
  dialog.innerHTML = `
    <div class="dashboard-prompt-backdrop" data-prompt-close></div>
    <section class="dashboard-prompt-panel" role="dialog" aria-modal="true" aria-labelledby="dashboard-prompt-title">
      <header class="dashboard-prompt-header">
        <h2 id="dashboard-prompt-title">Prompts</h2>
        <button type="button" class="dashboard-prompt-icon-button" data-prompt-close aria-label="Close prompts">×</button>
      </header>
      <p class="dashboard-prompt-storage-error" data-prompt-storage-error role="alert" hidden>Could not save this prompt change. Reloading Codex will restore the last successfully saved version.</p>
      <div data-prompt-content></div>
    </section>`;
  return dialog;
}

function renderDialog() {
  const dialog = document.getElementById(dashboardDOM.elementIDs.promptDialog);
  const content = dialog?.querySelector('[data-prompt-content]');
  if (!content) return;
  if (dialogState.mode === 'createSection') {
    content.innerHTML = `
      <form class="dashboard-prompt-form" data-prompt-section-form>
        <label>Section name<input name="sectionName" autocomplete="off" maxlength="80" placeholder="e.g. Code review" required /></label>
        <div class="dashboard-prompt-form-actions">
          <button type="button" class="dashboard-prompt-secondary" data-prompt-cancel>Cancel</button>
          <button type="submit" class="dashboard-prompt-primary">Create section</button>
        </div>
      </form>`;
    content.querySelector('[name="sectionName"]')?.focus();
    return;
  }
  if (dialogState.mode === 'renameSection') {
    content.innerHTML = `
      <form class="dashboard-prompt-form" data-prompt-section-rename-form>
        <label>Section name<input name="sectionName" autocomplete="off" maxlength="80" value="${dashboardDOM.escapeHTML(dialogState.section)}" required /></label>
        <div class="dashboard-prompt-form-actions">
          <button type="button" class="dashboard-prompt-secondary" data-prompt-cancel>Cancel</button>
          <button type="submit" class="dashboard-prompt-primary">Rename section</button>
        </div>
      </form>`;
    content.querySelector('[name="sectionName"]')?.focus();
    return;
  }
  if (dialogState.mode !== 'list') {
    const prompt = dialogState.mode === 'edit'
      ? promptStore.prompts.find((item) => item.id === dialogState.promptID)
      : undefined;
    const sectionNames = [...promptStore.sections]
      .sort((left, right) => left.localeCompare(right));
    content.innerHTML = `
      <form class="dashboard-prompt-form" data-prompt-form>
        <label>Name<input name="name" autocomplete="off" maxlength="80" placeholder="e.g. Review this code" value="${dashboardDOM.escapeHTML(prompt?.name || '')}" required /></label>
        <label>Section<input name="section" autocomplete="off" maxlength="80" list="dashboard-prompt-sections" placeholder="General" value="${dashboardDOM.escapeHTML(promptStore.normalizeSection(prompt?.section))}" /><datalist id="dashboard-prompt-sections">${sectionNames.map((section) => `<option value="${dashboardDOM.escapeHTML(section)}"></option>`).join('')}</datalist></label>
        <label>Prompt<textarea name="content" rows="8" placeholder="Write the prompt you want to reuse…" required>${dashboardDOM.escapeHTML(prompt?.content || '')}</textarea></label>
        <div class="dashboard-prompt-form-actions">
          <button type="button" class="dashboard-prompt-secondary" data-prompt-cancel>Cancel</button>
          <button type="submit" class="dashboard-prompt-primary">Save prompt</button>
        </div>
      </form>`;
    content.querySelector('[name="name"]')?.focus();
    return;
  }
  const query = promptSearchTerm.trim().toLowerCase();
  const visiblePrompts = query ? promptStore.prompts.filter((prompt) => (
    `${prompt.name} ${prompt.section} ${prompt.content}`.toLowerCase().includes(query)
  )) : promptStore.prompts;
  const renderPromptRows = (sectionPrompts) => sectionPrompts.map((prompt) => `
    <article class="dashboard-prompt-row" data-prompt-row-id="${dashboardDOM.escapeHTML(prompt.id)}" draggable="true">
      <span class="dashboard-prompt-drag-handle" aria-hidden="true" title="Drag to reorder">⠿</span>
      <button type="button" class="dashboard-prompt-use" data-prompt-use="${dashboardDOM.escapeHTML(prompt.id)}">
        <strong>${dashboardDOM.escapeHTML(prompt.name)}</strong>
        <span>${dashboardDOM.escapeHTML(prompt.content)}</span>
      </button>
      <div class="dashboard-prompt-row-actions">
        <button type="button" data-prompt-move-up="${dashboardDOM.escapeHTML(prompt.id)}" aria-label="Move ${dashboardDOM.escapeHTML(prompt.name)} up">↑</button>
        <button type="button" data-prompt-move-down="${dashboardDOM.escapeHTML(prompt.id)}" aria-label="Move ${dashboardDOM.escapeHTML(prompt.name)} down">↓</button>
        <button type="button" data-prompt-edit="${dashboardDOM.escapeHTML(prompt.id)}" aria-label="Edit ${dashboardDOM.escapeHTML(prompt.name)}">Edit</button>
        <button type="button" data-prompt-delete="${dashboardDOM.escapeHTML(prompt.id)}" aria-label="Delete ${dashboardDOM.escapeHTML(prompt.name)}">Delete</button>
      </div>
    </article>`).join('');
  const groupedPrompts = new Map();
  promptStore.sections.forEach((section) => groupedPrompts.set(section, []));
  visiblePrompts.forEach((prompt) => {
    const section = promptStore.normalizeSection(prompt.section);
    if (!groupedPrompts.has(section)) groupedPrompts.set(section, []);
    groupedPrompts.get(section).push(prompt);
  });
  const orderedSections = [...groupedPrompts.entries()].sort(([left], [right]) => {
    if (left === 'General') return -1;
    if (right === 'General') return 1;
    return left.localeCompare(right);
  });
  const sections = orderedSections.map(([section, sectionPrompts], index) => {
    const collapsed = promptStore.collapsedSections.has(section);
    const sectionBodyID = `dashboard-prompt-section-${index}`;
    return `
      <section class="dashboard-prompt-section${collapsed ? ' is-collapsed' : ''}" data-prompt-section="${dashboardDOM.escapeHTML(section)}">
        <button type="button" class="dashboard-prompt-section-toggle" data-prompt-section-toggle="${dashboardDOM.escapeHTML(section)}" aria-expanded="${String(!collapsed)}" aria-controls="${sectionBodyID}">
          <span class="dashboard-prompt-section-title"><span class="dashboard-prompt-section-chevron" aria-hidden="true">›</span><strong>${dashboardDOM.escapeHTML(section)}</strong></span>
          <span class="dashboard-prompt-section-count">${sectionPrompts.length}</span>
        </button>
        <div class="dashboard-prompt-section-actions">
          ${section === 'General' ? '' : `<button type="button" data-prompt-section-rename="${dashboardDOM.escapeHTML(section)}" aria-label="Rename ${dashboardDOM.escapeHTML(section)} section">Rename</button><button type="button" data-prompt-section-delete="${dashboardDOM.escapeHTML(section)}" aria-label="Delete ${dashboardDOM.escapeHTML(section)} section">Delete</button>`}
        </div>
        <div class="dashboard-prompt-section-body" id="${sectionBodyID}"${collapsed ? ' hidden' : ''}>${renderPromptRows(sectionPrompts)}</div>
      </section>`;
  }).join('');
  content.innerHTML = `
    <div class="dashboard-prompt-tools">
      <label class="dashboard-prompt-search"><span class="sr-only">Search prompts</span><input type="search" data-prompt-search value="${dashboardDOM.escapeHTML(promptSearchTerm)}" /></label>
      <div class="dashboard-prompt-overflow">
        <button type="button" class="dashboard-prompt-secondary dashboard-prompt-overflow-toggle" data-prompt-actions-toggle aria-label="Prompt library actions" aria-expanded="false" aria-haspopup="menu">•••</button>
        <div class="dashboard-prompt-overflow-menu" data-prompt-actions-menu role="menu" hidden>
          <button type="button" data-prompt-export role="menuitem">Export library</button>
          <button type="button" data-prompt-import role="menuitem">Import library</button>
        </div>
      </div>
      <input type="file" accept="application/json,.json" data-prompt-import-file hidden />
    </div>
    <div class="dashboard-prompt-list">
      ${sections || `<div class="dashboard-prompt-empty"><strong>${query ? 'No matching prompts' : 'No saved prompts yet'}</strong><span>${query ? 'Try a different search.' : 'Save instructions you use often, then insert them into a chat in one click.'}</span></div>`}
    </div>
    <div class="dashboard-prompt-create-actions">
      <button type="button" class="dashboard-prompt-new dashboard-prompt-new-primary" data-prompt-new>+ New prompt</button>
      <button type="button" class="dashboard-prompt-new dashboard-prompt-new-secondary" data-prompt-new-section>+ New section</button>
    </div>`;
  content.querySelector('[data-prompt-search]')?.focus();
}

function open() {
  const composer = codexContracts.composer(dashboardDOM.elementIDs.promptDialog);
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
  document.getElementById(dashboardDOM.elementIDs.promptDialog)?.remove();
  returnFocusElement = document.activeElement instanceof HTMLElement
    ? document.activeElement
    : undefined;
  dialogState = { mode: 'list' };
  promptSearchTerm = '';
  const dialog = createDialogElement();
  document.body.append(dialog);
  renderDialog();
}

function exportLibrary() {
  const payload = JSON.stringify({
    version: 1,
    prompts: promptStore.prompts,
    sections: promptStore.sections,
  }, null, 2);
  const link = document.createElement('a');
  link.href = URL.createObjectURL(new Blob([payload], { type: 'application/json' }));
  link.download = `codex-dashboard-prompts-${new Date().toISOString().slice(0, 10)}.json`;
  link.click();
  setTimeout(() => URL.revokeObjectURL(link.href), 0);
}

async function importLibrary(file) {
  try {
    const payload = JSON.parse(await file.text());
    if (!promptLibraryContract.isValidExport(payload)) {
      throw new Error('invalid prompt library');
    }
    const prompts = promptStore.normalizePrompts(payload?.prompts);
    const sections = promptStore.normalizeSections(payload?.sections, prompts);
    if (!persistLibrary(prompts, sections)) return;
    promptStore.prompts = prompts;
    promptStore.sections = sections;
    promptSearchTerm = '';
    renderDialog();
  } catch (_) {
    showStorageError('Could not import this file. Choose an unmodified Codex Dashboard prompt export.');
  }
}

function expandedPromptContent(content, clipboardText = '') {
  return content
    .replaceAll('{{selection}}', capturedSelectionText)
    .replaceAll('{{clipboard}}', clipboardText);
}

function close({ restoreFocus = true } = {}) {
  dialogState = { mode: 'list' };
  document.getElementById(dashboardDOM.elementIDs.promptDialog)?.remove();
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
  let nextPrompts;
  if (dialogState.mode === 'edit') {
    nextPrompts = promptStore.prompts.map((prompt) => (
      prompt.id === dialogState.promptID ? { ...prompt, name, section, content } : prompt
    ));
  } else {
    nextPrompts = [...promptStore.prompts, {
      id: globalThis.crypto?.randomUUID?.() || `prompt-${Date.now()}`,
      name,
      section,
      content,
    }];
  }
  const nextSections = promptStore.sections.includes(section)
    ? promptStore.sections
    : [...promptStore.sections, section];
  if (!persistLibrary(nextPrompts, nextSections)) return;
  promptStore.prompts = nextPrompts;
  promptStore.sections = nextSections;
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
  if (!persistLibrary(promptStore.prompts, nextSections)) return;
  promptStore.sections = nextSections;
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
  if (!persistLibrary(nextPrompts, nextSections)) return;
  promptStore.prompts = nextPrompts;
  promptStore.sections = nextSections;
  promptStore.collapsedSections.delete(source);
  promptStore.saveCollapsedSections();
  dialogState = { mode: 'list' };
  renderDialog();
}

function movePrompt(promptID, offset) {
  const index = promptStore.prompts.findIndex((prompt) => prompt.id === promptID);
  const prompt = promptStore.prompts[index];
  if (!prompt) return;
  const section = promptStore.normalizeSection(prompt.section);
  const sectionIndexes = promptStore.prompts
    .map((item, itemIndex) => ({ item, itemIndex }))
    .filter(({ item }) => promptStore.normalizeSection(item.section) === section)
    .map(({ itemIndex }) => itemIndex);
  const position = sectionIndexes.indexOf(index);
  const destination = sectionIndexes[position + offset];
  if (destination === undefined) return;
  const nextPrompts = [...promptStore.prompts];
  [nextPrompts[index], nextPrompts[destination]] = [nextPrompts[destination], nextPrompts[index]];
  if (!persistLibrary(nextPrompts, promptStore.sections)) return;
  promptStore.prompts = nextPrompts;
  renderDialog();
  document.querySelector(`[data-prompt-row-id="${CSS.escape(promptID)}"] [data-prompt-move-${offset < 0 ? 'up' : 'down'}]`)?.focus();
}

function handlePromptKeyboard(event, dialog) {
  if (event.key === 'Escape') {
    event.preventDefault();
    event.stopImmediatePropagation();
    const actionsMenu = dialog.querySelector('[data-prompt-actions-menu]');
    if (actionsMenu && !actionsMenu.hidden) {
      actionsMenu.hidden = true;
      const actionsToggle = dialog.querySelector('[data-prompt-actions-toggle]');
      actionsToggle?.setAttribute('aria-expanded', 'false');
      actionsToggle?.focus();
      return;
    }
    close();
    return;
  }
  if (event.key !== 'Tab') return;
  const focusable = [...dialog.querySelectorAll('button, input, textarea, [tabindex]:not([tabindex="-1"])')]
    .filter((element) => !element.disabled && element.getClientRects().length > 0);
  const first = focusable[0];
  const last = focusable.at(-1);
  if (first && last && event.shiftKey && document.activeElement === first) {
    event.preventDefault();
    last.focus();
  } else if (first && last && !event.shiftKey && document.activeElement === last) {
    event.preventDefault();
    first.focus();
  }
}

function handlePromptSubmit(event, form) {
  event.preventDefault();
  if (form.matches('[data-prompt-form]')) savePrompt(form);
  else if (form.matches('[data-prompt-section-form]')) createPromptSection(form);
  else if (form.matches('[data-prompt-section-rename-form]')) renamePromptSection(form);
}

function insertSavedPrompt(prompt) {
  const insert = (clipboardText = '') => {
    if (composerAdapter.insert(expandedPromptContent(prompt.content, clipboardText))) {
      close({ restoreFocus: false });
      return true;
    }
    return false;
  };
  if (!prompt.content.includes('{{clipboard}}')) return insert();
  navigator.clipboard.readText()
    .then(insert)
    .catch(() => insert(''));
  return true;
}

function handlePromptClick(target) {
  if (target.closest('[data-prompt-close]')) close();
  else if (target.closest('[data-prompt-actions-toggle]')) {
    const toggle = target.closest('[data-prompt-actions-toggle]');
    const menu = document.querySelector('[data-prompt-actions-menu]');
    if (!menu) return;
    menu.hidden = !menu.hidden;
    toggle.setAttribute('aria-expanded', String(!menu.hidden));
    if (!menu.hidden) menu.querySelector('button')?.focus();
  }
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
        ? { ...prompt, section: 'General' }
        : prompt
    ));
    const nextSections = promptStore.sections.filter((item) => item !== section);
    if (!persistLibrary(nextPrompts, nextSections)) return;
    promptStore.prompts = nextPrompts;
    promptStore.sections = nextSections;
    promptStore.collapsedSections.delete(section);
    promptStore.saveCollapsedSections();
    renderDialog();
  } else if (target.closest('[data-prompt-section-delete]')) {
    const button = target.closest('[data-prompt-section-delete]');
    button.dataset.promptSectionDeleteConfirm = button.dataset.promptSectionDelete;
    button.textContent = 'Confirm delete';
    button.setAttribute('aria-label', 'Confirm section deletion; prompts will move to General');
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
  } else if (target.closest('[data-prompt-export]')) {
    document.querySelector('[data-prompt-actions-menu]')?.setAttribute('hidden', '');
    document.querySelector('[data-prompt-actions-toggle]')?.setAttribute('aria-expanded', 'false');
    exportLibrary();
  } else if (target.closest('[data-prompt-import]')) {
    document.querySelector('[data-prompt-actions-menu]')?.setAttribute('hidden', '');
    document.querySelector('[data-prompt-actions-toggle]')?.setAttribute('aria-expanded', 'false');
    document.querySelector('[data-prompt-import-file]')?.click();
  } else if (target.closest('[data-prompt-delete-confirm]')) {
    const id = target.closest('[data-prompt-delete-confirm]').dataset.promptDeleteConfirm;
    const nextPrompts = promptStore.prompts.filter((prompt) => prompt.id !== id);
    if (!persistLibrary(nextPrompts, promptStore.sections)) return;
    promptStore.prompts = nextPrompts;
    renderDialog();
  } else if (target.closest('[data-prompt-delete]')) {
    const button = target.closest('[data-prompt-delete]');
    button.dataset.promptDeleteConfirm = button.dataset.promptDelete;
    button.textContent = 'Confirm delete';
    button.setAttribute('aria-label', 'Confirm prompt deletion');
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
    if (!prompt || !insertSavedPrompt(prompt)) {
      delete window[insertionGuard];
    }
  }
}

function handlePromptInteraction(event) {
  const target = event.target instanceof Element ? event.target : null;
  if (
    event.type === 'keydown'
      && event.key === 'Escape'
      && document.getElementById(dashboardDOM.elementIDs.promptDialog)
  ) {
    handlePromptKeyboard(event, document.getElementById(dashboardDOM.elementIDs.promptDialog));
    return;
  }
  const dialog = target?.closest(`#${dashboardDOM.elementIDs.promptDialog}`);
  if (!dialog || dialog[dialogOwner] !== true) return;
  if (promptReordering.handle(event, target, dialog, persistLibrary, renderDialog)) return;
  if (event.type === 'keydown') {
    if (event.target.matches('[data-prompt-search]') && event.key === 'ArrowDown') {
      event.preventDefault();
      dialog.querySelector('[data-prompt-use]')?.focus();
    } else handlePromptKeyboard(event, dialog);
  }
  else if (event.type === 'input' && event.target.matches('[data-prompt-search]')) {
    promptSearchTerm = event.target.value;
    renderDialog();
  }
  else if (event.type === 'change' && event.target.matches('[data-prompt-import-file]')) {
    const [file] = event.target.files || [];
    if (file) void importLibrary(file);
  }
  else if (event.type === 'submit') handlePromptSubmit(event, target);
  else if (event.type === 'click') handlePromptClick(target);
}

function mount() {
  promptLauncher.mount(open);
  promptInteractionEventTypes.forEach((type) => {
    document.addEventListener(type, handlePromptInteraction, true);
  });
}

function unmount() {
  promptInteractionEventTypes.forEach((type) => {
    document.removeEventListener(type, handlePromptInteraction, true);
  });
  promptLauncher.unmount();
  close({ restoreFocus: false });
}

  return { mount, unmount };
})();
