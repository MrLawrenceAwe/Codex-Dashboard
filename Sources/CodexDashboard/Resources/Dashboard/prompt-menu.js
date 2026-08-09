const promptMenu = (() => {
  const activationEventTypes = ['pointerdown', 'mousedown', 'click', 'keydown'];
  let syncQueued = false;
  let onActivate;

  function findAnchor() {
    const interactiveLabel = [...document.querySelectorAll('button, [role="menuitem"]')]
      .find((element) => dashboardDOM.textIs(element, 'Record a skill'));
    const exactLabels = [...document.querySelectorAll('span, div')]
      .filter((element) => dashboardDOM.textIs(element, 'Record a skill'));
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
    if (!menu || menu.closest(`#${dashboardDOM.elementIDs.promptDialog}`)) return null;
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

  function setHighlighted(item, highlighted) {
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

  function removeHostActions(root) {
    [root, ...root.querySelectorAll('*')].forEach((element) => {
      [...element.attributes].forEach((attribute) => {
        if (attribute.name === 'id' || attribute.name.startsWith('data-app-action')) {
          element.removeAttribute(attribute.name);
        }
      });
    });
  }

  function createItem(anchor) {
    const item = anchor.cloneNode(true);
    removeHostActions(item);
    item.dataset.codexPromptMenuItem = '';
    item.setAttribute('aria-label', 'Prompts');
    item.setAttribute('role', anchor.getAttribute('role') || 'menuitem');
    item.setAttribute('tabindex', '0');
    item.classList.remove('bg-token-list-hover-background', 'opacity-100');
    item.addEventListener('pointerenter', () => setHighlighted(item, true));
    item.addEventListener('pointerleave', () => setHighlighted(item, false));
    item.addEventListener('focus', () => setHighlighted(item, true));
    item.addEventListener('blur', () => setHighlighted(item, false));
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

  function synchronize() {
    syncQueued = false;
    if (document.querySelector('[data-codex-prompt-menu-item]')) return;
    const anchor = findAnchor();
    if (anchor) createItem(anchor);
  }

  function scheduleSync() {
    if (syncQueued) return;
    syncQueued = true;
    queueMicrotask(synchronize);
  }

  function handleActivation(event) {
    const target = event.target instanceof Element ? event.target : null;
    const menuItem = target?.closest('[data-codex-prompt-menu-item]');
    const activatesItem = event.type !== 'keydown' || ['Enter', ' '].includes(event.key);
    if (!menuItem || !activatesItem) return;
    event.preventDefault();
    event.stopImmediatePropagation();
    onActivate?.();
  }

  function mount(activation) {
    onActivate = activation;
    synchronize();
    activationEventTypes.forEach((type) => {
      document.addEventListener(type, handleActivation, true);
    });
  }

  function unmount() {
    activationEventTypes.forEach((type) => {
      document.removeEventListener(type, handleActivation, true);
    });
    syncQueued = false;
    onActivate = undefined;
    document.querySelectorAll('[data-codex-prompt-menu-item]').forEach((item) => item.remove());
  }

  return { mount, scheduleSync, unmount };
})();
