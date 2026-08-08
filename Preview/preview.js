Promise.all([
  fetch('../Resources/Adapter/canvas.js').then((response) => response.text()),
  fetch('../Resources/Adapter/canvas.css').then((response) => response.text()),
]).then(([script, stylesheet]) => {
  new Function('CANVAS_VERSION', 'CANVAS_CSS', script)('preview-v1', stylesheet);
  window.__codexDashboard.update([
    {
      id: 'thread-dashboard',
      title: 'Build tasks dashboard',
      preview: 'Create an active-task dashboard embedded directly inside Codex.',
      workspace: 'Codex Dashboard',
      cwd: '/Users/lawrenceawe/Codex Dashboard',
      updatedAt: Math.round(Date.now() / 1000) - 3,
      createdAt: Math.round(Date.now() / 1000) - 1200,
      isPinned: true,
      model: 'gpt-5.6-sol',
      status: 'running',
    },
    {
      id: 'thread-review',
      title: 'Review project for bugs',
      preview: 'Inspect the project for correctness problems and produce actionable findings.',
      workspace: 'voice-tiktok-scroller',
      cwd: '/Users/lawrenceawe/voice-tiktok-scroller',
      updatedAt: Math.round(Date.now() / 1000) - 780,
      createdAt: Math.round(Date.now() / 1000) - 3600,
      isPinned: false,
      model: 'gpt-5.6-terra',
      status: 'recent',
    },
    {
      id: 'thread-idle',
      title: 'Fix back command detection',
      preview: 'Improve recognition of the spoken back command.',
      workspace: 'voice-tiktok-scroller',
      cwd: '/Users/lawrenceawe/voice-tiktok-scroller',
      updatedAt: Math.round(Date.now() / 1000) - 86400,
      createdAt: Math.round(Date.now() / 1000) - 90000,
      isPinned: false,
      model: 'gpt-5.6-terra',
      status: 'idle',
    },
  ]);
  window.__codexDashboard.open();
});
