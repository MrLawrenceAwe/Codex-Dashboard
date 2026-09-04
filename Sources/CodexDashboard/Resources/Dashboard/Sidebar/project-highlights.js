const sidebarProjectHighlights = (() => {
  const key = 'codex-dashboard.sidebar-project-highlights';
  const selector = '[data-app-action-sidebar-project-row][data-app-action-sidebar-project-id]';
  const palette = { Yellow: '#d6b64c', Green: '#69b883', Blue: '#719fe8', Purple: '#ae87d9', Pink: '#d781af', Red: '#dc6b6b', Orange: '#d89459' };
  let colours = new Map();
  let observer;
  let sidebar;
  let dialog;
  let activeID;
  let activeRow;
  let opener;
  let started = false;

  function load() {
    try {
      colours = new Map(Object.entries(JSON.parse(localStorage.getItem(key) || '{}'))
        .filter(([, colour]) => Object.hasOwn(palette, colour)));
    } catch (_) { colours = new Map(); }
  }

  function setAttribute(element, name, value) {
    if (element.getAttribute(name) !== value) element.setAttribute(name, value);
  }

  function updateRow(row) {
    if (!row?.isConnected) return;
    const id = row.getAttribute('data-app-action-sidebar-project-id');
    const colour = palette[colours.get(id)];
    const label = row.querySelector('[data-marquee-text]');
    const highlighted = label?.hasAttribute('data-codex-project-highlight-name');
    if (colour && label) {
      if (!highlighted) label.setAttribute('data-codex-project-highlight-name', '');
      if (label.style.getPropertyValue('--codex-project-highlight') !== colour) {
        label.style.setProperty('--codex-project-highlight', colour);
      }
    } else if (highlighted) {
      label.removeAttribute('data-codex-project-highlight-name');
      label.style.removeProperty('--codex-project-highlight');
    }

    let button = row.querySelector('[data-codex-project-colour]');
    if (!button) {
      button = document.createElement('button');
      button.type = 'button';
      button.setAttribute('data-codex-project-colour', '');
      button.textContent = '◉';
      row.append(button);
    }
    const name = row.getAttribute('data-app-action-sidebar-project-label') || 'project';
    setAttribute(button, 'aria-label', `Highlight colour for ${name}`);
    setAttribute(button, 'title', `Highlight colour for ${name}`);
    setAttribute(button, 'aria-haspopup', 'dialog');
    setAttribute(button, 'aria-expanded', String(Boolean(dialog && activeID === id)));
    if (button.style.color !== (colour || '')) button.style.color = colour || '';
  }

  function updateRows(root) {
    if (!root) return;
    if (root instanceof Element && root.matches(selector)) updateRow(root);
    root.querySelectorAll?.(selector).forEach(updateRow);
  }

  function close(restoreFocus = false) {
    const previousRow = activeRow;
    dialog?.remove();
    dialog = undefined;
    activeID = undefined;
    activeRow = undefined;
    if (restoreFocus && opener?.isConnected) opener.focus();
    opener = undefined;
    updateRow(previousRow);
  }

  function open(button) {
    close();
    const row = button.closest(selector);
    if (!row) return;
    opener = button;
    activeRow = row;
    activeID = row.getAttribute('data-app-action-sidebar-project-id');
    dialog = document.createElement('div');
    dialog.id = 'codex-sidebar-project-colours';
    dialog.setAttribute('role', 'dialog');
    dialog.setAttribute('aria-label', `Highlight ${row.getAttribute('data-app-action-sidebar-project-label') || 'project'}`);
    const title = document.createElement('strong');
    title.textContent = 'Project highlight';
    dialog.append(title);
    for (const [name, colour] of [['No highlight', null], ...Object.entries(palette)]) {
      const option = document.createElement('button');
      option.type = 'button';
      option.dataset.colour = colour ? name : '';
      option.textContent = name;
      option.setAttribute('aria-pressed', String((colours.get(activeID) || '') === option.dataset.colour));
      if (colour) option.style.setProperty('--swatch', colour);
      dialog.append(option);
    }
    document.body.append(dialog);
    const rect = button.getBoundingClientRect();
    dialog.style.left = `${Math.max(8, Math.min(rect.left, window.innerWidth - dialog.offsetWidth - 8))}px`;
    dialog.style.top = `${Math.max(8, Math.min(rect.bottom + 4, window.innerHeight - dialog.offsetHeight - 8))}px`;
    updateRow(row);
    dialog.querySelector('[aria-pressed="true"]').focus();
  }

  function handle(event) {
    const target = event.target instanceof Element ? event.target : null;
    const button = target?.closest('[data-codex-project-colour]');
    const inside = target?.closest('#codex-sidebar-project-colours');
    if (event.type === 'keydown') {
      if (dialog && event.key === 'Escape') {
        event.preventDefault(); event.stopImmediatePropagation(); close(true); return;
      }
      if (!button && !inside) return;
      event.stopImmediatePropagation();
      if (event.key === 'Enter' || event.key === ' ') {
        event.preventDefault(); target.click();
      }
      return;
    }
    if (!button && !inside) {
      if (event.type === 'pointerdown' && dialog) close();
      return;
    }
    event.stopImmediatePropagation();
    if (event.type !== 'click') return;
    event.preventDefault();
    if (button) { open(button); return; }
    const option = target.closest('[data-colour]');
    if (!option) return;
    if (option.dataset.colour) colours.set(activeID, option.dataset.colour);
    else colours.delete(activeID);
    try { localStorage.setItem(key, JSON.stringify(Object.fromEntries(colours))); } catch (_) {}
    updateRow(activeRow);
    close(true);
  }

  function handleMutations(records) {
    const rows = new Set();
    records.forEach((record) => {
      const target = record.target instanceof Element ? record.target : record.target.parentElement;
      const targetRow = target?.closest(selector);
      if (targetRow) rows.add(targetRow);
      [...record.addedNodes].forEach((node) => {
        if (node instanceof Element) updateRows(node);
      });
    });
    rows.forEach(updateRow);
    if (activeRow && !activeRow.isConnected) close();
  }

  function mount() {
    if (!observer) load();
    const nextSidebar = codexHost.sidebar();
    if (sidebar === nextSidebar) return;
    observer?.disconnect();
    sidebar = nextSidebar;
    observer = new MutationObserver(handleMutations);
    if (sidebar) {
      observer.observe(sidebar, { childList: true, subtree: true, attributes: true,
        attributeFilter: ['data-app-action-sidebar-project-id', 'data-app-action-sidebar-project-label'] });
      updateRows(sidebar);
    }
  }

  const events = ['pointerdown', 'mousedown', 'click', 'keydown'];
  function start() {
    mount();
    if (started) return;
    started = true;
    events.forEach((type) => document.addEventListener(type, handle, true));
  }

  function destroy() {
    observer?.disconnect(); observer = undefined; sidebar = undefined; started = false;
    dialog?.remove(); dialog = undefined; activeID = undefined; activeRow = undefined; opener = undefined;
    events.forEach((type) => document.removeEventListener(type, handle, true));
    document.querySelectorAll('[data-codex-project-colour]').forEach((button) => button.remove());
    document.querySelectorAll('[data-codex-project-highlight-name]').forEach((label) => {
      label.removeAttribute('data-codex-project-highlight-name');
      label.style.removeProperty('--codex-project-highlight');
    });
  }
  return { destroy, mount, start };
})();
