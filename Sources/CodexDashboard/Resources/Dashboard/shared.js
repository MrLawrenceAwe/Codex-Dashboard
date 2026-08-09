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

function escapeHTML(value) {
  return String(value ?? '').replace(/[&<>'"]/g, (character) => ({
    '&': '&amp;', '<': '&lt;', '>': '&gt;', "'": '&#39;', '"': '&quot;',
  })[character]);
}

function textIs(element, value) {
  return element?.textContent?.trim() === value;
}
