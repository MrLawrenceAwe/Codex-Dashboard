const promptLibrary = (() => {
  let dialogState = { mode: 'list' };
  let returnFocusElement;

  function showStorageError() {
    const error = document.querySelector('[data-prompt-storage-error]');
    if (error) error.hidden = false;
  }

  function persistLibrary(nextPrompts = promptStore.prompts, nextSections = promptStore.sections) {
    if (promptStore.saveLibrary(nextPrompts, nextSections)) return true;
    showStorageError();
    return false;
  }

  const promptInteractionEventTypes = [
  'pointerdown', 'mousedown', 'click', 'keydown', 'submit',
  'dragstart', 'dragover', 'dragleave', 'drop', 'dragend',
];

function createDialogElement() {
  const dialog = document.createElement('div');
  dialog.id = dashboardDOM.elementIDs.promptDialog;
  dialog.innerHTML = `
    <div class="dashboard-prompt-backdrop" data-prompt-close></div>
    <section class="dashboard-prompt-panel" role="dialog" aria-modal="true" aria-labelledby="dashboard-prompt-title">
      <header class="dashboard-prompt-header">
        <div>
          <h2 id="dashboard-prompt-title">Prompts</h2>
          <p>Reusable instructions for any chat</p>
        </div>
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
  const renderPromptRows = (sectionPrompts) => sectionPrompts.map((prompt) => `
    <article class="dashboard-prompt-row" data-prompt-row-id="${dashboardDOM.escapeHTML(prompt.id)}" draggable="true">
      <span class="dashboard-prompt-drag-handle" aria-hidden="true" title="Drag to reorder">⠿</span>
      <button type="button" class="dashboard-prompt-use" data-prompt-use="${dashboardDOM.escapeHTML(prompt.id)}">
        <strong>${dashboardDOM.escapeHTML(prompt.name)}</strong>
        <span>${dashboardDOM.escapeHTML(prompt.content)}</span>
      </button>
      <div class="dashboard-prompt-row-actions">
        <button type="button" data-prompt-edit="${dashboardDOM.escapeHTML(prompt.id)}" aria-label="Edit ${dashboardDOM.escapeHTML(prompt.name)}">Edit</button>
        <button type="button" data-prompt-delete="${dashboardDOM.escapeHTML(prompt.id)}" aria-label="Delete ${dashboardDOM.escapeHTML(prompt.name)}">Delete</button>
      </div>
    </article>`).join('');
  const groupedPrompts = new Map();
  promptStore.sections.forEach((section) => groupedPrompts.set(section, []));
  promptStore.prompts.forEach((prompt) => {
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
        <div class="dashboard-prompt-section-body" id="${sectionBodyID}"${collapsed ? ' hidden' : ''}>${renderPromptRows(sectionPrompts)}</div>
      </section>`;
  }).join('');
  content.innerHTML = `
    <div class="dashboard-prompt-list">
      ${sections || '<div class="dashboard-prompt-empty"><strong>No saved prompts yet</strong><span>Save instructions you use often, then insert them into a chat in one click.</span></div>'}
    </div>
    <div class="dashboard-prompt-create-actions">
      <button type="button" class="dashboard-prompt-new" data-prompt-new>+ New prompt</button>
      <button type="button" class="dashboard-prompt-new" data-prompt-new-section>+ New section</button>
    </div>`;
  content.querySelector('[data-prompt-use], [data-prompt-new], [data-prompt-new-section]')?.focus();
}

function open() {
  document.getElementById(dashboardDOM.elementIDs.promptDialog)?.remove();
  returnFocusElement = document.activeElement instanceof HTMLElement
    ? document.activeElement
    : undefined;
  dialogState = { mode: 'list' };
  const dialog = createDialogElement();
  document.body.append(dialog);
  renderDialog();
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

function handlePromptKeyboard(event, dialog) {
  if (event.key === 'Escape') {
    event.preventDefault();
    event.stopImmediatePropagation();
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
  if (form.matches('[data-prompt-form]')) savePrompt(form);
  else if (form.matches('[data-prompt-section-form]')) createPromptSection(form);
  else return;
  event.preventDefault();
}

function handlePromptClick(target) {
  if (target.closest('[data-prompt-close]')) close();
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
    if (prompt && composerAdapter.insert(prompt.content)) {
      close({ restoreFocus: false });
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
  if (!dialog) return;
  if (promptReordering.handle(event, target, dialog, persistLibrary, renderDialog)) return;
  if (event.type === 'keydown') handlePromptKeyboard(event, dialog);
  else if (event.type === 'submit') handlePromptSubmit(event, target);
  else if (event.type === 'click') handlePromptClick(target);
}

function mount() {
  promptMenu.mount(open);
  promptInteractionEventTypes.forEach((type) => {
    document.addEventListener(type, handlePromptInteraction, true);
  });
}

function unmount() {
  promptInteractionEventTypes.forEach((type) => {
    document.removeEventListener(type, handlePromptInteraction, true);
  });
  promptMenu.unmount();
  close({ restoreFocus: false });
}

  return { mount, unmount };
})();
