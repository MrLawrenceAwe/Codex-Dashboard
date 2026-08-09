const promptLibraryStorageKey = 'codex-dashboard.prompt-library';
const legacyPromptStorageKey = 'codex-dashboard.saved-prompts';
const collapsedSectionsStorageKey = 'codex-dashboard.collapsed-prompt-sections';
const legacyPromptSectionsStorageKey = 'codex-dashboard.prompt-sections';
const initialPromptLibrary = loadPromptLibrary();
let prompts = initialPromptLibrary.prompts;
let promptSections = initialPromptLibrary.sections;
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

function normalizeStoredPrompts(storedPrompts) {
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

function normalizeStoredSections(storedSections, storedPrompts) {
  const sections = Array.isArray(storedSections)
    ? storedSections.filter((item) => typeof item === 'string')
    : [];
  return [...new Set([
    ...sections.map(normalizePromptSection),
    ...storedPrompts.map((prompt) => normalizePromptSection(prompt.section)),
  ])];
}

function loadPromptLibrary() {
  const storedLibrary = readStoredJSON(promptLibraryStorageKey, null);
  if (storedLibrary && typeof storedLibrary === 'object') {
    const storedPrompts = normalizeStoredPrompts(storedLibrary.prompts);
    return {
      prompts: storedPrompts,
      sections: normalizeStoredSections(storedLibrary.sections, storedPrompts),
    };
  }

  const legacyPrompts = normalizeStoredPrompts(readStoredJSON(legacyPromptStorageKey, []));
  const migratedLibrary = {
    prompts: legacyPrompts,
    sections: normalizeStoredSections(
      readStoredJSON(legacyPromptSectionsStorageKey, []),
      legacyPrompts,
    ),
  };
  writeStoredJSON(promptLibraryStorageKey, migratedLibrary, false);
  return migratedLibrary;
}

function showPromptStorageError() {
  const error = document.querySelector('[data-prompt-storage-error]');
  if (error) error.hidden = false;
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

function storePromptLibrary(nextPrompts = prompts, nextSections = promptSections) {
  return writeStoredJSON(promptLibraryStorageKey, {
    prompts: nextPrompts,
    sections: normalizeStoredSections(nextSections, nextPrompts),
  });
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
  const nextSections = promptSections.includes(section)
    ? promptSections
    : [...promptSections, section];
  if (!storePromptLibrary(nextPrompts, nextSections)) return;
  prompts = nextPrompts;
  promptSections = nextSections;
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
  if (!storePromptLibrary(prompts, nextSections)) return;
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
    if (!storePromptLibrary(nextPrompts, promptSections)) return;
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

function reorderPrompt(destination, dropAfter) {
  const movingPrompt = prompts.find((prompt) => prompt.id === draggedPromptID);
  if (!movingPrompt || !destination?.section) return false;
  if (destination.row?.dataset.promptRowId === draggedPromptID) return false;

  const remainingPrompts = prompts.filter((prompt) => prompt.id !== draggedPromptID);
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
  if (!storePromptLibrary(remainingPrompts, promptSections)) return false;
  prompts = remainingPrompts;
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
    const moved = reorderPrompt(destination, dropAfter);
    draggedPromptID = undefined;
    if (moved) renderPromptLibrary();
    else clearPromptDropIndicators(dialog);
    return true;
  }
  return false;
}
