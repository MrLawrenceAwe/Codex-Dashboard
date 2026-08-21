const promptLibraryDialog = (() => {
  function create(owner) {
    const dialog = document.createElement('div');
    dialog[owner] = true;
    dialog.id = dashboardElements.elementIDs.promptDialog;
    dialog.innerHTML = `
      <div class="dashboard-prompt-backdrop" data-prompt-close></div>
      <section class="dashboard-prompt-panel" role="dialog" aria-modal="true" aria-labelledby="dashboard-prompt-title">
        <header class="dashboard-prompt-header">
          <h2 id="dashboard-prompt-title">Prompts</h2>
          <button type="button" class="dashboard-prompt-icon-button" data-prompt-close aria-label="Close prompts">×</button>
        </header>
        <p class="dashboard-prompt-storage-error" data-prompt-storage-error role="alert" hidden>Could not save this prompt change. Reloading Codex will restore the last successfully saved version.</p>
        <div data-prompt-content></div>
      </section>`;
    return dialog;
  }

  function handleKeyboard(event, dialog, close) {
    if (event.key === 'Escape') {
      event.preventDefault();
      event.stopImmediatePropagation();
      const actionsMenu = dialog.querySelector('[data-prompt-actions-menu]');
      if (actionsMenu && !actionsMenu.hidden) {
        actionsMenu.hidden = true;
        const actionsToggle = dialog.querySelector('[data-prompt-actions-toggle]');
        actionsToggle?.setAttribute('aria-expanded', 'false');
        actionsToggle?.focus();
        return;
      }
      close();
      return;
    }
    if (event.key !== 'Tab') return;
    const focusable = [...dialog.querySelectorAll('button, input, select, textarea, [tabindex]:not([tabindex="-1"])')]
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

  return { create, handleKeyboard };
})();
