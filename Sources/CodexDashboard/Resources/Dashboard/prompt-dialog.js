const promptInteractionEventTypes = [
  'pointerdown', 'mousedown', 'click', 'keydown', 'submit',
  'dragstart', 'dragover', 'dragleave', 'drop', 'dragend',
];

function createPromptDialog() {
  const dialog = document.createElement('div');
  dialog.id = elementIDs.promptDialog;
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

function renderPromptLibrary() {
  const dialog = document.getElementById(elementIDs.promptDialog);
  const content = dialog?.querySelector('[data-prompt-content]');
  if (!content) return;
  if (promptDialogState.mode === 'createSection') {
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
  if (promptDialogState.mode !== 'list') {
    const prompt = promptDialogState.mode === 'edit'
      ? prompts.find((item) => item.id === promptDialogState.promptID)
      : undefined;
    const sectionNames = [...promptSections]
      .sort((left, right) => left.localeCompare(right));
    content.innerHTML = `
      <form class="dashboard-prompt-form" data-prompt-form>
        <label>Name<input name="name" autocomplete="off" maxlength="80" placeholder="e.g. Review this code" value="${escapeHTML(prompt?.name || '')}" required /></label>
        <label>Section<input name="section" autocomplete="off" maxlength="80" list="dashboard-prompt-sections" placeholder="General" value="${escapeHTML(normalizePromptSection(prompt?.section))}" /><datalist id="dashboard-prompt-sections">${sectionNames.map((section) => `<option value="${escapeHTML(section)}"></option>`).join('')}</datalist></label>
        <label>Prompt<textarea name="content" rows="8" placeholder="Write the prompt you want to reuse…" required>${escapeHTML(prompt?.content || '')}</textarea></label>
        <div class="dashboard-prompt-form-actions">
          <button type="button" class="dashboard-prompt-secondary" data-prompt-cancel>Cancel</button>
          <button type="submit" class="dashboard-prompt-primary">Save prompt</button>
        </div>
      </form>`;
    content.querySelector('[name="name"]')?.focus();
    return;
  }
  const renderPromptRows = (prompts) => prompts.map((prompt) => `
    <article class="dashboard-prompt-row" data-prompt-row-id="${escapeHTML(prompt.id)}" draggable="true">
      <span class="dashboard-prompt-drag-handle" aria-hidden="true" title="Drag to reorder">⠿</span>
      <button type="button" class="dashboard-prompt-use" data-prompt-use="${escapeHTML(prompt.id)}">
        <strong>${escapeHTML(prompt.name)}</strong>
        <span>${escapeHTML(prompt.content)}</span>
      </button>
      <div class="dashboard-prompt-row-actions">
        <button type="button" data-prompt-edit="${escapeHTML(prompt.id)}" aria-label="Edit ${escapeHTML(prompt.name)}">Edit</button>
        <button type="button" data-prompt-delete="${escapeHTML(prompt.id)}" aria-label="Delete ${escapeHTML(prompt.name)}">Delete</button>
      </div>
    </article>`).join('');
  const groupedPrompts = new Map();
  promptSections.forEach((section) => groupedPrompts.set(section, []));
  prompts.forEach((prompt) => {
    const section = normalizePromptSection(prompt.section);
    if (!groupedPrompts.has(section)) groupedPrompts.set(section, []);
    groupedPrompts.get(section).push(prompt);
  });
  const orderedSections = [...groupedPrompts.entries()].sort(([left], [right]) => {
    if (left === 'General') return -1;
    if (right === 'General') return 1;
    return left.localeCompare(right);
  });
  const sections = orderedSections.map(([section, prompts], index) => {
    const collapsed = collapsedSections.has(section);
    const sectionBodyID = `dashboard-prompt-section-${index}`;
    return `
      <section class="dashboard-prompt-section${collapsed ? ' is-collapsed' : ''}" data-prompt-section="${escapeHTML(section)}">
        <button type="button" class="dashboard-prompt-section-toggle" data-prompt-section-toggle="${escapeHTML(section)}" aria-expanded="${String(!collapsed)}" aria-controls="${sectionBodyID}">
          <span class="dashboard-prompt-section-title"><span class="dashboard-prompt-section-chevron" aria-hidden="true">›</span><strong>${escapeHTML(section)}</strong></span>
          <span class="dashboard-prompt-section-count">${prompts.length}</span>
        </button>
        <div class="dashboard-prompt-section-body" id="${sectionBodyID}"${collapsed ? ' hidden' : ''}>${renderPromptRows(prompts)}</div>
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

function openPromptLibrary() {
  document.getElementById(elementIDs.promptDialog)?.remove();
  returnFocusElement = document.activeElement instanceof HTMLElement
    ? document.activeElement
    : undefined;
  promptDialogState = { mode: 'list' };
  const dialog = createPromptDialog();
  document.body.append(dialog);
  renderPromptLibrary();
}

function closePromptLibrary({ restoreFocus = true } = {}) {
  promptDialogState = { mode: 'list' };
  document.getElementById(elementIDs.promptDialog)?.remove();
  const returnFocus = returnFocusElement;
  returnFocusElement = undefined;
  if (restoreFocus && returnFocus?.isConnected) returnFocus.focus();
}

function findComposer() {
  const selectors = [
    'textarea[placeholder="Do anything"]',
    '[contenteditable="true"][data-placeholder="Do anything"]',
    '[contenteditable="true"][role="textbox"]',
    'textarea',
    '[contenteditable="true"]',
  ];
  return selectors.flatMap((selector) => [...document.querySelectorAll(selector)])
    .find((element) => (
      !element.closest(`#${elementIDs.promptDialog}`)
        && element.getClientRects().length > 0
    ));
}

function insertPromptIntoComposer(content) {
  const composer = findComposer();
  if (!composer) return false;
  composer.focus();
  if (composer instanceof HTMLTextAreaElement || composer instanceof HTMLInputElement) {
    const start = composer.selectionStart ?? composer.value.length;
    const end = composer.selectionEnd ?? start;
    const separator = start > 0 && !/\s$/.test(composer.value.slice(0, start)) ? '\n\n' : '';
    const nextValue = `${composer.value.slice(0, start)}${separator}${content}${composer.value.slice(end)}`;
    const valueSetter = Object.getOwnPropertyDescriptor(
      Object.getPrototypeOf(composer),
      'value',
    )?.set;
    valueSetter?.call(composer, nextValue);
    const nextCursor = start + separator.length + content.length;
    composer.setSelectionRange(nextCursor, nextCursor);
    // The value has already been replaced through the native setter. Sending the
    // prompt again as InputEvent.data makes some composer implementations treat
    // the notification as a second insertion.
    composer.dispatchEvent(new Event('input', { bubbles: true }));
    return true;
  }
  const selection = window.getSelection();
  if (!selection?.rangeCount || !composer.contains(selection.anchorNode)) {
    const range = document.createRange();
    range.selectNodeContents(composer);
    range.collapse(false);
    selection?.removeAllRanges();
    selection?.addRange(range);
  }
  const needsSeparator = Boolean(composer.textContent && !/\s$/.test(composer.textContent));
  return document.execCommand('insertText', false, `${needsSeparator ? '\n\n' : ''}${content}`);
}

function savePrompt(form) {
  const values = new FormData(form);
  const name = String(values.get('name') || '').trim();
  const content = String(values.get('content') || '').trim();
  if (!name || !content) return;
  const section = resolvePromptSection(values.get('section'));
  let nextPrompts;
  if (promptDialogState.mode === 'edit') {
    nextPrompts = prompts.map((prompt) => (
      prompt.id === promptDialogState.promptID ? { ...prompt, name, section, content } : prompt
    ));
  } else {
    nextPrompts = [...prompts, {
      id: globalThis.crypto?.randomUUID?.() || `prompt-${Date.now()}`,
      name,
      section,
      content,
    }];
  }
  if (!storePrompts(nextPrompts)) return;
  prompts = nextPrompts;
  if (!promptSections.includes(section)) {
    promptSections = [...promptSections, section];
  }
  promptDialogState = { mode: 'list' };
  renderPromptLibrary();
}

function createPromptSection(form) {
  const values = new FormData(form);
  const name = String(values.get('sectionName') || '').trim();
  if (!name) return;
  const section = resolvePromptSection(name);
  const nextSections = promptSections.includes(section)
    ? promptSections
    : [...promptSections, section];
  if (!storePromptSections(nextSections)) return;
  promptSections = nextSections;
  const nextCollapsedSections = new Set(collapsedSections);
  nextCollapsedSections.delete(section);
  storeCollapsedSections(nextCollapsedSections);
  collapsedSections = nextCollapsedSections;
  promptDialogState = { mode: 'list' };
  renderPromptLibrary();
  [...document.querySelectorAll('[data-prompt-section-toggle]')]
    .find((button) => button.dataset.promptSectionToggle === section)?.focus();
}

function activatePromptMenu(event, target) {
  const menuItem = target?.closest('[data-codex-prompt-menu-item]');
  const activatesMenuItem = ['pointerdown', 'mousedown', 'click'].includes(event.type)
    || (event.type === 'keydown' && ['Enter', ' '].includes(event.key));
  if (!menuItem || !activatesMenuItem) return false;
  event.preventDefault();
  event.stopImmediatePropagation();
  openPromptLibrary();
  return true;
}

function handlePromptKeyboard(event, dialog) {
  if (event.key === 'Escape') {
    event.preventDefault();
    event.stopImmediatePropagation();
    closePromptLibrary();
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
  if (target.closest('[data-prompt-close]')) closePromptLibrary();
  else if (target.closest('[data-prompt-section-toggle]')) {
    const toggle = target.closest('[data-prompt-section-toggle]');
    const section = toggle.dataset.promptSectionToggle;
    if (collapsedSections.has(section)) collapsedSections.delete(section);
    else collapsedSections.add(section);
    storeCollapsedSections();
    renderPromptLibrary();
    [...document.querySelectorAll('[data-prompt-section-toggle]')]
      .find((button) => button.dataset.promptSectionToggle === section)?.focus();
  } else if (target.closest('[data-prompt-new-section]')) {
    promptDialogState = { mode: 'createSection' };
    renderPromptLibrary();
  } else if (target.closest('[data-prompt-new]')) {
    promptDialogState = { mode: 'create' };
    renderPromptLibrary();
  } else if (target.closest('[data-prompt-cancel]')) {
    promptDialogState = { mode: 'list' };
    renderPromptLibrary();
  } else if (target.closest('[data-prompt-edit]')) {
    promptDialogState = {
      mode: 'edit',
      promptID: target.closest('[data-prompt-edit]').dataset.promptEdit,
    };
    renderPromptLibrary();
  } else if (target.closest('[data-prompt-delete-confirm]')) {
    const id = target.closest('[data-prompt-delete-confirm]').dataset.promptDeleteConfirm;
    const nextPrompts = prompts.filter((prompt) => prompt.id !== id);
    if (!storePrompts(nextPrompts)) return;
    prompts = nextPrompts;
    renderPromptLibrary();
  } else if (target.closest('[data-prompt-delete]')) {
    const button = target.closest('[data-prompt-delete]');
    button.dataset.promptDeleteConfirm = button.dataset.promptDelete;
    button.textContent = 'Confirm delete';
    button.setAttribute('aria-label', 'Confirm prompt deletion');
  } else if (target.closest('[data-prompt-use]')) {
    const id = target.closest('[data-prompt-use]').dataset.promptUse;
    const prompt = prompts.find((item) => item.id === id);
    if (prompt && insertPromptIntoComposer(prompt.content)) {
      closePromptLibrary({ restoreFocus: false });
    }
  }
}

function handlePromptInteraction(event) {
  const target = event.target instanceof Element ? event.target : null;
  if (activatePromptMenu(event, target)) return;
  if (
    event.type === 'keydown'
      && event.key === 'Escape'
      && document.getElementById(elementIDs.promptDialog)
  ) {
    handlePromptKeyboard(event, document.getElementById(elementIDs.promptDialog));
    return;
  }
  const dialog = target?.closest(`#${elementIDs.promptDialog}`);
  if (!dialog) return;
  if (handlePromptDrag(event, target, dialog)) return;
  if (event.type === 'keydown') handlePromptKeyboard(event, dialog);
  else if (event.type === 'submit') handlePromptSubmit(event, target);
  else if (event.type === 'click') handlePromptClick(target);
}

function mountPromptLibrary() {
  syncPromptMenuItem();
  promptInteractionEventTypes.forEach((type) => {
    document.addEventListener(type, handlePromptInteraction, true);
  });
}

function unmountPromptLibrary() {
  promptInteractionEventTypes.forEach((type) => {
    document.removeEventListener(type, handlePromptInteraction, true);
  });
  promptMenuSyncQueued = false;
  closePromptLibrary({ restoreFocus: false });
  document.querySelectorAll('[data-codex-prompt-menu-item]').forEach((item) => item.remove());
}
