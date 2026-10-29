const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { test } = require('node:test');
const source = fs.readFileSync(path.join(__dirname,
  '../../Sources/CodexDashboard/Resources/Dashboard/Reviews/review-presentation.js'), 'utf8');
const presentation = vm.runInNewContext(`${source}\nreviewPresentation`, {
  composerPresets: { reasoningLabel: value => ({ high: 'High' })[value] || value },
});

test('withdrawn findings finish evaluation without claiming a commit', () => {
  const loop = { phase: 'completed', rounds: [{ fixRequested: true,
    result: { outcome: 'withdrawn', fixCommit: null } }] };
  const stages = presentation.roundStages(loop);
  assert.equal(stages[0].state, 'done');
  assert.equal(stages[1].state, 'done');
  assert.equal(stages[1].description, 'Findings withdrawn; no commit needed');
  assert.equal(presentation.roundStatus(loop.rounds[0], false), 'Findings withdrawn');
});

test('fixed, clean, and ongoing verification retain distinct stage descriptions', () => {
  const loop = { phase: 'completed', rounds: [{ result: { outcome: 'fixed' } }] };
  assert.equal(presentation.roundStages(loop)[1].description, 'Done');
  loop.rounds[0].result.outcome = 'clean';
  assert.equal(presentation.roundStages(loop)[1].description, 'Not needed');
  loop.phase = 'running';
  loop.rounds[0] = { fixVerification: { targetRevision: 'merged-head' } };
  assert.equal(presentation.roundStages(loop)[1].description, 'Reverifying fixes');
});

test('only fixed rounds display a fix commit; checked revisions are separate', () => {
  assert.equal(presentation.roundStatus({ result: {
    outcome: 'fixed', fixCommit: '1234567890', verifiedRevision: 'later-head',
  } }, false), 'Fixes committed · 12345678');
  for (const [outcome, label] of [['clean', 'No findings'], ['withdrawn', 'Findings withdrawn']]) {
    assert.equal(presentation.roundStatus({ result: { outcome, verifiedRevision: 'base-head' } }, false), label);
  }
  assert.equal(presentation.roundStatus({ result: {
    outcome: 'fixed', verifiedRevision: 'folder-fingerprint',
  } }, false, 'folder'), 'Fixes applied & verified');
});

test('settings retain labels, ordering, saved model fallback, and folder publishing wording', () => {
  const loop = { reviewType: 'organisation', promptContext: { kind: 'personal' }, priorityLimit: 'P0',
    preserveUICopy: true, liveTesting: true, muteTestPlayback: false, reloadExtensionBeforeTesting: true,
    speed: 'fast', workspaceKind: 'folder', pushToRemote: true,
    reviewSelection: { modelID: 'review', reasoningEffort: 'high' }, fixSelection: { modelID: 'saved' } };
  const labels = presentation.settingsLabels(loop, [{ modelID: 'review', displayName: 'Review model' }],
    [{ id: 'organisation', label: 'Structure' }]);
  assert.deepEqual(Array.from(labels), ['Structure', 'Personal project', 'P0', 'UI copy unchanged',
    'Live testing enabled', 'Mute test playback: Off', 'Extension reload enabled', 'Fast',
    'Save and verify folder changes', 'Review: Review model · High', 'Fix: saved']);
  assert.equal(presentation.priorityLabel('P2'), 'P0–P2');
  assert.equal(presentation.phaseLabel({ phase: 'awaitingExtensionReload' }), 'Waiting for extension reload');
  assert.deepEqual(Array.from(presentation.settingsLabels({ reviewType: 'content' }, [], [])),
    ['content', 'Project context not recorded', 'Standard', 'Keep commits local',
      'Review: Not recorded', 'Fix: Not recorded']);
});

test('controls distinguish queue, stopping, resume, pause, and retained history', () => {
  const controls = loop => JSON.parse(JSON.stringify(presentation.controls(loop, true)));
  assert.deepEqual(controls({ phase: 'queued' }), [{ action: 'stop', label: 'Cancel queued loop' }]);
  assert.deepEqual(controls({ phase: 'stopping' }), [{ action: 'stop', label: 'Retry Stop' }]);
  for (const phase of ['paused', 'blocked']) {
    assert.equal(controls({ phase })[0].label, 'Resume');
  }
  assert.equal(controls({ phase: 'awaitingExtensionReload' })[0].label, 'Extension reloaded — continue');
  assert.equal(controls({ phase: 'running' })[0].label, 'Pause after round');
  assert.equal(controls({ phase: 'waiting' })[0].label, 'Pause');
  assert.deepEqual(controls({ phase: 'running', pauseRequested: true })[0],
    { action: 'pause', disabled: true, label: 'Pausing after round…' });
  const finished = { id: 'loop', phase: 'completed', isFinished: true };
  assert.deepEqual(controls(finished), [{ clear: 'loop', label: 'Move to history' }]);
  assert.equal(presentation.controls(finished, false).length, 0);
});

test('metrics count addressed findings only in fixed rounds and deduplicate fix commits', () => {
  const metrics = presentation.metrics({ rounds: [
    { number: 1, result: { outcome: 'fixed', addressedFindingCount: 2, fixCommit: 'same' } },
    { number: 2, result: { outcome: 'fixed', addressedFindingCount: 1, fixCommit: 'same' } },
    { number: 3, result: { outcome: 'blocked', addressedFindingCount: 10, fixCommit: 'other' } },
    { number: 4, review: { findings: [{}, {}] }, result: { outcome: 'withdrawn' } },
  ] });
  assert.deepEqual(JSON.parse(JSON.stringify(metrics)),
    { roundLabel: 'Round 4', findings: 2, addressed: 3, commits: 1 });
});

test('pending control requests update availability without replacing cached buttons', () => {
  const cardSource = fs.readFileSync(path.join(__dirname,
    '../../Sources/CodexDashboard/Resources/Dashboard/Reviews/review-loop-card-view.js'), 'utf8');
  const anchor = 'return { renderCards };';
  assert.equal(cardSource.split(anchor).length, 2);
  const view = vm.runInNewContext(`${cardSource.replace(anchor, 'return { renderControls };')}\nreviewLoopCardView`, {
    reviewPresentation: presentation,
    domUtils: { escapeHTML: value => value },
  });
  let writes = 0;
  let buttons;
  const controls = {
    set innerHTML(markup) {
      writes++;
      buttons = [...markup.matchAll(/<button /g)].map(() => ({ dataset: {} }));
    },
    querySelectorAll: () => buttons,
  };
  const root = { querySelector: () => controls };
  const loop = { id: 'loop', phase: 'running' };
  view.renderControls(root, loop, null, false);
  const initialButtons = buttons;
  view.renderControls(root, loop, { kind: 'pause' }, false);
  assert.equal(buttons, initialButtons);
  assert.ok(buttons.every(button => button.disabled));
  view.renderControls(root, loop, null, false);
  assert.equal(writes, 1);
  assert.ok(buttons.every(button => !button.disabled));
  loop.pauseRequested = true;
  view.renderControls(root, loop, null, false);
  assert.equal(buttons[0].disabled, true);
  assert.equal(buttons[1].disabled, false);
});
