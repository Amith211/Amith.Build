'use strict';
const fs = require('node:fs/promises');
const os = require('node:os');
const { settings, STATE_NAME } = require('./core.cjs');

async function register(env = process.env, now = Date.now, uptimeNow = () => os.uptime() * 1000) {
  const startedAt = now();
  const startedUptimeMs = Math.floor(uptimeNow());
  const policy = settings({
    enabled: env['INPUT_KEEP-RUNNER-ALIVE'] ?? 'false',
    durationMinutes: env['INPUT_KEEP-RUNNER-ALIVE-MINUTES'] ?? '60',
    marginMinutes: env['INPUT_RUNNER-TIMEOUT-MARGIN-MINUTES'] ?? '30'
  });
  if (!env.GITHUB_STATE) throw new Error('Runner diagnostics registration requires GITHUB_STATE.');
  const record = { ...policy, startedAt, startedUptimeMs };
  await fs.appendFile(env.GITHUB_STATE, STATE_NAME + '=' + JSON.stringify(record) + os.EOL);
  console.log(policy.enabled
    ? 'Registered post-job diagnostic hold with a ' + policy.marginMinutes + '-minute cleanup margin.'
    : 'Post-job diagnostic hold is disabled.');
  return record;
}
module.exports = { register };
if (require.main === module) register().catch(error => { console.error(error.message); process.exitCode = 1; });
