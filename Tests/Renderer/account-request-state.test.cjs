const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { test } = require('node:test');

function setup() {
  const source = fs.readFileSync(path.join(__dirname,
    '../../Sources/CodexDashboard/Resources/Dashboard/Accounts/account-popover.js'), 'utf8');
  // Expose the queue entry point without mounting a browser or changing the public API.
  const anchor = 'return { applySnapshot, readQueuedAction,';
  assert.equal(source.split(anchor).length, 2);
  let now = 1000;
  const timers = new Map();
  let timerID = 0;
  const api = vm.runInNewContext(`${source.replace(anchor,
    'return { queue, actionProgress, applySnapshot, readQueuedAction,')}\naccountPopover`, {
    crypto: { getRandomValues: values => values.fill(1) },
    Date: { now: () => now },
    setTimeout: callback => { timers.set(++timerID, callback); return timerID; },
    clearTimeout: id => timers.delete(id),
    document: { getElementById: () => null, querySelector: () => null },
    codexUIContracts: { profileMenu: () => null },
    usageResetNotice: { applySnapshot() {}, destroy() {} },
  });
  return { api, timers, advance: () => { now += 15001; } };
}

test('acknowledged requests survive snapshots and deadlines until matching completion', () => {
  const { api, timers, advance } = setup();
  api.queue('restartForSignIn');
  const request = JSON.parse(api.readQueuedAction());
  assert.deepEqual(Object.keys(request).sort(), ['accountID', 'kind', 'requestID']);
  assert.equal(api.actionProgress(), 'Sign-in request queued…');
  assert.equal(api.acknowledgeAction('wrong'), false);
  assert.equal(timers.size, 1);
  assert.equal(api.acknowledgeAction(request.requestID), true);
  assert.equal(timers.size, 0);
  assert.equal(api.actionProgress(), 'Request received. Checking Codex state…');
  advance();
  api.applySnapshot({ accounts: [], isBusy: false });
  api.queue('saveCurrentAccount');
  assert.equal(JSON.parse(api.readQueuedAction()).requestID, request.requestID);
  assert.equal(api.completeAction('wrong', {}), false);
  assert.equal(api.completeAction(request.requestID, { accounts: [], isBusy: false }), true);
  assert.equal(api.readQueuedAction(), 'null');
  assert.equal(api.actionProgress(), null);
  api.queue('saveCurrentAccount');
  assert.notEqual(JSON.parse(api.readQueuedAction()).requestID, request.requestID);
});

test('expiry cancels the old timer and rejects late completion before retry', () => {
  const { api, timers, advance } = setup();
  api.queue('saveCurrentAccount');
  const expired = JSON.parse(api.readQueuedAction());
  advance();
  assert.equal(api.readQueuedAction(), 'null');
  assert.equal(timers.size, 0);
  assert.equal(api.actionProgress(), null);
  api.queue('switchAccount', 'account');
  const retry = JSON.parse(api.readQueuedAction());
  assert.equal(retry.accountID, 'account');
  assert.equal(api.completeAction(expired.requestID, {}), false);
  assert.equal(api.acknowledgeAction(expired.requestID), false);
  assert.equal(JSON.parse(api.readQueuedAction()).requestID, retry.requestID);
  api.unmount();
  assert.equal(timers.size, 0);
  assert.equal(api.readQueuedAction(), 'null');
});

test('timer expiry and native busy snapshots retain queue gating', () => {
  const { api, timers } = setup();
  api.applySnapshot({ accounts: [], isBusy: true });
  api.queue('saveCurrentAccount');
  assert.equal(api.readQueuedAction(), 'null');
  api.applySnapshot({ accounts: [], isBusy: false });
  api.queue('saveCurrentAccount');
  assert.equal(api.actionProgress(), 'Account request queued…');
  [...timers.values()][0]();
  assert.equal(api.readQueuedAction(), 'null');
  assert.equal(timers.size, 0);
});
