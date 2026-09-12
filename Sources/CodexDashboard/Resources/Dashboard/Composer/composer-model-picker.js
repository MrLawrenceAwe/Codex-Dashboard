const composerModelPicker = (() => {
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

  return { applyPreset };
})();
