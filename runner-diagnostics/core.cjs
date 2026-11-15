'use strict';
const { setTimeout: delay } = require('node:timers/promises');
const { performance } = require('node:perf_hooks');
const os = require('node:os');

const JOB_LIMIT_MINUTES = 360;
const MINUTE = 60000;
const STATE_NAME = 'AMITH_RUNNER_DIAGNOSTICS';

function integer(value, name) {
  if (!['number', 'string'].includes(typeof value) || String(value).trim() === '' || !Number.isSafeInteger(Number(value))) {
    throw new Error(name + ' must be a whole number.');
  }
  return Number(value);
}
function settings({ enabled = false, durationMinutes = 60, marginMinutes = 30 } = {}) {
  if (!['boolean', 'string'].includes(typeof enabled)) throw new Error('keep-runner-alive must be true or false.');
  const flag = String(enabled).trim().toLowerCase();
  if (!['true', 'false'].includes(flag)) throw new Error('keep-runner-alive must be true or false.');
  const duration = integer(durationMinutes, 'keep-runner-alive-minutes');
  const margin = integer(marginMinutes, 'runner-timeout-margin-minutes');
  if (duration !== -1 && (duration < 1 || duration > JOB_LIMIT_MINUTES)) {
    throw new Error('keep-runner-alive-minutes must be 1-360, or -1 for the remaining budget.');
  }
  if (margin < 1 || margin >= JOB_LIMIT_MINUTES) {
    throw new Error('runner-timeout-margin-minutes must be 1-359.');
  }
  return { enabled: flag === 'true', durationMinutes: duration, marginMinutes: margin };
}
function holdWindow(record, now = Date.now(), uptimeMs) {
  if (!record || typeof record !== 'object' || Array.isArray(record)) throw new Error('Invalid saved runner diagnostics state.');
  const policy = settings(record);
  if (!Number.isSafeInteger(record.startedAt) || record.startedAt < 0 || !Number.isSafeInteger(now)) {
    throw new Error('Invalid diagnostic job-start timestamp.');
  }
  if (!Number.isSafeInteger(record.startedUptimeMs) || record.startedUptimeMs < 0) throw new Error('Invalid diagnostic uptime timestamp.');
  if (uptimeMs === undefined) uptimeMs = record.startedUptimeMs + Math.max(0, now - record.startedAt);
  if (!Number.isFinite(uptimeMs) || uptimeMs < record.startedUptimeMs) {
    return { reason: 'clock-skew', durationMs: 0 };
  }
  const budget = (JOB_LIMIT_MINUTES - policy.marginMinutes) * MINUTE;
  const cutoff = record.startedAt + budget;
  const uptimeCutoff = record.startedUptimeMs + budget;
  if (!policy.enabled) return { reason: 'disabled', durationMs: 0, cutoff };
  // A clock moving behind the recorded start cannot provide a safe budget.
  if (now < record.startedAt) return { reason: 'clock-skew', durationMs: 0, cutoff };
  const available = Math.max(0, Math.min(cutoff - now, uptimeCutoff - uptimeMs));
  const requested = policy.durationMinutes === -1 ? available : policy.durationMinutes * MINUTE;
  const durationMs = Math.min(requested, available);
  return { reason: durationMs ? 'hold' : 'budget-exhausted', durationMs, cutoff, uptimeCutoff, deadline: now + durationMs };
}
async function hold(record, {
  now = Date.now, monotonicNow = () => performance.now(), uptimeNow = () => os.uptime() * 1000,
  sleep = (ms, signal) => delay(ms, undefined, { signal }),
  signal, log = console.log
} = {}) {
  const window = holdWindow(record, now(), uptimeNow());
  if (!window.durationMs) {
    log('Diagnostic hold skipped: ' + window.reason + '.');
    return window.reason;
  }
  log('Holding runner for diagnostics until ' + new Date(window.deadline).toISOString() + '. Cancel the workflow to end the hold early.');
  // Wall time enforces the job cutoff; monotonic time prevents backward clock
  // adjustments from extending the amount of time originally granted.
  const end = monotonicNow() + window.durationMs;
  while (true) {
    if (signal?.aborted) { log('Diagnostic hold interrupted.'); return 'cancelled'; }
    const remaining = Math.min(end - monotonicNow(), window.deadline - now(), window.cutoff - now(), window.uptimeCutoff - uptimeNow());
    if (remaining <= 0) break;
    try { await sleep(Math.min(MINUTE, remaining), signal); }
    catch (error) {
      if (signal?.aborted && error.name === 'AbortError') { log('Diagnostic hold interrupted.'); return 'cancelled'; }
      throw error;
    }
    if (monotonicNow() < end && now() < window.deadline) {
      log('Diagnostic hold active; at most ' + Math.ceil(Math.max(0, end - monotonicNow()) / 1000) + ' seconds remain.');
    }
  }
  log('Diagnostic hold finished; allowing job cleanup to complete.');
  return 'completed';
}
module.exports = { JOB_LIMIT_MINUTES, MINUTE, STATE_NAME, settings, holdWindow, hold };
