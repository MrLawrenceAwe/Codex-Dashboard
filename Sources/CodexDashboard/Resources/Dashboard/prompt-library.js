let savedPrompts = loadSavedPrompts();
let promptMenuSyncQueued = false;
let promptEditorState = { mode: 'list' };

function loadSavedPrompts() {
  try {
    const value = JSON.parse(localStorage.getItem(promptStorageKey) || '[]');
    if (!Array.isArray(value)) return [];
    return value.filter((prompt) => (
      prompt && typeof prompt.id === 'string'
        && typeof prompt.name === 'string'
        && typeof prompt.content === 'string'
    ));
  } catch (_) {
    return [];
  }
}

function persistSavedPrompts() {
  try {
    localStorage.setItem(promptStorageKey, JSON.stringify(savedPrompts));
  } catch (_) {
    // Prompt editing remains usable for the current renderer session if storage is unavailable.
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
      <div data-prompt-content></div>
    </section>`;
  return dialog;
}

function renderPromptLibrary() {
  const dialog = document.getElementById(elementIDs.promptDialog);
  const content = dialog?.querySelector('[data-prompt-content]');
  if (!content) return;
  if (promptEditorState.mode !== 'list') {
    const prompt = promptEditorState.mode === 'edit'
      ? savedPrompts.find((item) => item.id === promptEditorState.promptID)
      : undefined;
    content.innerHTML = `
      <form class="dashboard-prompt-form" data-prompt-form>
        <label>Name<input name="name" autocomplete="off" maxlength="80" placeholder="e.g. Review this code" value="${escapeHTML(prompt?.name || '')}" required /></label>
        <label>Prompt<textarea name="content" rows="8" placeholder="Write the prompt you want to reuse…" required>${escapeHTML(prompt?.content || '')}</textarea></label>
        <div class="dashboard-prompt-form-actions">
          <button type="button" class="dashboard-prompt-secondary" data-prompt-cancel>Cancel</button>
          <button type="submit" class="dashboard-prompt-primary">Save prompt</button>
        </div>
      </form>`;
    content.querySelector('[name="name"]')?.focus();
    return;
  }
  const rows = savedPrompts.map((prompt) => `
    <article class="dashboard-prompt-row">
      <button type="button" class="dashboard-prompt-use" data-prompt-use="${escapeHTML(prompt.id)}">
        <strong>${escapeHTML(prompt.name)}</strong>
        <span>${escapeHTML(prompt.content)}</span>
      </button>
      <div class="dashboard-prompt-row-actions">
        <button type="button" data-prompt-edit="${escapeHTML(prompt.id)}" aria-label="Edit ${escapeHTML(prompt.name)}">Edit</button>
        <button type="button" data-prompt-delete="${escapeHTML(prompt.id)}" aria-label="Delete ${escapeHTML(prompt.name)}">Delete</button>
      </div>
    </article>`).join('');
  content.innerHTML = `
    <div class="dashboard-prompt-list">
      ${rows || '<div class="dashboard-prompt-empty"><strong>No saved prompts yet</strong><span>Save instructions you use often, then insert them into a chat in one click.</span></div>'}
    </div>
    <button type="button" class="dashboard-prompt-new" data-prompt-new>+ New prompt</button>`;
  content.querySelector('[data-prompt-use], [data-prompt-new]')?.focus();
}

function openPromptLibrary() {
  document.getElementById(elementIDs.promptDialog)?.remove();
  promptEditorState = { mode: 'list' };
  const dialog = createPromptDialog();
  document.body.append(dialog);
  renderPromptLibrary();
}

function closePromptLibrary() {
  promptEditorState = { mode: 'list' };
  document.getElementById(elementIDs.promptDialog)?.remove();
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
    composer.dispatchEvent(new InputEvent('input', { bubbles: true, inputType: 'insertText', data: content }));
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
  if (promptEditorState.mode === 'edit') {
    savedPrompts = savedPrompts.map((prompt) => (
      prompt.id === promptEditorState.promptID ? { ...prompt, name, content } : prompt
    ));
  } else {
    savedPrompts = [...savedPrompts, {
      id: globalThis.crypto?.randomUUID?.() || `prompt-${Date.now()}`,
      name,
      content,
    }];
  }
  persistSavedPrompts();
  promptEditorState = { mode: 'list' };
  renderPromptLibrary();
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
  const dialog = target?.closest(`#${elementIDs.promptDialog}`);
  if (!dialog) return;
  if (event.type === 'keydown' && event.key === 'Escape') {
    event.preventDefault();
    closePromptLibrary();
    return;
  }
  if (event.type === 'submit' && target.matches('[data-prompt-form]')) {
    event.preventDefault();
    savePrompt(target);
    return;
  }
  if (event.type !== 'click') return;
  if (target.closest('[data-prompt-close]')) closePromptLibrary();
  else if (target.closest('[data-prompt-new]')) {
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
    savedPrompts = savedPrompts.filter((prompt) => prompt.id !== id);
    persistSavedPrompts();
    renderPromptLibrary();
  } else if (target.closest('[data-prompt-delete]')) {
    const button = target.closest('[data-prompt-delete]');
    button.dataset.promptDeleteConfirm = button.dataset.promptDelete;
    button.textContent = 'Confirm delete';
    button.setAttribute('aria-label', 'Confirm prompt deletion');
  } else if (target.closest('[data-prompt-use]')) {
    const id = target.closest('[data-prompt-use]').dataset.promptUse;
    const prompt = savedPrompts.find((item) => item.id === id);
    if (prompt && insertPromptIntoComposer(prompt.content)) closePromptLibrary();
  }
}

