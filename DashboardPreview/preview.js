Promise.all([
  fetch('../Sources/CodexDashboard/Resources/Dashboard/dashboard.js').then((response) => response.text()),
  fetch('../Sources/CodexDashboard/Resources/Dashboard/dashboard.css').then((response) => response.text()),
]).then(([script, stylesheet]) => {
  const threads = [
    {
      id: 'thread-dashboard',
      title: 'Build threads dashboard',
      preview: 'Create an active-thread dashboard embedded directly inside Codex.',
      workspace: 'Codex Dashboard',
      workspacePath: '/Users/lawrenceawe/Codex Dashboard',
      updatedAtUnixSeconds: Math.round(Date.now() / 1000) - 3,
      isPinned: true,
      model: 'gpt-5.6-sol',
      activity: 'running',
      gitStatus: 'modified',
    },
    {
      id: 'thread-review',
      title: 'Review project for bugs',
      preview: 'Inspect the project for correctness problems and produce actionable findings.',
      workspace: 'voice-tiktok-scroller',
      workspacePath: '/Users/lawrenceawe/voice-tiktok-scroller',
      updatedAtUnixSeconds: Math.round(Date.now() / 1000) - 780,
      isPinned: false,
      model: 'gpt-5.6-terra',
      activity: 'idle',
      gitStatus: 'clean',
    },
    {
      id: 'thread-idle',
      title: 'Fix back command detection',
      preview: 'Improve recognition of the spoken back command.',
      workspace: 'voice-tiktok-scroller',
      workspacePath: '/Users/lawrenceawe/voice-tiktok-scroller',
      updatedAtUnixSeconds: Math.round(Date.now() / 1000) - 86400,
      isPinned: false,
      model: 'gpt-5.6-terra',
      activity: 'idle',
      gitStatus: 'clean',
    },
  ];
  new Function('DASHBOARD_VERSION', 'DASHBOARD_CSS', script)('preview-v1', stylesheet);
  window.__codexDashboard.update({ threads });
  window.__codexDashboard.open();
});
