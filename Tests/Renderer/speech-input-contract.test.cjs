const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { test } = require('node:test');

const source = fs.readFileSync(path.join(__dirname,
  '../../Sources/CodexDashboard/Resources/Dashboard/Core/codex-ui-contracts.js'), 'utf8');

function speechContract({ hostMarker = false, editState, props = {} } = {}) {
  const composerBody = { __reactFiber$test: { memoizedProps: props } };
  return vm.runInNewContext(`${source}\ncodexUIContracts`, {
    domUtils: {},
    document: {
      querySelector: selector => selector.includes('[data-edit-dictation-state=')
        ? (['starting', 'recording', 'transcribing'].includes(editState) ? {} : null)
        : (hostMarker ? {} : null),
      querySelectorAll: selector => selector.includes('[data-composer-body]') ? [composerBody] : [],
    },
  });
}

test('host speech detection covers startup and transcription on the composer body', () => {
  const activeStates = [
    { isDictating: true },
    { isDictationStarting: true },
    { isTranscribing: true },
    { startDictation() {}, isStarting: true },
    { startDictation() {}, isPreparing: true },
    { realtimeSession: { thread: { phase: 'connecting' } } },
  ];
  for (const props of activeStates) {
    const contract = speechContract({ props });
    assert.equal(contract.hasHostSpeechInput(), true);
    assert.equal(contract.hasActiveSpeechInput(), true);
  }
  for (const props of [{}, { isStarting: true }, { isPreparing: true },
    { realtimeSession: { thread: { phase: 'inactive' } } }]) {
    const contract = speechContract({ props });
    assert.equal(contract.hasHostSpeechInput(), false);
    assert.equal(contract.hasActiveSpeechInput(), false);
  }
});

test('host markers block edit dictation while its own active state only blocks focus changes', () => {
  const host = speechContract({ hostMarker: true });
  assert.equal(host.hasHostSpeechInput(), true);
  assert.equal(host.hasActiveSpeechInput(), true);

  for (const editState of ['starting', 'recording', 'transcribing', 'idle', 'error']) {
    const contract = speechContract({ editState });
    assert.equal(contract.hasHostSpeechInput(), false);
    assert.equal(contract.hasActiveSpeechInput(), ['starting', 'recording', 'transcribing'].includes(editState));
  }
});
