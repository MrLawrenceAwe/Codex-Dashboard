const composerAdapter = (() => {
  const { isVisible } = domUtils;
  const waitFor = (value, timeout = 1200) => domUtils.waitFor(
    value,
    { timeout, interval: 25 },
  );

  function isAvailable(element) {
    return isVisible(element)
      && !element.closest('[inert], [hidden], [aria-hidden="true"]')
      && !element.matches('[disabled], [data-disabled], [aria-disabled="true"]');
  }

  const picker = () => [...document.querySelectorAll('[data-model-picker-view]')]
    .find(isAvailable);

  function intelligenceTrigger() {
    return codexUIContracts.intelligenceTrigger(dashboardElements.elementIDs.promptDialog);
  }

  async function openIntelligenceMenu() {
    const visibleMenu = picker;
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

  function matchesLabel(element, label) {
    return element.getAttribute('aria-label') === label
      || [element, ...element.querySelectorAll('*')].some((node) => (
        node.textContent.trim().replace(/\s+/g, ' ') === label
      ));
  }

  async function openCompactMenu() {
    const menu = await openIntelligenceMenu();
    if (!menu || menu.dataset.modelPickerView === 'simple') return menu;
    const selected = [...menu.querySelectorAll('[role="menuitemradio"][aria-checked="true"]')]
      .find(isAvailable);
    if (!selected) return null;
    selected.click();
    return waitFor(() => picker()?.dataset.modelPickerView === 'simple' && picker());
  }

  async function selectModel(label) {
    let menu = await openIntelligenceMenu();
    if (!menu) return false;
    if (menu.dataset.modelPickerView !== 'advanced') {
      const toggle = menu.querySelector('[data-model-picker-view-toggle]');
      if (!isAvailable(toggle)) return false;
      toggle.click();
      menu = await waitFor(() => picker()?.dataset.modelPickerView === 'advanced' && picker());
    }
    if (!menu) return false;
    const option = [...menu.querySelectorAll('[role="menuitemradio"]')]
      .find((candidate) => isAvailable(candidate) && matchesLabel(candidate, label));
    if (!option) return false;
    // Locked rows open purchase/access dialogs rather than selecting a model.
    const description = option.getAttribute('aria-describedby')?.split(/\s+/)
      .map((id) => document.getElementById(id)?.textContent || '').join(' ');
    if (/locked/i.test(description || '')) return false;
    option.click();
    return Boolean(await waitFor(() => picker()?.dataset.modelPickerView === 'simple'));
  }

  async function selectEffort(effort) {
    // Persisted "light" is the picker's label for the underlying "low" effort.
    const target = effort === 'light' ? 'low' : effort;
    const order = ['low', 'medium', 'high', 'xhigh', 'max', 'ultra'];
    if (!order.includes(target)) return false;
    for (let step = 0; step < order.length; step += 1) {
      const current = intelligenceTrigger()?.dataset.selectedReasoningEffort;
      if (current === target) return true;
      if (!order.includes(current)) return false;
      const menu = await openCompactMenu();
      const slider = menu?.querySelector('[data-reasoning-slider]');
      if (!isAvailable(slider)) return false;
      const key = order.indexOf(current) < order.indexOf(target) ? 'ArrowRight' : 'ArrowLeft';
      slider.dispatchEvent(new KeyboardEvent('keydown', { key, bubbles: true }));
      if (!await waitFor(() => intelligenceTrigger()?.dataset.selectedReasoningEffort !== current)) {
        return false;
      }
    }
    return intelligenceTrigger()?.dataset.selectedReasoningEffort === target;
  }

  async function selectSpeed(speed) {
    const menu = await openCompactMenu();
    if (!menu) return false;
    const toggle = [...menu.querySelectorAll('[role="menuitemcheckbox"]')]
      .find((candidate) => isAvailable(candidate)
        && /^Enable (fast|standard) mode$/.test(candidate.getAttribute('aria-label') || ''));
    if (toggle) {
      const checked = speed === 'fast' ? 'true' : 'false';
      if (toggle.getAttribute('aria-checked') !== checked) toggle.click();
      return Boolean(await waitFor(() => toggle.isConnected && toggle.getAttribute('aria-checked') === checked));
    }
    // Accounts with more speed tiers expose a Speed flyout in the same compact view.
    const item = [...menu.querySelectorAll('[role="menuitem"]')]
      .find((candidate) => isAvailable(candidate)
        && candidate.getAttribute('aria-label')?.startsWith('Speed '));
    if (!item) return false;
    item.dispatchEvent(new PointerEvent('pointermove', { bubbles: true, pointerType: 'mouse' }));
    const submenu = await waitFor(() => {
      const controlled = document.getElementById(item.getAttribute('aria-controls'));
      return item.getAttribute('aria-expanded') === 'true' && isAvailable(controlled) ? controlled : null;
    });
    if (!submenu) return false;
    const label = presetOptions.label(presetOptions.speeds, speed);
    const option = [...submenu.querySelectorAll('[role^="menuitem"]')]
      .find((candidate) => isAvailable(candidate) && matchesLabel(candidate, label));
    if (!option) return false;
    option.click();
    await new Promise((resolve) => setTimeout(resolve, 25));
    return true;
  }

  async function applyPreset(preset) {
    if (!preset) return true;
    const modelLabel = presetOptions.label(presetOptions.models, preset.model);
    if (preset.model && !modelLabel) return false;
    const selections = [
      [selectModel, modelLabel],
      [selectEffort, preset.reasoningEffort],
      [selectSpeed, preset.speed],
    ].filter(([, value]) => value);
    for (const [select, value] of selections) {
      if (!await select(value)) {
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

  async function attachImage(image) {
    if (!image?.dataURL) return false;
    const composer = codexUIContracts.composer(dashboardElements.elementIDs.promptDialog);
    if (!composer) return false;
    try {
      const response = await fetch(image.dataURL);
      if (!response.ok) return false;
      const blob = await response.blob();
      const file = new File([blob], image.name || 'Attached image', {
        type: image.type || blob.type,
      });
      const clipboard = new DataTransfer();
      clipboard.items.add(file);
      const paste = new Event('paste', { bubbles: true, cancelable: true });
      Object.defineProperty(paste, 'clipboardData', { value: clipboard });
      composer.dispatchEvent(paste);
      return true;
    } catch (_) {
      return false;
    }
  }

  return { applyPreset, attachImage, insert };
})();
