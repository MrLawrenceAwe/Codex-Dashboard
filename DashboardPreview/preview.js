const resourceRoot = '../Sources/CodexDashboard/Resources/Dashboard';
const scriptNames = ['bootstrap', 'codex-ui', 'prompt-library', 'thread-dashboard'];
const stylesheetNames = ['dashboard', 'prompts'];

Promise.all([
  Promise.all(scriptNames.map((name) => fetch(`${resourceRoot}/${name}.js`).then((response) => response.text()))),
  Promise.all(stylesheetNames.map((name) => fetch(`${resourceRoot}/${name}.css`).then((response) => response.text()))),
]).then(([scripts, stylesheets]) => {
  const script = scripts.join('\n');
  const stylesheet = stylesheets.join('\n');
  const threads = [
    {
      id: 'thread-dashboard',
      title: 'Build threads dashboard',
      preview: 'Create an active-thread dashboard embedded directly inside Codex.',
      workspaceName: 'Codex Dashboard',
      workspacePath: '/Users/lawrenceawe/Codex Dashboard',
      recencyTimestamp: Math.round(Date.now() / 1000) - 3,
      isPinned: true,
      model: 'gpt-5.6-sol',
      activity: 'running',
      gitWorkingTreeStatus: 'hasChanges',
    },
    {
      id: 'thread-review',
      title: 'Review project for bugs',
      preview: 'Inspect the project for correctness problems and produce actionable findings.',
      workspaceName: 'voice-tiktok-scroller',
      workspacePath: '/Users/lawrenceawe/voice-tiktok-scroller',
      recencyTimestamp: Math.round(Date.now() / 1000) - 780,
      isPinned: false,
      model: 'gpt-5.6-terra',
      activity: 'idle',
      gitWorkingTreeStatus: 'clean',
    },
    {
      id: 'thread-idle',
      title: 'Fix back command detection',
      preview: 'Improve recognition of the spoken back command.',
      workspaceName: 'voice-tiktok-scroller',
      workspacePath: '/Users/lawrenceawe/voice-tiktok-scroller',
      recencyTimestamp: Math.round(Date.now() / 1000) - 86400,
      isPinned: false,
      model: 'gpt-5.6-terra',
      activity: 'idle',
      gitWorkingTreeStatus: 'clean',
    },
  ];
  new Function('DASHBOARD_VERSION', 'DASHBOARD_CSS', script)('preview-v1', stylesheet);
  window.__codexDashboard.applySnapshot({ threads });
  window.__codexDashboard.open();
});
