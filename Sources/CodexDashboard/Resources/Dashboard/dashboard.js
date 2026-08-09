const existing = window.__codexDashboard;
if (existing?.version === DASHBOARD_VERSION) {
  return existing.ensureMounted();
}
existing?.destroy?.();

const elementIDs = {
  style: 'codex-dashboard-style',
  navButton: 'codex-dashboard-navigation',
  page: 'codex-dashboard-page',
  promptDialog: 'codex-dashboard-prompt-dialog',
};

const promptStorageKey = 'codex-dashboard.saved-prompts';

const host = {
  sidebar() {
    return document.querySelector('aside.app-shell-left-panel, aside');
  },

  pageHost() {
    return this.sidebar()?.parentElement || document.body;
  },

  navigationInsertionPoint() {
    const navigation = document.querySelector('nav, [role="navigation"]');
    if (!navigation) return null;
    const buttons = [...navigation.querySelectorAll('button')];
    const newChat = buttons.find((button) => button.textContent.trim() === 'New chat');
    const newChatRow = newChat?.closest('.sidebar-item');
    if (newChatRow?.parentElement) return { element: newChatRow, insertAfter: true };
    const fallbackButton = buttons.find((button) => button.textContent.trim() === 'Pull requests')
      || buttons.find((button) => button.classList.contains('sidebar-item'));
    return fallbackButton?.parentElement ? { element: fallbackButton, insertAfter: false } : null;
  },

  unreadThreadIDs() {
    const unreadIDs = new Set();
    document.querySelectorAll('[data-app-action-sidebar-thread-id]').forEach((row) => {
      const fiberKey = Object.keys(row).find((key) => key.startsWith('__reactFiber$'));
      let fiber = fiberKey ? row[fiberKey] : null;
      while (fiber) {
        const props = fiber.memoizedProps || fiber.pendingProps;
        if (
          typeof props?.conversationId === 'string'
          && typeof props?.isUnread === 'boolean'
        ) {
          if (props.isUnread) unreadIDs.add(props.conversationId);
          break;
        }
        fiber = fiber.return;
      }
    });
    return unreadIDs;
  },

  navigateToThread(thread) {
    const threadKey = `local:${thread.id}`;
    const sidebarThreadButton = document.querySelector(
      `[data-app-action-sidebar-thread-id="${CSS.escape(threadKey)}"]`,
    );
    if (sidebarThreadButton) {
      sidebarThreadButton.click();
      return;
    }
    window.dispatchEvent(new MessageEvent('message', {
      data: {
        type: 'navigate-to-route',
        path: `/local/${encodeURIComponent(thread.id)}`,
      },
      source: null,
    }));
  },
};

let threads = [];
let filterMode = 'all';
let searchTerm = '';
let groupingMode = 'projects';
const collapsedProjects = new Set();
let mutationObserver;
let resizeObserver;
let observedSidebar;
let mutationFrame;
let pendingSidebarMutation = false;
let isOpen = false;
let unreadThreadIDs = new Set();
let savedPrompts = loadSavedPrompts();
let promptMenuSyncQueued = false;
let promptDraftID;

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

function syncUnreadFromSidebar() {
  const nextUnreadThreadIDs = host.unreadThreadIDs();
  const changed = nextUnreadThreadIDs.size !== unreadThreadIDs.size
    || [...nextUnreadThreadIDs].some((id) => !unreadThreadIDs.has(id));
  unreadThreadIDs = nextUnreadThreadIDs;
  return changed;
}

function isThreadUnread(thread) {
  return unreadThreadIDs.has(thread.id);
}

function handleHostNavigation(event) {
  const eventTarget = event.target instanceof Element ? event.target : null;
  if (eventTarget?.closest(`#${elementIDs.navButton}`)) {
    event.preventDefault();
    event.stopPropagation();
    if (event.type === 'click') openPage();
    return;
  }
  if (event.type !== 'click' || !isOpen) return;
  if (eventTarget?.closest('aside') && !eventTarget.closest(`#${elementIDs.navButton}`)) closePage();
}

function iconSvg(name) {
  const paths = {
    threads: '<path d="M8 6h12M8 12h12M8 18h12M3.5 6h.01M3.5 12h.01M3.5 18h.01"/>',
    project: '<path d="M3 7.5A1.5 1.5 0 0 1 4.5 6h5l2 2H19.5A1.5 1.5 0 0 1 21 9.5v8A1.5 1.5 0 0 1 19.5 19h-15A1.5 1.5 0 0 1 3 17.5z"/>',
    arrow: '<path d="M5 12h14m-5-5 5 5-5 5"/>',
    search: '<circle cx="11" cy="11" r="6"/><path d="m16 16 4 4"/>',
    pin: '<path d="m9 3 6 0-1 6 3 3v2H7v-2l3-3zM12 14v7"/>',
    gitChanges: '<circle cx="6" cy="5" r="2"/><circle cx="18" cy="6" r="2"/><circle cx="6" cy="19" r="2"/><path d="M6 7v10M8 6h5a5 5 0 0 1 5 5v-3"/>',
    chevron: '<path d="m9 18 6-6-6-6"/>',
  };
  return `<svg aria-hidden="true" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round">${paths[name]}</svg>`;
}

function escapeHTML(value) {
  return String(value ?? '').replace(/[&<>'"]/g, (character) => ({
    '&': '&amp;', '<': '&lt;', '>': '&gt;', "'": '&#39;', '"': '&quot;',
  })[character]);
}

function textIs(element, value) {
  return element?.textContent?.trim() === value;
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

function createPromptMenuItem(anchor) {
  const item = anchor.cloneNode(true);
  item.querySelectorAll('*').forEach((element) => {
    [...element.attributes].forEach((attribute) => {
      if (attribute.name === 'id' || attribute.name.startsWith('data-app-action')) {
        element.removeAttribute(attribute.name);
      }
    });
  });
  [...item.attributes].forEach((attribute) => {
    if (attribute.name === 'id' || attribute.name.startsWith('data-app-action')) {
      item.removeAttribute(attribute.name);
    }
  });
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

function promptDialogHTML() {
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
  if (promptDraftID !== undefined) {
    const prompt = savedPrompts.find((item) => item.id === promptDraftID);
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
  promptDraftID = undefined;
  const dialog = promptDialogHTML();
  document.body.append(dialog);
  renderPromptLibrary();
}

function closePromptLibrary() {
  promptDraftID = undefined;
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
  if (promptDraftID) {
    savedPrompts = savedPrompts.map((prompt) => (
      prompt.id === promptDraftID ? { ...prompt, name, content } : prompt
    ));
  } else {
    savedPrompts = [...savedPrompts, {
      id: globalThis.crypto?.randomUUID?.() || `prompt-${Date.now()}`,
      name,
      content,
    }];
  }
  persistSavedPrompts();
  promptDraftID = undefined;
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
    promptDraftID = null;
    renderPromptLibrary();
  } else if (target.closest('[data-prompt-cancel]')) {
    promptDraftID = undefined;
    renderPromptLibrary();
  } else if (target.closest('[data-prompt-edit]')) {
    promptDraftID = target.closest('[data-prompt-edit]').dataset.promptEdit;
    renderPromptLibrary();
  } else if (target.closest('[data-prompt-delete]')) {
    const id = target.closest('[data-prompt-delete]').dataset.promptDelete;
    savedPrompts = savedPrompts.filter((prompt) => prompt.id !== id);
    persistSavedPrompts();
    renderPromptLibrary();
  } else if (target.closest('[data-prompt-use]')) {
    const id = target.closest('[data-prompt-use]').dataset.promptUse;
    const prompt = savedPrompts.find((item) => item.id === id);
    if (prompt && insertPromptIntoComposer(prompt.content)) closePromptLibrary();
  }
}

function relativeTime(unixSeconds) {
  const seconds = Math.max(0, Math.round(Date.now() / 1000 - Number(unixSeconds || 0)));
  if (seconds < 60) return 'just now';
  const minutes = Math.floor(seconds / 60);
  if (minutes < 60) return `${minutes}m ago`;
  const hours = Math.floor(minutes / 60);
  if (hours < 24) return `${hours}h ago`;
  const days = Math.floor(hours / 24);
  return `${days}d ago`;
}

function getVisibleThreads() {
  const query = searchTerm.trim().toLowerCase();
  const uncommittedProjectPaths = new Set(
    threads
      .filter((thread) => thread.gitStatus === 'modified')
      .map((thread) => String(thread.workspacePath).trim()),
  );
  return threads.filter((thread) => {
    const matchesFilter = filterMode === 'all'
      || (filterMode === 'unread' && isThreadUnread(thread))
      || (filterMode === 'uncommitted'
        && uncommittedProjectPaths.has(String(thread.workspacePath).trim()));
    const matchesSearch = !query || `${thread.title} ${thread.preview} ${thread.workspace} ${thread.workspacePath}`.toLowerCase().includes(query);
    return matchesFilter && matchesSearch;
  });
}

function openThread(thread) {
  closePage();
  host.navigateToThread(thread);
}

function renderThreadHTML(thread, showProject = false) {
  const unread = isThreadUnread(thread);
  return `
    <article class="dashboard-thread" data-activity="${escapeHTML(thread.activity)}" data-unread="${String(unread)}" data-thread-id="${escapeHTML(thread.id)}">
      <div class="dashboard-status-dot" title="${escapeHTML(thread.activity)}"></div>
      <div class="dashboard-thread-copy">
        <div class="dashboard-thread-title-row">
          ${unread ? '<span class="dashboard-unread-dot" role="status" aria-label="Unread response" title="Unread response"></span>' : ''}
          <h2>${escapeHTML(thread.title)}</h2>
          ${thread.isPinned ? `<span class="dashboard-pin" title="Pinned">${iconSvg('pin')}</span>` : ''}
        </div>
        <p>${escapeHTML(thread.preview || 'No preview available')}</p>
        <div class="dashboard-meta">
          ${showProject ? `<span>${escapeHTML(thread.workspace)}</span>` : ''}
          <span>${relativeTime(thread.updatedAtUnixSeconds)}</span>
          ${thread.model ? `<span>${escapeHTML(thread.model)}</span>` : ''}
        </div>
      </div>
      <div class="dashboard-thread-actions">
        ${thread.activity === 'running' ? '<span class="dashboard-running-spinner" role="status" aria-label="Running" title="Running"></span>' : ''}
        <button type="button" data-open-thread="${escapeHTML(thread.id)}">Open ${iconSvg('arrow')}</button>
      </div>
    </article>`;
}

function renderThreadListHTML(visibleThreads) {
  if (groupingMode === 'updated') {
    return [...visibleThreads]
      .sort((left, right) => Number(right.updatedAtUnixSeconds || 0) - Number(left.updatedAtUnixSeconds || 0))
      .map((thread) => renderThreadHTML(thread, true))
      .join('');
  }
  const groups = new Map();
  visibleThreads.forEach((thread) => {
    const projectPath = String(thread.workspacePath).trim();
    if (!groups.has(projectPath)) groups.set(projectPath, { path: projectPath, name: thread.workspace, threads: [] });
    groups.get(projectPath).threads.push(thread);
  });
  return [...groups.values()].map(({ path: projectPath, name: project, threads: projectThreads }, index) => {
    const isCollapsed = collapsedProjects.has(projectPath);
    const projectListID = `dashboard-project-${index}`;
    return `
    <section class="dashboard-project-group${isCollapsed ? ' is-collapsed' : ''}" aria-label="${escapeHTML(project)} project">
      <header class="dashboard-project-heading">
        <button type="button" class="dashboard-project-toggle" data-project-toggle="${escapeHTML(projectPath)}" aria-expanded="${String(!isCollapsed)}" aria-controls="${projectListID}">
          <span class="dashboard-project-title">
            <span class="dashboard-project-chevron">${iconSvg('chevron')}</span>
            <span class="dashboard-project-icon">${iconSvg('project')}</span>
            <span class="dashboard-project-name">${escapeHTML(project)}</span>
            ${projectThreads.some((thread) => thread.gitStatus === 'modified') ? `<span class="dashboard-git-changes" title="This Git project has uncommitted changes">${iconSvg('gitChanges')}<span>Uncommitted</span></span>` : ''}
          </span>
          <span class="dashboard-project-summary">
            ${projectThreads.some((thread) => thread.activity === 'running') ? '<span class="dashboard-running-spinner" role="status" aria-label="Thread running" title="Thread running"></span>' : ''}
            <span class="dashboard-project-count">${projectThreads.length} ${projectThreads.length === 1 ? 'thread' : 'threads'}</span>
          </span>
        </button>
      </header>
      <div class="dashboard-project-list" id="${projectListID}"${isCollapsed ? ' hidden' : ''}>${projectThreads.map((thread) => renderThreadHTML(thread)).join('')}</div>
    </section>`;
  }).join('');
}

function render() {
  updateNavigationStatus();
  const page = document.getElementById(elementIDs.page);
  if (!page) return;
  const runningThreads = threads.filter((thread) => thread.activity === 'running');
  const unread = threads.filter(isThreadUnread).length;
  const runningSummary = page.querySelector('[data-running-summary]');
  if (runningSummary) runningSummary.hidden = runningThreads.length === 0;
  const runningList = page.querySelector('[data-running-list]');
  if (runningList) runningList.innerHTML = runningThreads
    .map((thread) => renderThreadHTML(thread, true))
    .join('');
  page.querySelectorAll('[data-filter]').forEach((button) => {
    const isActive = button.dataset.filter === filterMode;
    button.classList.toggle('is-active', isActive);
    button.setAttribute('aria-pressed', String(isActive));
  });
  const filterCounts = {
    all: threads.length,
    unread,
    uncommitted: new Set(
      threads
        .filter((thread) => thread.gitStatus === 'modified')
        .map((thread) => String(thread.workspacePath).trim()),
    ).size,
  };
  page.querySelectorAll('[data-filter-count]').forEach((count) => {
    count.textContent = String(filterCounts[count.dataset.filterCount] ?? 0);
  });
  page.querySelectorAll('[data-grouping]').forEach((button) => {
    const isActive = button.dataset.grouping === groupingMode;
    button.classList.toggle('is-active', isActive);
    button.setAttribute('aria-pressed', String(isActive));
  });

  const visibleThreads = getVisibleThreads();
  page.querySelector('[data-visible-summary]').textContent = `${visibleThreads.length} ${visibleThreads.length === 1 ? 'thread' : 'threads'}`;
  const list = page.querySelector('[data-thread-list]');
  if (!visibleThreads.length) {
    const emptyMessage = filterMode === 'unread' && !searchTerm.trim()
      ? 'You’re all caught up'
      : 'No threads found';
    list.innerHTML = `<div class="dashboard-empty"><strong>${emptyMessage}</strong></div>`;
    return;
  }
  list.innerHTML = renderThreadListHTML(visibleThreads);
}

function syncContentInset() {
  const sidebar = host.sidebar();
  const width = sidebar ? Math.max(0, sidebar.getBoundingClientRect().right) : 0;
  document.documentElement.style.setProperty('--codex-dashboard-content-left', `${Math.round(width)}px`);
}

function observeSidebar() {
  const sidebar = host.sidebar();
  if (!resizeObserver || sidebar === observedSidebar) return;
  resizeObserver.disconnect();
  if (sidebar) resizeObserver.observe(sidebar);
  observedSidebar = sidebar;
}

function syncPageHost() {
  const page = document.getElementById(elementIDs.page);
  const pageHost = host.pageHost();
  if (page && pageHost && page.parentElement !== pageHost) pageHost.append(page);
}

function mutationTouchesSidebar(record) {
  if (record.target instanceof Element && record.target.closest('aside')) return true;
  return [...record.addedNodes, ...record.removedNodes].some((node) => (
    node instanceof Element && (node.matches('aside') || node.querySelector('aside'))
  ));
}

function scheduleMutationSync(records) {
  schedulePromptMenuSync();
  const sidebarMutation = records.some(mutationTouchesSidebar);
  const dashboardMissing = !document.getElementById(elementIDs.page)
    || !document.getElementById(elementIDs.navButton);
  if (!sidebarMutation && !dashboardMissing) return;
  if (sidebarMutation) pendingSidebarMutation = true;
  if (mutationFrame !== undefined) return;
  mutationFrame = requestAnimationFrame(() => {
    mutationFrame = undefined;
    const shouldSyncUnread = pendingSidebarMutation;
    pendingSidebarMutation = false;
    const restoredPage = !document.getElementById(elementIDs.page);
    if (restoredPage) createPage();
    if (!document.getElementById(elementIDs.navButton)) createNavigation();
    if (isOpen && restoredPage) openPage();
    syncPageHost();
    observeSidebar();
    if (shouldSyncUnread && syncUnreadFromSidebar()) render();
  });
}

function createNavigation() {
  const insertionPoint = host.navigationInsertionPoint();
  if (!insertionPoint?.element?.parentElement) return false;
  const button = document.createElement('button');
  button.id = elementIDs.navButton;
  button.type = 'button';
  button.className = insertionPoint.element.className;
  button.setAttribute('aria-label', 'Dashboard');
  button.innerHTML = `
    <div class="dashboard-nav-copy">
      <span class="dashboard-nav-icon">${iconSvg('threads')}</span>
      <span class="dashboard-nav-label">Dashboard</span>
    </div>
    <div class="dashboard-nav-status">
      <span class="dashboard-nav-spinner" data-navigation-running role="status" aria-label="Threads running" title="Threads running" hidden></span>
      <strong class="dashboard-nav-count" data-navigation-count aria-label="0 unread threads" hidden>0</strong>
    </div>`;
  if (insertionPoint.insertAfter) insertionPoint.element.after(button);
  else insertionPoint.element.parentElement.insertBefore(button, insertionPoint.element);
  updateNavigationStatus();
  return true;
}

function createPage() {
  const page = document.createElement('section');
  page.id = elementIDs.page;
  page.setAttribute('aria-label', 'Codex thread dashboard');
  page.innerHTML = `
    <div class="dashboard-shell">
      <header class="dashboard-header">
        <h1>Threads</h1>
      </header>
      <section class="dashboard-running" data-running-summary aria-label="Running threads" hidden>
        <div class="dashboard-running-heading">
          <span class="dashboard-running-spinner" role="status" aria-label="Running threads" title="Running threads"></span>
          <h2>Running</h2>
        </div>
        <div class="dashboard-running-list" data-running-list></div>
      </section>
      <div class="dashboard-section-header">
        <div class="dashboard-section-title">
          <p data-visible-summary>0 threads</p>
        </div>
        <div class="dashboard-toolbar">
          <div class="dashboard-filters" aria-label="Filter threads">
            <button type="button" data-filter="all" class="is-active">All <span class="dashboard-filter-count" data-filter-count="all">0</span></button>
            <button type="button" data-filter="unread">Unread <span class="dashboard-filter-count" data-filter-count="unread">0</span></button>
            <button type="button" data-filter="uncommitted">Uncommitted <span class="dashboard-filter-count" data-filter-count="uncommitted">0</span></button>
          </div>
          <div class="dashboard-view-options" aria-label="Group threads">
            <button type="button" data-grouping="projects" class="is-active" aria-pressed="true">Projects</button>
            <button type="button" data-grouping="updated" aria-pressed="false">Last updated</button>
          </div>
          <label class="dashboard-search" aria-label="Search loaded threads">${iconSvg('search')}<input type="search" placeholder="Search threads" data-dashboard-search /></label>
        </div>
      </div>
      <main class="dashboard-list" data-thread-list></main>
    </div>`;
  page.querySelectorAll('[data-filter]').forEach((button) => {
    button.addEventListener('click', () => {
      filterMode = button.dataset.filter;
      render();
    });
  });
  page.querySelectorAll('[data-grouping]').forEach((button) => {
    button.addEventListener('click', () => {
      groupingMode = button.dataset.grouping;
      render();
    });
  });
  page.querySelector('[data-dashboard-search]').addEventListener('input', (event) => {
    searchTerm = event.target.value;
    render();
  });
  page.querySelector('[data-thread-list]').addEventListener('click', (event) => {
    const projectToggle = event.target.closest('[data-project-toggle]');
    if (projectToggle) {
      const projectPath = projectToggle.dataset.projectToggle;
      if (collapsedProjects.has(projectPath)) collapsedProjects.delete(projectPath);
      else collapsedProjects.add(projectPath);
      render();
      return;
    }
    openThreadFromEvent(event);
  });
  page.querySelector('[data-running-list]').addEventListener('click', openThreadFromEvent);
  host.pageHost().append(page);
}

function openThreadFromEvent(event) {
  const eventTarget = event.target instanceof Element ? event.target : null;
  const button = eventTarget?.closest('[data-open-thread]');
  if (!button) return;
  const thread = threads.find((item) => item.id === button.dataset.openThread);
  if (thread) openThread(thread);
}

function openPage() {
  const page = document.getElementById(elementIDs.page);
  if (!page) return;
  isOpen = true;
  page.classList.add('is-open');
  document.documentElement.classList.add('codex-dashboard-open');
  document.getElementById(elementIDs.navButton)?.setAttribute('aria-current', 'page');
  render();
}

function closePage() {
  isOpen = false;
  document.getElementById(elementIDs.page)?.classList.remove('is-open');
  document.documentElement.classList.remove('codex-dashboard-open');
  document.getElementById(elementIDs.navButton)?.removeAttribute('aria-current');
}

function updateNavigationStatus() {
  const unreadCount = threads.filter(isThreadUnread).length;
  const hasRunningThreads = threads.some((thread) => thread.activity === 'running');
  const count = document.querySelector('[data-navigation-count]');
  if (count) {
    count.textContent = String(unreadCount);
    count.hidden = unreadCount === 0;
    count.setAttribute(
      'aria-label',
      `${unreadCount} unread ${unreadCount === 1 ? 'thread' : 'threads'}`,
    );
  }
  const spinner = document.querySelector('[data-navigation-running]');
  if (spinner) spinner.hidden = !hasRunningThreads;
}

function update(nextSnapshot) {
  const nextThreads = Array.isArray(nextSnapshot?.threads) ? nextSnapshot.threads : [];
  threads = nextThreads;
  syncUnreadFromSidebar();
  render();
}

function ensureMounted() {
  if (!document.body) return false;
  if (!document.getElementById(elementIDs.style)) {
    const style = document.createElement('style');
    style.id = elementIDs.style;
    style.textContent = DASHBOARD_CSS;
    document.head.append(style);
  }
  const pageWasMissing = !document.getElementById(elementIDs.page);
  if (pageWasMissing) createPage();
  if (!document.getElementById(elementIDs.navButton)) createNavigation();
  syncPageHost();
  syncContentInset();
  syncPromptMenuItem();
  if (isOpen && pageWasMissing) openPage();

  if (!mutationObserver) {
    mutationObserver = new MutationObserver(scheduleMutationSync);
    mutationObserver.observe(document.body, { childList: true, subtree: true });
  }
  if (!resizeObserver && typeof ResizeObserver !== 'undefined') {
    resizeObserver = new ResizeObserver(syncContentInset);
    observeSidebar();
  }
  document.addEventListener('pointerdown', handlePromptInteraction, true);
  document.addEventListener('mousedown', handlePromptInteraction, true);
  document.addEventListener('click', handlePromptInteraction, true);
  document.addEventListener('keydown', handlePromptInteraction, true);
  document.addEventListener('submit', handlePromptInteraction, true);
  document.addEventListener('pointerdown', handleHostNavigation, true);
  document.addEventListener('mousedown', handleHostNavigation, true);
  document.addEventListener('click', handleHostNavigation, true);
  return Boolean(
    document.getElementById(elementIDs.style)
      && document.getElementById(elementIDs.page)
      && document.getElementById(elementIDs.navButton)
  );
}

function destroy() {
  isOpen = false;
  mutationObserver?.disconnect();
  resizeObserver?.disconnect();
  if (mutationFrame !== undefined) cancelAnimationFrame(mutationFrame);
  mutationObserver = undefined;
  resizeObserver = undefined;
  mutationFrame = undefined;
  pendingSidebarMutation = false;
  promptMenuSyncQueued = false;
  observedSidebar = undefined;
  document.removeEventListener('pointerdown', handlePromptInteraction, true);
  document.removeEventListener('mousedown', handlePromptInteraction, true);
  document.removeEventListener('click', handlePromptInteraction, true);
  document.removeEventListener('keydown', handlePromptInteraction, true);
  document.removeEventListener('submit', handlePromptInteraction, true);
  document.removeEventListener('pointerdown', handleHostNavigation, true);
  document.removeEventListener('mousedown', handleHostNavigation, true);
  document.removeEventListener('click', handleHostNavigation, true);
  document.documentElement.classList.remove('codex-dashboard-open');
  document.documentElement.style.removeProperty('--codex-dashboard-content-left');
  document.querySelectorAll('[data-codex-prompt-menu-item]').forEach((item) => item.remove());
  Object.values(elementIDs).forEach((id) => document.getElementById(id)?.remove());
  delete window.__codexDashboard;
}

window.__codexDashboard = { version: DASHBOARD_VERSION, ensureMounted, destroy, open: openPage, update };
return ensureMounted();
