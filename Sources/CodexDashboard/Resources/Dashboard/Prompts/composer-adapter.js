const composerAdapter = (() => {
  const modelLabels = {
    'gpt-5.6-sol': '5.6 Sol',
    'gpt-5.6-terra': '5.6 Terra',
    'gpt-5.6-luna': '5.6 Luna',
    'gpt-5.5': '5.5',
    'gpt-5.4': '5.4',
    'gpt-5.4-mini': '5.4 Mini',
  };
  const reasoningEffortLabels = {
    low: 'Low',
    medium: 'Medium',
    high: 'High',
    xhigh: 'Extra High',
  };
  const speedLabels = { standard: 'Standard', fast: 'Fast' };

  function isVisible(element) {
    return Boolean(element?.getClientRects().length)
      && getComputedStyle(element).visibility !== 'hidden';
  }

  async function waitFor(value, timeout = 1200) {
    const deadline = performance.now() + timeout;
    while (performance.now() < deadline) {
      const result = value();
      if (result) return result;
      await new Promise((resolve) => setTimeout(resolve, 25));
    }
    return null;
  }

  function intelligenceTrigger() {
    const composer = codexUIContracts.composer(dashboardElements.elementIDs.promptDialog);
    let container = composer?.parentElement;
    while (container && container !== document.body) {
      const trigger = [...container.querySelectorAll('[data-codex-intelligence-trigger]')]
        .find(isVisible);
      if (trigger) return trigger;
      container = container.parentElement;
    }
    return [...document.querySelectorAll('[data-codex-intelligence-trigger]')].find(isVisible) || null;
  }

  async function openIntelligenceMenu() {
    const isIntelligenceMenu = (menu) => {
      if (menu.querySelector('[data-model-picker-view-toggle]')) return true;
      const labels = [...menu.querySelectorAll('[role="menuitem"]')]
        .map((item) => item.getAttribute('aria-label') || '');
      return ['Model', 'Effort', 'Speed']
        .every((prefix) => labels.some((label) => label.startsWith(`${prefix} `)));
    };
    const visibleMenu = () => [...document.querySelectorAll('[role="menu"]')]
      .find((menu) => isVisible(menu) && isIntelligenceMenu(menu));
    let openMenu = visibleMenu();
    if (openMenu) return openMenu;
    let trigger = intelligenceTrigger();
    if (!trigger) return null;
    if (trigger.getAttribute('aria-expanded') === 'true') {
      openMenu = await waitFor(visibleMenu, 400);
      if (openMenu) return openMenu;
      document.body.click();
      await waitFor(() => intelligenceTrigger()?.getAttribute('aria-expanded') !== 'true', 300);
      trigger = intelligenceTrigger();
      if (!trigger) return null;
    }
    trigger.dispatchEvent(new PointerEvent('pointerdown', {
      bubbles: true, button: 0, pointerType: 'mouse',
    }));
    trigger.click();
    return waitFor(visibleMenu);
  }

  async function advancedMenuItem(prefix) {
    const menu = await openIntelligenceMenu();
    if (!menu) return null;
    let item = [...menu.querySelectorAll('[role="menuitem"]')].find((candidate) => (
      candidate.getAttribute('aria-label')?.startsWith(`${prefix} `)
    ));
    if (item) return item;
    menu.querySelector('[data-model-picker-view-toggle]')?.click();
    item = await waitFor(() => [...menu.querySelectorAll('[role="menuitem"]')].find((candidate) => (
      candidate.getAttribute('aria-label')?.startsWith(`${prefix} `)
    )));
    return item;
  }

  async function selectPresetValue(prefix, label) {
    const item = await advancedMenuItem(prefix);
    if (!item) return false;
    item.dispatchEvent(new PointerEvent('pointermove', { bubbles: true, pointerType: 'mouse' }));
    const submenu = await waitFor(() => {
      const menus = [...document.querySelectorAll('[role="menu"]')].filter(isVisible);
      return item.getAttribute('aria-expanded') === 'true' ? menus.at(-1) : null;
    });
    if (!submenu) return false;
    const options = [...submenu.querySelectorAll('[role^="menuitem"]')].filter(isVisible);
    const option = options.find((candidate) => {
      const text = candidate.textContent.trim().replace(/\s+/g, ' ');
      return text === label || candidate.getAttribute('aria-label') === label;
    }) || options.find((candidate) => (
      candidate.textContent.trim().replace(/\s+/g, ' ').startsWith(label)
    ));
    if (!option) return false;
    option.click();
    await new Promise((resolve) => setTimeout(resolve, 25));
    return true;
  }

  async function applyPreset(preset) {
    if (!preset) return true;
    const selections = [
      ['Model', modelLabels[preset.model]],
      ['Effort', reasoningEffortLabels[preset.reasoningEffort]],
      ['Speed', speedLabels[preset.speed]],
    ].filter(([, label]) => label);
    for (const [prefix, label] of selections) {
      if (!await selectPresetValue(prefix, label)) {
        document.body.click();
        return false;
      }
    }
    document.body.click();
    return true;
  }

  function insertIntoEditor(view, content, separateFromExistingContent) {
    const schema = view.state.schema;
    const lines = `${separateFromExistingContent ? '\n' : ''}${content}`.split('\n');
    const paragraphs = lines.map((line) => schema.nodes.paragraph.create(
      null,
      line ? schema.text(line) : null,
    ));
    const fragment = schema.nodes.doc.create(null, paragraphs).content;
    const Slice = view.state.doc.slice(0, 0).constructor;
    const transaction = view.state.tr
      .replaceSelection(new Slice(fragment, 0, 0))
      .scrollIntoView();
    view.focus();
    view.dispatch(transaction);
    return true;
  }

  function insert(content) {
    const composer = codexUIContracts.composer(dashboardElements.elementIDs.promptDialog);
    if (!composer) return false;
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
      composer.dispatchEvent(new Event('input', { bubbles: true }));
      requestAnimationFrame(() => composer.focus());
      return true;
    }
    composer.focus();
    const selection = window.getSelection();
    const needsSeparator = Boolean(composer.textContent && !/\s$/.test(composer.textContent));
    const insertedContent = `${needsSeparator ? '\n\n' : ''}${content}`;
    const editorView = codexUIContracts.composerEditorView(composer);
    if (editorView) {
      return insertIntoEditor(editorView, content, needsSeparator);
    }
    if (!selection?.rangeCount || !composer.contains(selection.anchorNode)) {
      const range = document.createRange();
      range.selectNodeContents(composer);
      range.collapse(false);
      selection?.removeAllRanges();
      selection?.addRange(range);
    }
    const insertion = document.createTextNode(insertedContent);
    const range = selection?.getRangeAt(0);
    if (!range) return false;
    range.deleteContents();
    range.insertNode(insertion);
    range.setStartAfter(insertion);
    range.collapse(true);
    selection.removeAllRanges();
    selection.addRange(range);
    composer.dispatchEvent(new Event('input', { bubbles: true }));
    return true;
  }

  return { applyPreset, insert };
})();
