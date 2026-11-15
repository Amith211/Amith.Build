'use strict';
// No npm dependencies: the action must bootstrap a shell on a bare runner.
const fs = require('node:fs/promises');
const path = require('node:path');
const os = require('node:os');
const crypto = require('node:crypto');
const { spawnSync } = require('node:child_process');

function run(file, args) {
  const result = spawnSync(file, args, { encoding: 'utf8', timeout: 300000, windowsHide: true });
  if (result.error || result.status !== 0) throw new Error('Tool command failed: ' + file + ' (exit ' + result.status + (result.error ? ', ' + result.error.message : '') + ')');
  return result.stdout.trim();
}
function cacheRoot(value, env = process.env, platform = process.platform) {
  return path.resolve(value || env.AMITH_TOOL_CACHE || env.RUNNER_TOOL_CACHE ||
    (platform === 'linux' ? '/opt/hostedtoolcache' : path.join(os.homedir(), '.cache', 'amith-build', 'tools')));
}
function versionTag(value) {
  if (!value || value === 'latest') return 'latest';
  if (!/^v?\d+\.\d+\.\d+(-[0-9A-Za-z.-]+)?$/.test(value)) throw new Error('Use an exact tool release version, or leave it empty for latest stable.');
  return value.startsWith('v') ? value : 'v' + value;
}
function assetName(tool, tag, platform, arch) {
  const version = tag.replace(/^v/, '');
  if (!['win32', 'linux'].includes(platform) || !['x64', 'arm64'].includes(arch)) throw new Error('Shared tool setup supports Windows/Linux x64/arm64.');
  if (tool === 'pwsh') return 'powershell-' + version + '-' + (platform === 'win32' ? 'win' : 'linux') + '-' + arch + (platform === 'win32' ? '.zip' : '.tar.gz');
  return 'gh_' + version + '_' + (platform === 'win32' ? 'windows' : 'linux') + '_' + (arch === 'x64' ? 'amd64' : 'arm64') + (platform === 'win32' ? '.zip' : '.tar.gz');
}
async function sha(file) { return crypto.createHash('sha256').update(await fs.readFile(file)).digest('hex'); }
async function ready(directory, relative) {
  try {
    const receipt = JSON.parse(await fs.readFile(path.join(directory, '.amith-ready.json'), 'utf8'));
    return receipt.executable === relative && receipt.sha256 === await sha(path.join(directory, relative));
  } catch { return false; }
}
async function withLock(directory, operation) {
  await fs.mkdir(path.dirname(directory), { recursive: true });
  const lock = directory + '.lock';
  const deadline = Date.now() + 300000;
  while (true) {
    try { await fs.mkdir(lock); break; }
    catch (error) {
      if (error.code !== 'EEXIST') throw error;
      if (Date.now() >= deadline) throw new Error('Timed out waiting for tool cache lock: ' + lock + '. Check for an interrupted installer.');
      await new Promise(resolve => setTimeout(resolve, 500));
    }
  }
  try { return await operation(); } finally { await fs.rm(lock, { recursive: true, force: true }); }
}
async function installCached(directory, relative, installer, validate = file => run(file, ['--version'])) {
  return withLock(directory, async () => {
    if (await ready(directory, relative)) {
      console.log('Cache hit: ' + directory);
      validate(path.join(directory, relative));
      return path.join(directory, relative);
    }
    // Failed attempts never become ready entries; only our own version directory is replaced.
    const attempt = await fs.mkdtemp(directory + '.attempt-');
    try {
      await installer(attempt);
      const executable = path.join(attempt, relative);
      validate(executable);
      await fs.writeFile(path.join(attempt, '.amith-ready.json'), JSON.stringify({ executable: relative, sha256: await sha(executable) }));
      await fs.rm(directory, { recursive: true, force: true });
      await fs.rename(attempt, directory);
      console.log('Cached tool: ' + directory);
      return path.join(directory, relative);
    } finally { await fs.rm(attempt, { recursive: true, force: true }); }
  });
}
async function release(repo, selector, token) {
  const headers = { 'User-Agent': 'Amith.Build', Accept: 'application/vnd.github+json' };
  if (token) headers.Authorization = 'Bearer ' + token;
  const response = await fetch('https://api.github.com/repos/' + repo + '/releases/' + (selector === 'latest' ? 'latest' : 'tags/' + selector), { headers, signal: AbortSignal.timeout(60000) });
  if (!response.ok) throw new Error('Cannot resolve ' + repo + ' release (HTTP ' + response.status + ').');
  return response.json();
}
async function installTool(tool, options) {
  const repo = tool === 'pwsh' ? 'PowerShell/PowerShell' : 'cli/cli';
  const metadata = await release(repo, versionTag(options.version), options.token);
  const name = assetName(tool, metadata.tag_name, process.platform, process.arch);
  const asset = metadata.assets.find(item => item.name.toLowerCase() === name.toLowerCase());
  if (!asset) throw new Error('Release has no supported asset: ' + name);
  const directory = path.join(options.root, 'amith-build', tool, metadata.tag_name, process.platform + '-' + process.arch);
  const exe = tool + (process.platform === 'win32' ? '.exe' : '');
  const relative = tool === 'gh' ? path.join('bin', exe) : exe;
  return installCached(directory, relative, async attempt => {
    // Credentials are never attached to release-asset downloads or redirects.
    const response = await fetch(asset.browser_download_url, { signal: AbortSignal.timeout(300000) });
    if (!response.ok) throw new Error('Cannot download ' + name + ' (HTTP ' + response.status + ').');
    const bytes = Buffer.from(await response.arrayBuffer());
    let digest = asset.digest;
    if (!digest) {
      const checksums = metadata.assets.find(item => /^(hashes\.sha256|gh_.*_checksums\.txt)$/.test(item.name));
      if (!checksums) throw new Error('Release has no SHA256 verification data.');
      const sums = await fetch(checksums.browser_download_url, { signal: AbortSignal.timeout(60000) });
      if (!sums.ok) throw new Error('Cannot download tool checksums.');
      const line = (await sums.text()).split(/\r?\n/).find(line => line.trim().toLowerCase().endsWith(name.toLowerCase()));
      const hash = line && line.match(/[a-f0-9]{64}/i);
      if (!hash) throw new Error('Tool checksum was not found.');
      digest = 'sha256:' + hash[0].toLowerCase();
    }
    if (digest.toLowerCase() !== 'sha256:' + crypto.createHash('sha256').update(bytes).digest('hex')) throw new Error('Tool archive SHA256 mismatch.');
    const archive = path.join(attempt, name);
    const unpack = path.join(attempt, 'unpack');
    await fs.writeFile(archive, bytes);
    await fs.mkdir(unpack);
    if (process.platform === 'win32') {
      const quote = value => "'" + value.replace(/'/g, "''") + "'";
      run(path.join(process.env.SystemRoot, 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe'),
        ['-NoProfile', '-NonInteractive', '-Command', "$ErrorActionPreference='Stop'; Add-Type -AssemblyName System.IO.Compression.FileSystem; " + '[IO.Compression.ZipFile]::ExtractToDirectory(' + quote(archive) + ',' + quote(unpack) + ')']);
    } else { run('tar', ['-xzf', archive, '-C', unpack]); }
    const contents = tool === 'gh' && process.platform !== 'win32'
      ? path.join(unpack, name.replace(/\.tar\.gz$/, '')) : unpack;
    for (const item of await fs.readdir(contents)) await fs.rename(path.join(contents, item), path.join(attempt, item));
    await fs.rm(unpack, { recursive: true, force: true });
    await fs.rm(archive);
    if (process.platform !== 'win32') await fs.chmod(path.join(attempt, relative), 0o755);
  });
}
async function legacyPaths(roots) {
  const directories = new Set();
  async function visit(directory, depth) {
    let entries;
    try { entries = await fs.readdir(directory, { withFileTypes: true }); } catch { return; }
    for (const entry of entries) {
      if (entry.isFile()) directories.add(directory);
      else if (entry.isDirectory() && depth > 0) await visit(path.join(directory, entry.name), depth - 1);
    }
  }
  for (const root of roots.filter(Boolean)) await visit(root, 4);
  return [...directories];
}
function buildToolPath(required, legacy, existing, platform = process.platform) {
  const delimiter = platform === 'win32' ? ';' : ':';
  // Leave room for the runner's remaining environment and later tool setup.
  const budget = platform === 'win32' ? 24000 : 64000;
  const key = directory => platform === 'win32' ? directory.toLowerCase() : directory;
  const seen = new Set();
  const inherited = [];
  for (const directory of (existing || '').split(delimiter)) {
    if (directory && !seen.has(key(directory))) {
      seen.add(key(directory));
      inherited.push(directory);
    }
  }
  const additions = [];
  for (const directory of required) {
    if (/[\r\n]/.test(directory)) throw new Error('PATH entry must be a single line.');
    const index = inherited.findIndex(entry => key(entry) === key(directory));
    if (index >= 0) inherited.splice(index, 1);
    if (!additions.some(entry => key(entry) === key(directory))) additions.push(directory);
    seen.add(key(directory));
  }
  const size = value => platform === 'win32' ? value.length : Buffer.byteLength(value);
  let value = [...additions, ...inherited].join(delimiter);
  if (size(value) > budget) throw new Error('Existing PATH and required tools exceed the safe PATH budget.');
  let omitted = 0;
  for (const directory of legacy) {
    if (/[\r\n]/.test(directory)) throw new Error('PATH entry must be a single line.');
    if (seen.has(key(directory))) continue;
    seen.add(key(directory));
    if (size(value) + size(directory) + delimiter.length > budget) { omitted++; continue; }
    additions.push(directory);
    value = [...additions, ...inherited].join(delimiter);
  }
  return { additions, value, omitted };
}
async function main() {
  const input = name => process.env['INPUT_' + name.toUpperCase()] || '';
  const root = cacheRoot(input('tool-cache-path'));
  if (/[\r\n]/.test(root)) throw new Error('Tool cache path must be a single line.');
  // Preserve legacy discovery for v0.1; selected tool directories take precedence.
  const legacy = await legacyPaths([path.join(os.homedir(), '.dotnet', 'tools'),
    process.env.RUNNER_TEMP && path.join(process.env.RUNNER_TEMP, 'pwsh'),
    path.join(root, 'dotnet'), path.join(os.homedir(), '_work', '_tool', 'gh'),
    ...(process.platform === 'linux' ? ['/usr/local/bin', '/usr/bin'] : [])]);
  const pwsh = await installTool('pwsh', { root, version: input('powershell-tag'), token: input('token') });
  const gh = await installTool('gh', { root, version: input('gh-version'), token: input('token') });
  const selected = buildToolPath([path.dirname(pwsh), path.dirname(gh)], legacy, process.env.PATH);
  const additions = selected.additions;
  process.env.PATH = selected.value;
  console.log('Tool PATH: ' + additions.length + ' additions; ' + selected.omitted + ' optional directories omitted.');
  if (selected.omitted) console.log('::warning::Legacy tool discovery exceeded the safe PATH budget; optional directories were omitted.');
  if (process.env.GITHUB_PATH) await fs.appendFile(process.env.GITHUB_PATH, [...additions].reverse().join(os.EOL) + os.EOL);
  if (process.env.GITHUB_ENV) await fs.appendFile(process.env.GITHUB_ENV, 'AMITH_TOOL_CACHE=' + root + os.EOL);
  if (process.env.GITHUB_OUTPUT) await fs.appendFile(process.env.GITHUB_OUTPUT, 'cache-root=' + root + os.EOL);
  console.log(run('pwsh', ['--version']));
  console.log(run('gh', ['--version']));
}
module.exports = { cacheRoot, versionTag, assetName, ready, installCached, legacyPaths, buildToolPath };
if (require.main === module) main().catch(error => { console.error(error.message); process.exitCode = 1; });
