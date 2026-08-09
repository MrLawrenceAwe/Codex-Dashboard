const promptLauncher = (() => {
  let syncQueued = false;
  let syncFrame;
  let onActivate;

  const launcherMutationSelector = [
    'textarea',
    '[contenteditable="true"]',
    'button[aria-label="Add"]',
    'button[aria-label^="Add "]',
    'button[aria-label*="attachment" i]',
    'button[data-testid="composer-plus-btn"]',
    'button[data-testid="composer-attachment-button"]',
    '[data-codex-prompt-launcher]',
  ].join(',');

  function createButton(addButton) {
    const button = document.createElement('button');
    button.type = 'button';
    button.dataset.codexPromptLauncher = '';
    button.className = 'dashboard-prompt-launcher';
    button.setAttribute('aria-label', 'Prompts');
    button.title = 'Saved prompts';
    button.innerHTML = `
      <svg aria-hidden="true" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8">
        <path d="M5 5.5A2.5 2.5 0 0 1 7.5 3h9A2.5 2.5 0 0 1 19 5.5v7a2.5 2.5 0 0 1-2.5 2.5H11l-4.5 4v-4A2.5 2.5 0 0 1 5 12.5z"/>
        <path d="M8.5 7.5h7M8.5 10.5h4.5"/>
      </svg>
      <span>Prompts</span>`;
    button.addEventListener('click', (event) => {
      event.preventDefault();
      event.stopPropagation();
      onActivate?.();
    });
    addButton.after(button);
  }

  function synchronize() {
    syncQueued = false;
    const addButton = codexContracts.composerAddButton(dashboardDOM.elementIDs.promptDialog);
    const currentButton = document.querySelector('[data-codex-prompt-launcher]');
    if (!addButton) {
      currentButton?.remove();
      return;
    }
    if (currentButton?.previousElementSibling === addButton) return;
    currentButton?.remove();
    createButton(addButton);
  }

  function scheduleSync() {
    if (syncQueued) return;
    syncQueued = true;
    syncFrame = requestAnimationFrame(() => {
      syncFrame = undefined;
      synchronize();
    });
  }

  function mutationsCouldAffectLauncher(records) {
    const currentButton = document.querySelector('[data-codex-prompt-launcher]');
    if (currentButton && !currentButton.isConnected) return true;
    return records.some((record) => [...record.addedNodes, ...record.removedNodes].some((node) => (
      node instanceof Element
        && (node.matches(launcherMutationSelector) || node.querySelector(launcherMutationSelector))
    )));
  }

  function mount(activation) {
    onActivate = activation;
    synchronize();
  }

  function unmount() {
    if (syncFrame !== undefined) cancelAnimationFrame(syncFrame);
    syncQueued = false;
    syncFrame = undefined;
    onActivate = undefined;
    document.querySelectorAll('[data-codex-prompt-launcher]').forEach((button) => button.remove());
  }

  return { mount, mutationsCouldAffectLauncher, scheduleSync, unmount };
})();
