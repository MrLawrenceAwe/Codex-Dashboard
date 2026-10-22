const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { test } = require('node:test');

const source = fs.readFileSync(path.join(__dirname,
  '../../Sources/CodexDashboard/Resources/Dashboard/Core/codex-ui-contracts.js'), 'utf8');

test('model-picker compatibility uses the supplied reasoning schema', async () => {
  // A metadata-only fixture: no DOM, browser, or UI is launched.
  const trigger = {
    dataset: { selectedReasoningEffort: 'future-effort' },
    getAttribute: () => 'true',
  };
  const picker = { querySelector: () => ({}) };
  const contract = vm.runInNewContext(`${source}\ncodexUIContracts`, {
    COMPOSER_PRESET_SCHEMA: { reasoningEfforts: ['future-effort'] },
    domUtils: { isVisible: () => true, waitFor: async value => value() },
    document: {
      querySelectorAll: selector => selector === '[data-codex-intelligence-trigger]'
        ? [trigger] : selector === '[data-model-picker-view]' ? [picker] : [],
    },
  });
  assert.equal(await contract.probeModelPickerControls(), true);
  trigger.dataset.selectedReasoningEffort = 'medium';
  assert.equal(await contract.probeModelPickerControls(), false);
});
