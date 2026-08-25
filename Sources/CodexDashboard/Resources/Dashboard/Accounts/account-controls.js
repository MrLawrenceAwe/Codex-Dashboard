const accountControls = (() => {
  let savedAccounts = [];
  let activeAccountID = null;
  let statusMessage = null;
  let pendingAction = null;

  function render() {
    const select = document.querySelector('[data-account-select]');
    if (!select) return;
    const hasSavedActiveAccount = savedAccounts.some((account) => account.id === activeAccountID);
    const currentAccountOption = hasSavedActiveAccount
      ? ''
      : '<option value="" selected>Current account</option>';
    const options = savedAccounts.map((account) => `
      <option value="${dashboardElements.escapeHTML(account.id)}"${account.id === activeAccountID ? ' selected' : ''}>
        ${dashboardElements.escapeHTML(account.name)}
      </option>`).join('');
    select.innerHTML = currentAccountOption + options;

    const notice = document.querySelector('[data-account-notice]');
    if (!notice) return;
    notice.textContent = statusMessage || '';
    notice.hidden = !statusMessage;
  }

  function queue(action) {
    pendingAction = action;
    statusMessage = action.type === 'switch'
      ? 'Switching accounts…'
      : (action.type === 'add' ? 'Preparing account sign-in…' : 'Saving account…');
    render();
  }

  function consume() {
    if (!pendingAction) return null;
    const action = pendingAction;
    pendingAction = null;
    return JSON.stringify(action);
  }

  function applySnapshot(snapshot) {
    savedAccounts = snapshot.accounts;
    activeAccountID = snapshot.activeAccountID;
    statusMessage = snapshot.accountStatusMessage;
    render();
  }

  return { applySnapshot, consume, queue, render };
})();
