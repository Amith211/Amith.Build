'use strict';
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { spawnSync } = require('node:child_process');

// Evaluate the expressions actually shipped in the workflow, including GitHub's
// implicit success() check when no explicit status-check function is present.
const source = fs.readFileSync(path.join(__dirname, '../.github/workflows/build.yml'), 'utf8').replace(/\r\n/g, '\n');
const blocks = source.split(/^      - /m).slice(1);
const field = (block, name, indent = 8) => block.match(new RegExp('^ {' + indent + '}' + name + ':\\s*(.*)$', 'm'))?.[1].trim();
const step = id => {
  const index = blocks.findIndex(block => field(block, 'id') === id);
  assert.notEqual(index, -1, 'Missing workflow step ' + id);
  return { index, block: blocks[index], condition: field(blocks[index], 'if') };
};
const inputDefault = name => field(source.split('      ' + name + ':\n')[1].split(/\n {6}\S/)[0], 'default');
const retentionDefault = inputDefault('artifact-retention');
function state({ release = false, installer = 'success', container = 'success', releaseOutcome = 'skipped',
  retain = 'skipped', root = '', cancelled = false, previousSuccess = true,
  mode = retentionDefault, buildMode = 'all', policy = 'success' } = {}) {
  return { inputs: { release, 'artifact-retention': mode }, cancelled, previousSuccess, steps: {
    plan: { outputs: { 'build-mode': buildMode } }, 'retention-policy': { outcome: policy }, installer: { outcome: installer }, container: { outcome: container }, release: { outcome: releaseOutcome },
    retain: { outcome: retain, outputs: { 'retained-root': root } }
  } };
}
function evaluate(condition, context) {
  assert.ok(condition, 'A conditional retention/upload gate is required');
  let expression = condition.replace(/^\$\{\{\s*/, '').replace(/\s*\}\}$/, '');
  const hasStatusCheck = /\b(success|failure|cancelled|always)\s*\(/.test(expression);
  expression = expression.replace(/inputs\.artifact-retention/g, "inputs['artifact-retention']")
    .replace(/steps\.retention-policy/g, "steps['retention-policy']");
  expression = expression.replace(/steps\.plan\.outputs\.build-mode/g, "steps.plan.outputs['build-mode']");
  expression = expression.replace(/steps\.retain\.outputs\.retained-root/g, "steps.retain.outputs['retained-root']");
  if (!hasStatusCheck) expression = 'success() && (' + expression + ')';
  return !!vm.runInNewContext('(' + expression + ')', {
    inputs: context.inputs, steps: context.steps,
    cancelled: () => context.cancelled,
    success: () => context.previousSuccess && !context.cancelled,
    failure: () => !context.previousSuccess && !context.cancelled,
    always: () => true
  });
}
test('release precedes conditional retention and upload without masking its failure', () => {
  assert.ok(step('installer').index < step('container').index);
  assert.ok(step('container').index < step('release').index);
  assert.ok(step('release').index < step('retain').index);
  assert.ok(step('retain').index < step('upload').index);
  assert.notEqual(field(step('release').block, 'continue-on-error'), 'true');
  assert.equal(evaluate(step('release').condition, state({ release: true })), true);
  assert.equal(evaluate(step('release').condition, state()), false);
});
test('auto opt-in retains verified build-only packages with a one-day default', () => {
  assert.equal(evaluate(step('retain').condition, state({ mode: 'auto' })), true);
  assert.equal(retentionDefault, 'never');
  assert.equal(inputDefault('artifact-retention-days'), '1');
  assert.equal(field(step('upload').block, 'retention-days', 10), '${{ inputs.artifact-retention-days }}');
});
test('successful release runs skip the duplicate artifact copy', () => {
  const context = state({ mode: 'auto', release: true, releaseOutcome: 'success' });
  assert.equal(evaluate(step('retain').condition, context), false);
  assert.equal(evaluate(step('upload').condition, context), false);
});
test('auto opt-in retains and uploads failed releases despite the previous failed step', () => {
  const context = state({ mode: 'auto', release: true, releaseOutcome: 'failure', previousSuccess: false });
  assert.equal(evaluate(step('retain').condition, context), true);
  context.steps.retain = { outcome: 'success', outputs: { 'retained-root': '/verified/packages' } };
  assert.equal(evaluate(step('upload').condition, context), true);
});
test('cancelled or unsuccessful packaging runs do not start retention', () => {
  for (const installer of ['failure', 'skipped', 'cancelled']) {
    assert.equal(evaluate(step('retain').condition, state({ installer, previousSuccess: false })), false);
  }
  for (const release of [false, true]) {
    assert.equal(evaluate(step('retain').condition, state({ release, releaseOutcome: 'failure', cancelled: true })), false);
  }
});
test('failed, skipped or empty retention output is never uploaded', () => {
  for (const retain of ['failure', 'skipped', 'cancelled']) {
    assert.equal(evaluate(step('upload').condition, state({ retain, root: '/unverified/packages', previousSuccess: false })), false);
  }
  assert.equal(evaluate(step('upload').condition, state({ retain: 'success' })), false);
  assert.equal(evaluate(step('upload').condition, state({ retain: 'success', root: '/verified/packages', cancelled: true })), false);
});

test('always retains after either successful or failed releases and build-only runs', () => {
  for (const release of [false, true]) {
    for (const releaseOutcome of ['success', 'failure', 'skipped']) {
      assert.equal(evaluate(step('retain').condition, state({
        mode: 'always', release, releaseOutcome, previousSuccess: releaseOutcome !== 'failure'
      })), true);
    }
  }
});

test('default never disables retention regardless of release outcome', () => {
  assert.equal(retentionDefault, 'never');
  for (const release of [false, true]) {
    for (const releaseOutcome of ['success', 'failure', 'skipped']) {
      assert.equal(evaluate(step('retain').condition, state({
        release, releaseOutcome, previousSuccess: releaseOutcome !== 'failure'
      })), false);
    }
  }
});

test('all modes respect cancellation, packaging and input-validation gates', () => {
  for (const mode of ['auto', 'always', 'never', 'invalid']) {
    assert.equal(evaluate(step('retain').condition, state({ mode, cancelled: true })), false);
    for (const installer of ['failure', 'skipped', 'cancelled']) {
      assert.equal(evaluate(step('retain').condition, state({ mode, installer })), false);
    }
    assert.equal(evaluate(step('retain').condition, state({ mode, policy: 'failure' })), false);
  }
  assert.ok(step('retention-policy').index < step('installer').index);
});

test('actual workflow validation rejects invalid modes and nonpositive or fractional days', () => {
  const block = step('retention-policy').block;
  const script = block.split('        run: |')[1].split('\n').map(line => line.replace(/^          /, '')).join('\n');
  assert.ok(script.includes('TryParse'), 'Missing workflow input validation');
  for (const [mode, days, valid] of [
    ['auto', '14', true], ['always', '1', true], ['never', '400', true],
    ['AUTO', '14', false], ['invalid', '14', false], ['', '14', false],
    ['auto', '0', false], ['auto', '-1', false], ['auto', '401', false],
    ['auto', '1.5', false], ['never', 'no', false]
  ]) {
    const result = spawnSync('pwsh', ['-NoLogo', '-NoProfile', '-NonInteractive',
      '-Command', "$ErrorActionPreference = 'Stop'; " + script], {
      encoding: 'utf8',
      env: { ...process.env, AMITH_ARTIFACT_RETENTION: mode, AMITH_ARTIFACT_RETENTION_DAYS: days }
    });
    assert.ifError(result.error);
    assert.equal(result.status === 0, valid, mode + '/' + days + ': ' + result.stderr);
  }
});

test('failed or skipped container packaging blocks retention in every mode', () => {
  for (const mode of ['auto', 'always', 'never']) {
    for (const container of ['failure', 'skipped', 'cancelled']) {
      assert.equal(evaluate(step('retain').condition, state({ mode, container, previousSuccess: false })), false);
    }
  }
});

test('container-only runs can retain packages when the installer step is intentionally skipped', () => {
  for (const mode of ['auto', 'always']) {
    assert.equal(evaluate(step('retain').condition, state({ mode, buildMode: 'containers', installer: 'skipped' })), true);
    assert.equal(evaluate(step('retain').condition, state({ mode, buildMode: 'containers', installer: 'skipped', container: 'failure' })), false);
  }
  assert.equal(evaluate(step('retain').condition, state({ buildMode: 'containers', installer: 'skipped' })), false);
});

test('container-only workflow skips application packaging using the effective saved mode', () => {
  for (const name of ['Pack NuGet libraries', 'Publish applications', 'Archive applications', 'Package configured installers']) {
    const block = blocks.find(block => block.startsWith('name: ' + name + '\n'));
    assert.ok(block, name);
    const condition = field(block, 'if');
    assert.equal(evaluate(condition, state()), true);
    assert.equal(evaluate(condition, state({ buildMode: 'containers' })), false);
  }
});
