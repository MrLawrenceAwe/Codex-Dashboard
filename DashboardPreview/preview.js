Promise.all([
  fetch('../Sources/CodexDashboard/Resources/Dashboard/dashboard.js').then((response) => response.text()),
  fetch('../Sources/CodexDashboard/Resources/Dashboard/dashboard.css').then((response) => response.text()),
]).then(([script, stylesheet]) => {
  new Function('DASHBOARD_VERSION', 'DASHBOARD_CSS', script)('preview-v1', stylesheet);
  const tasks = [
    {
      id: 'thread-dashboard',
      title: 'Build tasks dashboard',
      preview: 'Create an active-task dashboard embedded directly inside Codex.',
      workspace: 'Codex Dashboard',
      updatedAt: Math.round(Date.now() / 1000) - 3,
      isPinned: true,
      model: 'gpt-5.6-sol',
      status: 'running',
    },
    {
      id: 'thread-review',
      title: 'Review project for bugs',
      preview: 'Inspect the project for correctness problems and produce actionable findings.',
      workspace: 'voice-tiktok-scroller',
      updatedAt: Math.round(Date.now() / 1000) - 780,
      isPinned: false,
      model: 'gpt-5.6-terra',
      status: 'recent',
    },
    {
      id: 'thread-idle',
      title: 'Fix back command detection',
      preview: 'Improve recognition of the spoken back command.',
      workspace: 'voice-tiktok-scroller',
      updatedAt: Math.round(Date.now() / 1000) - 86400,
      isPinned: false,
      model: 'gpt-5.6-terra',
      status: 'idle',
    },
  ];
  window.__codexDashboard.update({ tasks, totalTaskCount: tasks.length });
  window.__codexDashboard.open();
});
