const existing = window.__codexDashboard;
if (existing?.version === DASHBOARD_VERSION) {
  return existing.ensureMounted();
}
existing?.destroy?.();

const dashboardElements = {
  elementIDs: {
    style: 'codex-dashboard-style',
    navButton: 'codex-dashboard-navigation',
    page: 'codex-dashboard-page',
    promptDialog: 'codex-dashboard-prompt-library-dialog',
  },

  escapeHTML(value) {
    return String(value ?? '').replace(/[&<>'"]/g, (character) => ({
      '&': '&amp;', '<': '&lt;', '>': '&gt;', "'": '&#39;', '"': '&quot;',
    })[character]);
  },
};
