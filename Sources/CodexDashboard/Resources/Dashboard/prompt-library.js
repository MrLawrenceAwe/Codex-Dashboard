const promptSectionStorageKey = 'codex-dashboard.collapsed-prompt-sections';
const savedPromptSectionsStorageKey = 'codex-dashboard.prompt-sections';
let savedPrompts = loadSavedPrompts();
let savedPromptSections = loadSavedPromptSections();
let promptMenuSyncQueued = false;
let promptEditorState = { mode: 'list' };
let draggedPromptID;
let collapsedPromptSections = loadCollapsedPromptSections();
let promptDialogReturnFocus;

function normalizePromptSection(value) {
  return String(value || '').trim() || 'General';
}

function loadSavedPrompts() {
  try {
    const value = JSON.parse(localStorage.getItem(promptStorageKey) || '[]');
    if (!Array.isArray(value)) return [];
    return value.filter((prompt) => (
      prompt && typeof prompt.id === 'string'
        && typeof prompt.name === 'string'
        && typeof prompt.content === 'string'
    )).map((prompt) => ({
      ...prompt,
      section: normalizePromptSection(prompt.section),
    }));
  } catch (_) {
    return [];
  }
}

function loadCollapsedPromptSections() {
  try {
    const value = JSON.parse(localStorage.getItem(promptSectionStorageKey) || '[]');
    return new Set(Array.isArray(value) ? value.filter((item) => typeof item === 'string') : []);
  } catch (_) {
    return new Set();
  }
}

function loadSavedPromptSections() {
  let storedSections = [];
  try {
    const value = JSON.parse(localStorage.getItem(savedPromptSectionsStorageKey) || '[]');
    if (Array.isArray(value)) storedSections = value.filter((item) => typeof item === 'string');
  } catch (_) {
    // Existing prompt sections still seed the list if section storage is unavailable.
  }
  return [...new Set([
    ...storedSections.map(normalizePromptSection),
    ...savedPrompts.map((prompt) => normalizePromptSection(prompt.section)),
  ])];
}

function showPromptStorageError() {
  const error = document.querySelector('[data-prompt-storage-error]');
  if (error) error.hidden = false;
}

function persistSavedPromptSections(sections = savedPromptSections) {
  try {
    localStorage.setItem(savedPromptSectionsStorageKey, JSON.stringify(sections));
    return true;
  } catch (_) {
    showPromptStorageError();
    return false;
  }
}

function resolveSavedPromptSection(section) {
  const normalizedSection = normalizePromptSection(section);
  const existingSection = savedPromptSections.find(
    (item) => item.localeCompare(normalizedSection, undefined, { sensitivity: 'accent' }) === 0,
  );
  return existingSection || normalizedSection;
}

function persistCollapsedPromptSections(sections = collapsedPromptSections) {
  try {
    localStorage.setItem(promptSectionStorageKey, JSON.stringify([...sections]));
    return true;
  } catch (_) {
    return false;
  }
}

function persistSavedPrompts(prompts = savedPrompts) {
  try {
    localStorage.setItem(promptStorageKey, JSON.stringify(prompts));
    return true;
  } catch (_) {
    showPromptStorageError();
    return false;
  }
}

function findPromptMenuAnchor() {
  const interactiveLabel = [...document.querySelectorAll('button, [role="menuitem"]')]
    .find((element) => textIs(element, 'Record a skill'));
  const exactLabels = [...document.querySelectorAll('span, div')]
    .filter((element) => textIs(element, 'Record a skill'));
  const label = interactiveLabel || exactLabels.at(-1);
  if (!label) return null;
  const menu = label.closest('[data-composer-overlay-floating-ui], [role="menu"], [data-radix-menu-content], [data-slot="dropdown-menu-content"]')
    || [...function* ancestors() {
      let current = label.parentElement;
      while (current && current !== document.body) {
        yield current;
        current = current.parentElement;
      }
    }()].find((element) => (
      element.textContent.includes('Work in a project')
        && element.textContent.includes('Plan mode')
    ));
  if (!menu || menu.closest(`#${elementIDs.promptDialog}`)) return null;
  let row = label.closest('button, [role="menuitem"]');
  if (!row) {
    row = label;
    while (row.parentElement !== menu && row.parentElement) {
      const parent = row.parentElement;
      if (parent.textContent.trim() !== 'Record a skill') break;
      row = parent;
    }
  }
  return row?.parentElement ? row : null;
}

function replaceExactText(root, from, to) {
  const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
  while (walker.nextNode()) {
    if (walker.currentNode.nodeValue.trim() === from) {
      walker.currentNode.nodeValue = walker.currentNode.nodeValue.replace(from, to);
      return true;
    }
  }
  return false;
}

function setPromptMenuItemHighlighted(item, highlighted) {
  if (highlighted) {
    const menu = item.closest('[data-composer-overlay-floating-ui], [role="menu"]');
    menu?.querySelectorAll('[data-list-navigation-item]').forEach((row) => {
      row.classList.remove('bg-token-list-hover-background', 'opacity-100');
    });
    item.classList.add('bg-token-list-hover-background', 'opacity-100');
    return;
  }
  item.classList.remove('bg-token-list-hover-background', 'opacity-100');
}

function removeHostActionAttributes(root) {
  [root, ...root.querySelectorAll('*')].forEach((element) => {
    [...element.attributes].forEach((attribute) => {
      if (attribute.name === 'id' || attribute.name.startsWith('data-app-action')) {
        element.removeAttribute(attribute.name);
      }
    });
  });
}

function createPromptMenuItem(anchor) {
  const item = anchor.cloneNode(true);
  removeHostActionAttributes(item);
  item.dataset.codexPromptMenuItem = '';
  item.setAttribute('aria-label', 'Prompts');
  item.setAttribute('role', anchor.getAttribute('role') || 'menuitem');
  item.setAttribute('tabindex', '0');
  item.classList.remove('bg-token-list-hover-background', 'opacity-100');
  item.addEventListener('pointerenter', () => setPromptMenuItemHighlighted(item, true));
  item.addEventListener('pointerleave', () => setPromptMenuItemHighlighted(item, false));
  item.addEventListener('focus', () => setPromptMenuItemHighlighted(item, true));
  item.addEventListener('blur', () => setPromptMenuItemHighlighted(item, false));
  replaceExactText(item, 'Record a skill', 'Prompts');
  const svg = item.querySelector('svg');
  if (svg) {
    svg.setAttribute('viewBox', '0 0 24 24');
    svg.setAttribute('fill', 'none');
    svg.setAttribute('stroke', 'currentColor');
    svg.setAttribute('stroke-width', '1.8');
    svg.innerHTML = '<path d="M5 5.5A2.5 2.5 0 0 1 7.5 3h9A2.5 2.5 0 0 1 19 5.5v7a2.5 2.5 0 0 1-2.5 2.5H11l-4.5 4v-4A2.5 2.5 0 0 1 5 12.5z"/><path d="M8.5 7.5h7M8.5 10.5h4.5"/>';
  }
  anchor.after(item);
}

function syncPromptMenuItem() {
  promptMenuSyncQueued = false;
  if (document.querySelector('[data-codex-prompt-menu-item]')) return;
  const anchor = findPromptMenuAnchor();
  if (anchor) createPromptMenuItem(anchor);
}

function schedulePromptMenuSync() {
  if (promptMenuSyncQueued) return;
  promptMenuSyncQueued = true;
  queueMicrotask(syncPromptMenuItem);
}

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
  if (promptEditorState.mode === 'createSection') {
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
  if (promptEditorState.mode !== 'list') {
    const prompt = promptEditorState.mode === 'edit'
      ? savedPrompts.find((item) => item.id === promptEditorState.promptID)
      : undefined;
    const sectionNames = [...savedPromptSections]
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
  savedPromptSections.forEach((section) => groupedPrompts.set(section, []));
  savedPrompts.forEach((prompt) => {
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
    const collapsed = collapsedPromptSections.has(section);
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
  promptDialogReturnFocus = document.activeElement instanceof HTMLElement
    ? document.activeElement
    : undefined;
  promptEditorState = { mode: 'list' };
  const dialog = createPromptDialog();
  document.body.append(dialog);
  renderPromptLibrary();
}

function closePromptLibrary({ restoreFocus = true } = {}) {
  promptEditorState = { mode: 'list' };
  document.getElementById(elementIDs.promptDialog)?.remove();
  const returnFocus = promptDialogReturnFocus;
  promptDialogReturnFocus = undefined;
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
  const section = resolveSavedPromptSection(values.get('section'));
  let nextPrompts;
  if (promptEditorState.mode === 'edit') {
    nextPrompts = savedPrompts.map((prompt) => (
      prompt.id === promptEditorState.promptID ? { ...prompt, name, section, content } : prompt
    ));
  } else {
    nextPrompts = [...savedPrompts, {
      id: globalThis.crypto?.randomUUID?.() || `prompt-${Date.now()}`,
      name,
      section,
      content,
    }];
  }
  if (!persistSavedPrompts(nextPrompts)) return;
  savedPrompts = nextPrompts;
  if (!savedPromptSections.includes(section)) {
    savedPromptSections = [...savedPromptSections, section];
  }
  promptEditorState = { mode: 'list' };
  renderPromptLibrary();
}

function savePromptSection(form) {
  const values = new FormData(form);
  const name = String(values.get('sectionName') || '').trim();
  if (!name) return;
  const section = resolveSavedPromptSection(name);
  const nextSections = savedPromptSections.includes(section)
    ? savedPromptSections
    : [...savedPromptSections, section];
  if (!persistSavedPromptSections(nextSections)) return;
  savedPromptSections = nextSections;
  const nextCollapsedSections = new Set(collapsedPromptSections);
  nextCollapsedSections.delete(section);
  persistCollapsedPromptSections(nextCollapsedSections);
  collapsedPromptSections = nextCollapsedSections;
  promptEditorState = { mode: 'list' };
  renderPromptLibrary();
  [...document.querySelectorAll('[data-prompt-section-toggle]')]
    .find((button) => button.dataset.promptSectionToggle === section)?.focus();
}

function clearPromptDropIndicators(dialog) {
  dialog?.querySelectorAll('.is-drop-before, .is-drop-after, .is-drop-target').forEach((element) => {
    element.classList.remove('is-drop-before', 'is-drop-after', 'is-drop-target');
  });
}

function promptDropDestination(target) {
  const row = target?.closest('[data-prompt-row-id]');
  const sectionElement = target?.closest('[data-prompt-section]');
  return sectionElement ? {
    row,
    section: sectionElement.dataset.promptSection,
    sectionElement,
  } : null;
}

function movePromptFromDrop(destination, dropAfter) {
  const movingPrompt = savedPrompts.find((prompt) => prompt.id === draggedPromptID);
  if (!movingPrompt || !destination?.section) return false;
  if (destination.row?.dataset.promptRowId === draggedPromptID) return false;

  const remainingPrompts = savedPrompts.filter((prompt) => prompt.id !== draggedPromptID);
  const movedPrompt = { ...movingPrompt, section: normalizePromptSection(destination.section) };
  const targetPromptID = destination.row?.dataset.promptRowId;
  let insertionIndex;
  if (targetPromptID) {
    insertionIndex = remainingPrompts.findIndex((prompt) => prompt.id === targetPromptID);
    if (insertionIndex < 0) insertionIndex = remainingPrompts.length;
    else if (dropAfter) insertionIndex += 1;
  } else {
    insertionIndex = remainingPrompts.reduce((lastIndex, prompt, index) => (
      normalizePromptSection(prompt.section) === movedPrompt.section ? index + 1 : lastIndex
    ), remainingPrompts.length);
  }
  remainingPrompts.splice(insertionIndex, 0, movedPrompt);
  if (!persistSavedPrompts(remainingPrompts)) return false;
  savedPrompts = remainingPrompts;
  return true;
}

function handlePromptDrag(event, target, dialog) {
  if (event.type === 'dragstart') {
    const row = target?.closest('[data-prompt-row-id]');
    if (!row) return false;
    draggedPromptID = row.dataset.promptRowId;
    row.classList.add('is-dragging');
    if (event.dataTransfer) {
      event.dataTransfer.effectAllowed = 'move';
      event.dataTransfer.setData('text/plain', draggedPromptID);
    }
    return true;
  }
  if (!draggedPromptID) return false;
  if (event.type === 'dragend') {
    clearPromptDropIndicators(dialog);
    dialog?.querySelector('.is-dragging')?.classList.remove('is-dragging');
    draggedPromptID = undefined;
    return true;
  }
  const destination = promptDropDestination(target);
  if (!destination) return false;
  if (event.type === 'dragover') {
    event.preventDefault();
    if (event.dataTransfer) event.dataTransfer.dropEffect = 'move';
    clearPromptDropIndicators(dialog);
    if (destination.row && destination.row.dataset.promptRowId !== draggedPromptID) {
      const dropAfter = event.clientY > destination.row.getBoundingClientRect().top
        + destination.row.getBoundingClientRect().height / 2;
      destination.row.classList.add(dropAfter ? 'is-drop-after' : 'is-drop-before');
    } else {
      destination.sectionElement.classList.add('is-drop-target');
    }
    return true;
  }
  if (event.type === 'dragleave') return true;
  if (event.type === 'drop') {
    event.preventDefault();
    const dropAfter = Boolean(
      destination.row
        && event.clientY > destination.row.getBoundingClientRect().top
          + destination.row.getBoundingClientRect().height / 2
    );
    const moved = movePromptFromDrop(destination, dropAfter);
    draggedPromptID = undefined;
    if (moved) renderPromptLibrary();
    else clearPromptDropIndicators(dialog);
    return true;
  }
  return false;
}

function handlePromptInteraction(event) {
  const target = event.target instanceof Element ? event.target : null;
  const menuItem = target?.closest('[data-codex-prompt-menu-item]');
  const activatesMenuItem = ['pointerdown', 'mousedown', 'click'].includes(event.type)
    || (event.type === 'keydown' && ['Enter', ' '].includes(event.key));
  if (menuItem && activatesMenuItem) {
    event.preventDefault();
    event.stopImmediatePropagation();
    openPromptLibrary();
    return;
  }
  if (
    event.type === 'keydown'
      && event.key === 'Escape'
      && document.getElementById(elementIDs.promptDialog)
  ) {
    event.preventDefault();
    event.stopImmediatePropagation();
    closePromptLibrary();
    return;
  }
  const dialog = target?.closest(`#${elementIDs.promptDialog}`);
  if (!dialog) return;
  if (handlePromptDrag(event, target, dialog)) return;
  if (event.type === 'keydown' && event.key === 'Tab') {
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
    return;
  }
  if (event.type === 'submit') {
    if (target.matches('[data-prompt-form]')) {
      event.preventDefault();
      savePrompt(target);
      return;
    }
    if (target.matches('[data-prompt-section-form]')) {
      event.preventDefault();
      savePromptSection(target);
      return;
    }
  }
  if (event.type !== 'click') return;
  if (target.closest('[data-prompt-close]')) closePromptLibrary();
  else if (target.closest('[data-prompt-section-toggle]')) {
    const section = target.closest('[data-prompt-section-toggle]').dataset.promptSectionToggle;
    if (collapsedPromptSections.has(section)) collapsedPromptSections.delete(section);
    else collapsedPromptSections.add(section);
    persistCollapsedPromptSections();
    renderPromptLibrary();
    [...document.querySelectorAll('[data-prompt-section-toggle]')]
      .find((button) => button.dataset.promptSectionToggle === section)?.focus();
  } else if (target.closest('[data-prompt-new-section]')) {
    promptEditorState = { mode: 'createSection' };
    renderPromptLibrary();
  } else if (target.closest('[data-prompt-new]')) {
    promptEditorState = { mode: 'create' };
    renderPromptLibrary();
  } else if (target.closest('[data-prompt-cancel]')) {
    promptEditorState = { mode: 'list' };
    renderPromptLibrary();
  } else if (target.closest('[data-prompt-edit]')) {
    promptEditorState = {
      mode: 'edit',
      promptID: target.closest('[data-prompt-edit]').dataset.promptEdit,
    };
    renderPromptLibrary();
  } else if (target.closest('[data-prompt-delete-confirm]')) {
    const id = target.closest('[data-prompt-delete-confirm]').dataset.promptDeleteConfirm;
    const nextPrompts = savedPrompts.filter((prompt) => prompt.id !== id);
    if (!persistSavedPrompts(nextPrompts)) return;
    savedPrompts = nextPrompts;
    renderPromptLibrary();
  } else if (target.closest('[data-prompt-delete]')) {
    const button = target.closest('[data-prompt-delete]');
    button.dataset.promptDeleteConfirm = button.dataset.promptDelete;
    button.textContent = 'Confirm delete';
    button.setAttribute('aria-label', 'Confirm prompt deletion');
  } else if (target.closest('[data-prompt-use]')) {
    const id = target.closest('[data-prompt-use]').dataset.promptUse;
    const prompt = savedPrompts.find((item) => item.id === id);
    if (prompt && insertPromptIntoComposer(prompt.content)) {
      closePromptLibrary({ restoreFocus: false });
    }
  }
}
