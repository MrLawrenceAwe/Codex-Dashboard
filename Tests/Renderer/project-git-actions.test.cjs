const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');
const vm = require('node:vm');

function fixture({ failPush = false, switchProject = false, diffResponses = [] } = {}) {
  const workerCalls = [];
  const rpcCalls = [];
  const listeners = new Set();
  const notifications = new Set();
  let current = true;
  let diffRequestCount = 0;
  const source = fs.readFileSync(path.join(__dirname,
    '../../Sources/CodexDashboard/Resources/Dashboard/Core/project-git-actions.js'), 'utf8');
  const createProjectGitActions = vm.runInNewContext(source + '\ncreateProjectGitActions', {
    crypto: { randomUUID: () => String(workerCalls.length) },
    setTimeout, clearTimeout, setInterval, clearInterval,
    domUtils: { delay: () => Promise.resolve() },
    window: {
      addEventListener(type, listener) { if (type === 'message') notifications.add(listener); },
      removeEventListener(type, listener) { if (type === 'message') notifications.delete(listener); },
      electronBridge: {
      subscribeToWorkerMessages(worker, listener) {
        listeners.add(listener);
        return () => listeners.delete(listener);
      },
      sendWorkerMessageFromView(worker, message) {
        if (message.type !== 'worker-request') return Promise.resolve();
        const { id, method, params } = message.request;
        workerCalls.push({ method, params });
        let value;
        switch (method) {
          case 'current-branch': value = { branch: 'main', isDetached: false }; break;
          case 'git-context': value = { remotes: [{ name: 'origin' }] }; break;
          case 'commit-message-diff':
            value = diffResponses[diffRequestCount++] ?? { type: 'success', unifiedDiff: '+Added a change' };
            break;
          case 'review-summary': value = { type: 'success', files: [{ path: 'app.js' }] }; break;
          case 'commit': value = { status: 'success', commitSha: 'abc' }; break;
          case 'upstream-branch': value = { branch: 'main', upstream: { branch: 'origin/main' } }; break;
          case 'push': value = failPush
            ? { status: 'error', execOutput: { output: 'Rejected by remote' } } : { status: 'success' }; break;
          default: throw new Error('Unexpected worker method ' + method);
        }
        queueMicrotask(() => listeners.forEach(listener => listener({
          type: 'worker-response', workerId: 'git',
          response: { id, method, result: { type: 'ok', value } },
        })));
        return Promise.resolve();
      },
    } },
  });
  const actions = createProjectGitActions({
    async requestRPC({ method, params }) {
      rpcCalls.push({ method, params });
      let result;
      switch (method) {
        case 'thread/start': result = { thread: { id: 'temporary' } }; break;
        case 'turn/start':
          if (switchProject) current = false;
          else {
            // Results can arrive before the turn/start acknowledgement.
            for (const [method, details] of [
              ['turn/started', { turn: { id: 'turn' } }],
              ['item/completed', { turnId: 'turn', item: { type: 'agentMessage', text: '{"message":"Update application behavior"}' } }],
              ['turn/completed', { turn: { id: 'turn', status: 'completed' } }],
            ]) {
              for (const listener of notifications) listener({
                data: { type: 'mcp-notification', hostId: 'local', method,
                  params: { threadId: 'temporary', ...details } },
              });
            }
          }
          result = { turn: { id: 'turn' } }; break;
        case 'thread/unsubscribe':
        case 'turn/interrupt': result = {}; break;
        default: throw new Error('Unexpected RPC method ' + method);
      }
      return JSON.stringify({ result });
    },
  });
  return { actions, workerCalls, rpcCalls, notifications, options: { isCurrent: () => current, report() {} } };
}

test('Commit runs directly without any native chat controls and releases its temporary session', async () => {
  const { actions, workerCalls, rpcCalls, notifications, options } = fixture();
  try {
    await actions.run('/project', 'Commit', options);
    const commit = workerCalls.find(call => call.method === 'commit');
    assert.equal(commit.params.message, 'Update application behavior');
    assert.equal(commit.params.includeUnstaged, true);
    assert.equal(workerCalls.some(call => call.method === 'push'), false);
    assert.equal(rpcCalls.find(call => call.method === 'thread/start').params.ephemeral, true);
    assert.equal(rpcCalls.at(-1).method, 'thread/unsubscribe');
    assert.equal(rpcCalls.some(call => ['thread/turns/list', 'thread/items/list'].includes(call.method)), false);
    assert.equal(notifications.size, 0);
  } finally { actions.destroy(); }
});

test('Commit & push reports a retained local commit when the push fails, without retrying writes', async () => {
  const { actions, workerCalls, options } = fixture({ failPush: true });
  try {
    await assert.rejects(actions.run('/project', 'Commit & push', options),
      /Committed locally\. Push did not complete\. Rejected by remote/);
    assert.equal(workerCalls.filter(call => call.method === 'commit').length, 1);
    assert.equal(workerCalls.filter(call => call.method === 'push').length, 1);
    assert.equal(workerCalls.find(call => call.method === 'push').params.force, false);
    assert.equal(actions.isRunning('/project'), false);
  } finally { actions.destroy(); }
});

test('Leaving the project during message generation prevents Git writes and releases the session', async () => {
  const { actions, workerCalls, rpcCalls, options } = fixture({ switchProject: true });
  try {
    await assert.rejects(actions.run('/project', 'Commit', options), /selected project changed/);
    assert.equal(workerCalls.some(call => ['commit', 'push'].includes(call.method)), false);
    assert.equal(rpcCalls.some(call => call.method === 'turn/interrupt'), true);
    assert.equal(rpcCalls.at(-1).method, 'thread/unsubscribe');
  } finally { actions.destroy(); }
});

for (const action of ['Commit', 'Commit & push']) {
  for (const stage of ['initial', 'verification']) {
    test(`${action} stops when the ${stage} diff is too large to verify`, async () => {
      const tooLarge = { type: 'error', error: { type: 'diff-too-large' } };
      const diffResponses = stage === 'initial'
        ? [tooLarge, tooLarge]
        : [{ type: 'success', unifiedDiff: '+Added a change' }, tooLarge];
      const { actions, workerCalls, rpcCalls, notifications, options } = fixture({ diffResponses });
      try {
        await assert.rejects(actions.run('/project', action, options), /diff is too large to verify/i);
        assert.equal(workerCalls.some(call => ['commit', 'push'].includes(call.method)), false);
        assert.equal(actions.isRunning('/project'), false);
        assert.equal(notifications.size, 0);
        if (stage === 'initial') assert.equal(rpcCalls.length, 0);
        else assert.equal(rpcCalls.at(-1).method, 'thread/unsubscribe');
      } finally { actions.destroy(); }
    });
  }
}

test('Commit rejects a successful response without diff content', async () => {
  const { actions, workerCalls, options } = fixture({ diffResponses: [{ type: 'success' }, { type: 'success' }] });
  try {
    await assert.rejects(actions.run('/project', 'Commit', options), /did not provide a diff/i);
    assert.equal(workerCalls.some(call => call.method === 'commit'), false);
  } finally { actions.destroy(); }
});
