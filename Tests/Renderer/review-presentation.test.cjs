const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { test } = require('node:test');
const source = fs.readFileSync(path.join(__dirname,
  '../../Sources/CodexDashboard/Resources/Dashboard/Reviews/review-presentation.js'), 'utf8');
const presentation = vm.runInNewContext(`${source}\nreviewPresentation`);

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
