const sidebarProjectHighlights = (() => {
  const key = 'codex-dashboard.sidebar-project-highlights';
  const selector = 'aside [data-app-action-sidebar-project-row][data-app-action-sidebar-project-id]';
  const palette = { Yellow: '#d6b64c', Green: '#69b883', Blue: '#719fe8', Purple: '#ae87d9', Pink: '#d781af', Red: '#dc6b6b', Orange: '#d89459' };
  let colours = new Map();
  let observer;
  let frame;
  let dialog;
  let activeID;
  let opener;

  function load() {
    try {
      colours = new Map(Object.entries(JSON.parse(localStorage.getItem(key) || '{}'))
        .filter(([, colour]) => Object.hasOwn(palette, colour)));
    } catch (_) { colours = new Map(); }
  }

  function sync() {
    document.querySelectorAll(selector).forEach((row) => {
      const id = row.getAttribute('data-app-action-sidebar-project-id');
      const colour = palette[colours.get(id)];
      const label = row.querySelector('[data-marquee-text]');
      row.querySelectorAll('[data-codex-project-highlight-name]').forEach((old) => {
        if (old !== label || !colour) {
          old.removeAttribute('data-codex-project-highlight-name');
          old.style.removeProperty('--codex-project-highlight');
        }
      });
      if (label && colour) {
        label.setAttribute('data-codex-project-highlight-name', '');
        label.style.setProperty('--codex-project-highlight', colour);
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
      button.setAttribute('aria-label', `Highlight colour for ${name}`);
      button.title = `Highlight colour for ${name}`;
      button.setAttribute('aria-haspopup', 'dialog');
      button.setAttribute('aria-expanded', String(Boolean(dialog && activeID === id)));
      button.style.color = colour || '';
    });
  }

  function scheduleSync() {
    if (frame !== undefined) return;
    frame = window.setTimeout(() => { frame = undefined; sync(); }, 0);
  }

  function close(restoreFocus = false) {
    dialog?.remove();
    dialog = undefined;
    activeID = undefined;
    if (restoreFocus && opener?.isConnected) opener.focus();
    opener = undefined;
    sync();
  }

  function open(button) {
    close();
    opener = button;
    const row = button.closest(selector);
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
    sync();
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
    close(true);
  }

  const events = ['pointerdown', 'mousedown', 'click', 'keydown'];
  function mount() {
    if (observer) return;
    load();
    sync();
    observer = new MutationObserver((records) => {
      if (records.some((record) => {
        const target = record.target instanceof Element ? record.target : record.target.parentElement;
        return target?.closest(selector) || [...record.addedNodes, ...record.removedNodes].some((node) =>
          node instanceof Element && (node.matches(selector) || node.querySelector(selector)));
      })) scheduleSync();
    });
    observer.observe(document.body, { childList: true, subtree: true, attributes: true,
      attributeFilter: ['data-app-action-sidebar-project-id', 'data-app-action-sidebar-project-label'] });
    events.forEach((type) => document.addEventListener(type, handle, true));
  }

  function destroy() {
    observer?.disconnect(); observer = undefined;
    if (frame !== undefined) clearTimeout(frame);
    frame = undefined;
    dialog?.remove(); dialog = undefined; activeID = undefined; opener = undefined;
    events.forEach((type) => document.removeEventListener(type, handle, true));
    document.querySelectorAll('[data-codex-project-colour]').forEach((button) => button.remove());
    document.querySelectorAll('[data-codex-project-highlight-name]').forEach((label) => {
      label.removeAttribute('data-codex-project-highlight-name');
      label.style.removeProperty('--codex-project-highlight');
    });
  }
  return { mount, destroy };
})();
