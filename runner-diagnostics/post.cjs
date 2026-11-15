'use strict';
const { hold, STATE_NAME } = require('./core.cjs');

async function post(env = process.env, options = {}) {
  const saved = env['STATE_' + STATE_NAME];
  if (!saved) { console.log('Diagnostic hold was not registered; skipping.'); return 'unregistered'; }
  let record;
  try { record = JSON.parse(saved); }
  catch { throw new Error('Invalid saved runner diagnostics state.'); }
  const controller = new AbortController();
  const interrupt = () => controller.abort();
  process.once('SIGINT', interrupt);
  process.once('SIGTERM', interrupt);
  if (process.platform === 'win32') process.once('SIGBREAK', interrupt);
  try { return await hold(record, { ...options, signal: options.signal ?? controller.signal }); }
  finally {
    process.removeListener('SIGINT', interrupt);
    process.removeListener('SIGTERM', interrupt);
    if (process.platform === 'win32') process.removeListener('SIGBREAK', interrupt);
  }
}
module.exports = { post };
if (require.main === module) post().then(result => {
  if (result === 'cancelled') process.exitCode = 130;
}).catch(error => { console.error(error.message); process.exitCode = 1; });
