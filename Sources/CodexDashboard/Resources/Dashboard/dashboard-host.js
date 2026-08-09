window.__codexDashboard = {
  version: DASHBOARD_VERSION,
  ensureMounted: threadDashboard.ensureMounted,
  destroy: threadDashboard.destroy,
  open: threadDashboard.open,
  applySnapshot: threadDashboard.applySnapshot,
};
return threadDashboard.ensureMounted();
