'use strict';
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const path = require('node:path');
const os = require('node:os');
const { spawn, spawnSync } = require('node:child_process');
const { settings, holdWindow, hold, MINUTE, STATE_NAME } = require('../runner-diagnostics/core.cjs');
const { register } = require('../runner-diagnostics/main.cjs');
const { post } = require('../runner-diagnostics/post.cjs');

const start = Date.UTC(2026, 0, 1);
const startUp = 1000000;
const record = extra => ({ enabled: true, durationMinutes: 60, marginMinutes: 30, startedAt: start, startedUptimeMs: startUp, ...extra });

test('defaults are disabled, sixty minutes and a thirty-minute margin', () => {
  assert.deepEqual(settings(), { enabled: false, durationMinutes: 60, marginMinutes: 30 });
  assert.equal(holdWindow(record({ enabled: false }), start).durationMs, 0);
});
test('duration and margin enforce whole-number boundaries and maximum sentinel', () => {
  for (const value of [0, -2, 361, 1.5, NaN, Infinity, '', true]) {
    assert.throws(() => settings({ durationMinutes: value }));
  }
  for (const value of [0, -1, 360, 30.5, NaN, '', false]) {
    assert.throws(() => settings({ marginMinutes: value }));
  }
  for (const value of [1, 60, 360, -1]) assert.equal(settings({ durationMinutes: value }).durationMinutes, value);
  for (const value of [1, 30, 359]) assert.equal(settings({ marginMinutes: value }).marginMinutes, value);
  for (const enabled of ['yes', [true], null, 1]) assert.throws(() => settings({ enabled }));
});
test('normal holds use their requested duration within the whole-job budget', () => {
  const window = holdWindow(record(), start + 20 * MINUTE);
  assert.equal(window.durationMs, 60 * MINUTE);
  assert.equal(window.deadline, start + 80 * MINUTE);
  assert.equal(window.cutoff, start + 330 * MINUTE);
});
test('maximum and long holds stop at job start plus six hours minus the margin', () => {
  for (const duration of [-1, 360]) {
    const window = holdWindow(record({ durationMinutes: duration }), start + 100 * MINUTE);
    assert.equal(window.durationMs, 230 * MINUTE);
    assert.equal(window.deadline, start + 330 * MINUTE);
  }
  assert.equal(holdWindow(record({ durationMinutes: -1, marginMinutes: 60 }), start + 100 * MINUTE).durationMs, 200 * MINUTE);
});
test('exhausted budgets and backward timestamps never grant extra time', () => {
  assert.equal(holdWindow(record(), start + 330 * MINUTE).reason, 'budget-exhausted');
  assert.equal(holdWindow(record(), start + 400 * MINUTE).durationMs, 0);
  assert.equal(holdWindow(record(), start - 1).reason, 'clock-skew');
  for (const value of [null, '123', -1, NaN]) assert.throws(() => holdWindow(record({ startedAt: value }), start));
});
test('uptime counts work completed before the hold even if wall time moved backwards', () => {
  const window = holdWindow(record({ durationMinutes: -1 }), start + 20 * MINUTE, startUp + 100 * MINUTE);
  assert.equal(window.durationMs, 230 * MINUTE);
  assert.equal(holdWindow(record(), start, startUp - 1).reason, 'clock-skew');
});
test('timed wait uses bounded slices and completes without waiting past its deadline', async () => {
  let wall = start, mono = 0;
  const sleeps = [];
  const result = await hold(record({ durationMinutes: 2 }), {
    now: () => wall, monotonicNow: () => mono, uptimeNow: () => startUp + mono, log: () => {},
    sleep: async ms => { sleeps.push(ms); wall += ms; mono += ms; }
  });
  assert.equal(result, 'completed');
  assert.deepEqual(sleeps, [MINUTE, MINUTE]);
});
test('backward wall-clock changes cannot extend the monotonic hold budget', async () => {
  let wall = start, mono = 0, total = 0;
  await hold(record({ durationMinutes: 2 }), {
    now: () => wall, monotonicNow: () => mono, uptimeNow: () => startUp + mono, log: () => {},
    sleep: async ms => { total += ms; mono += ms; wall -= MINUTE; }
  });
  assert.equal(total, 2 * MINUTE);
});
test('forward clock changes end the wait at the wall-clock cutoff', async () => {
  let wall = start, mono = 0, count = 0;
  await hold(record(), {
    now: () => wall, monotonicNow: () => mono, uptimeNow: () => startUp + mono, log: () => {},
    sleep: async ms => { count++; mono += ms; wall += 400 * MINUTE; }
  });
  assert.equal(count, 1);
});
test('cancellation interrupts the wait and does not continue sleeping', async () => {
  const controller = new AbortController();
  const result = await hold(record(), {
    now: () => start, monotonicNow: () => 0, uptimeNow: () => startUp, signal: controller.signal, log: () => {},
    sleep: async () => { controller.abort(); const error = new Error('cancelled'); error.name = 'AbortError'; throw error; }
  });
  assert.equal(result, 'cancelled');
});
test('registration persists only validated policy and the first-step start timestamp', async t => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), 'amith-diagnostics-'));
  t.after(() => fs.rm(root, { recursive: true, force: true }));
  const state = path.join(root, 'state');
  const saved = await register({
    GITHUB_STATE: state, 'INPUT_KEEP-RUNNER-ALIVE': 'true',
    'INPUT_KEEP-RUNNER-ALIVE-MINUTES': '-1', 'INPUT_RUNNER-TIMEOUT-MARGIN-MINUTES': '30'
  }, () => start, () => startUp);
  assert.deepEqual(saved, record({ durationMinutes: -1 }));
  assert.equal((await fs.readFile(state, 'utf8')).trim(), STATE_NAME + '=' + JSON.stringify(saved));
  const before = await fs.readFile(state, 'utf8');
  await assert.rejects(register({ GITHUB_STATE: state, 'INPUT_KEEP-RUNNER-ALIVE-MINUTES': '0' }), /1-360/);
  assert.equal(await fs.readFile(state, 'utf8'), before);
});
test('post hook restores state, tolerates unregistered setup and removes signal listeners', async () => {
  assert.equal(await post({}), 'unregistered');
  for (const state of ['broken JSON', 'null', '[]']) await assert.rejects(post({ ['STATE_' + STATE_NAME]: state }), /Invalid saved/);
  const listeners = process.listenerCount('SIGINT');
  const result = await post({ ['STATE_' + STATE_NAME]: JSON.stringify(record()) }, { now: () => start + 400 * MINUTE, uptimeNow: () => startUp + 400 * MINUTE, log: () => {} });
  assert.equal(result, 'budget-exhausted');
  assert.equal(process.listenerCount('SIGINT'), listeners);
});
test('post hook does not overwrite a prior failure exit code', () => {
  const postPath = require.resolve('../runner-diagnostics/post.cjs');
  const code = "process.exitCode=23; require(" + JSON.stringify(postPath) + ").post(process.env);";
  const result = spawnSync(process.execPath, ['-e', code], {
    cwd: path.dirname(postPath),
    env: { ...process.env, ['STATE_' + STATE_NAME]: JSON.stringify(record({ enabled: false })) },
    encoding: 'utf8', timeout: 5000
  });
  assert.ifError(result.error);
  assert.equal(result.status, 23, result.stderr);
});
test('real post entry point caps a requested minute to a nearly exhausted job budget', () => {
  const now = Date.now();
  const saved = record({ startedAt: now - 330 * MINUTE + 1000, startedUptimeMs: Math.floor(os.uptime() * 1000), durationMinutes: 1 });
  const result = spawnSync(process.execPath, [require.resolve('../runner-diagnostics/post.cjs')], {
    env: { ...process.env, ['STATE_' + STATE_NAME]: JSON.stringify(saved) },
    encoding: 'utf8', timeout: 5000
  });
  assert.ifError(result.error);
  assert.equal(result.status, 0);
  assert.match(result.stdout, /Diagnostic hold (finished|skipped)/);
  assert.ok(Date.now() - now < 5000);
});
test('real post entry point terminates promptly when interrupted', async () => {
  const child = spawn(process.execPath, [require.resolve('../runner-diagnostics/post.cjs')], {
    env: { ...process.env, ['STATE_' + STATE_NAME]: JSON.stringify(record({ startedAt: Date.now(), startedUptimeMs: Math.floor(os.uptime() * 1000), durationMinutes: 1 })) },
    stdio: ['ignore', 'pipe', 'pipe']
  });
  let output = '';
  const outcome = await new Promise((resolve, reject) => {
    const timer = setTimeout(() => { child.kill(); reject(new Error('Diagnostic hold did not stop on cancellation')); }, 5000);
    child.on('error', error => { clearTimeout(timer); reject(error); });
    child.stdout.on('data', data => {
      output += data.toString();
      if (output.includes('Holding runner')) child.kill('SIGTERM');
    });
    child.on('close', (code, signal) => { clearTimeout(timer); resolve({ code, signal }); });
  });
  assert.notEqual(outcome.code, 0);
});
