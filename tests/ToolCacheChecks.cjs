'use strict';
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const tools = require('../setup-tools/index.cjs');

test('tool release selectors and platform assets', () => {
  assert.equal(tools.versionTag(''), 'latest');
  assert.equal(tools.versionTag('latest'), 'latest');
  assert.equal(tools.versionTag('7.5.4'), 'v7.5.4');
  assert.throws(() => tools.versionTag('../../elsewhere'));
  assert.equal(tools.assetName('pwsh', 'v7.5.4', 'linux', 'arm64'), 'powershell-7.5.4-linux-arm64.tar.gz');
  assert.equal(tools.assetName('gh', 'v2.80.0', 'win32', 'x64'), 'gh_2.80.0_windows_amd64.zip');
  assert.throws(() => tools.assetName('pwsh', 'v7.5.4', 'darwin', 'x64'));
  assert.equal(tools.cacheRoot('', {}, 'linux'), path.resolve('/opt/hostedtoolcache'));
  assert.equal(tools.cacheRoot('/custom', { RUNNER_TOOL_CACHE: '/runner' }), path.resolve('/custom'));
});
test('cache reuses completed installs and repairs corrupt or failed installs', async t => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), 'amith-cache-'));
  t.after(() => fs.rm(root, { recursive: true, force: true }));
  const directory = path.join(root, 'tools with spaces', '1.2.3', 'os-arch');
  let installs = 0;
  const install = async attempt => { installs++; await fs.writeFile(path.join(attempt, 'tool'), 'executable'); };
  const validate = file => assert.ok(file.endsWith('tool'));
  await tools.installCached(directory, 'tool', install, validate);
  await tools.installCached(directory, 'tool', install, validate);
  assert.equal(installs, 1);
  await fs.writeFile(path.join(directory, 'tool'), 'corrupt');
  await tools.installCached(directory, 'tool', install, validate);
  assert.equal(installs, 2);
  await fs.rm(directory, { recursive: true });
  await assert.rejects(tools.installCached(directory, 'tool', async attempt => {
    await fs.writeFile(path.join(attempt, 'tool'), 'partial');
    throw new Error('interrupted');
  }, validate), /interrupted/);
  assert.equal(await tools.ready(directory, 'tool'), false);
  await tools.installCached(directory, 'tool', install, validate);
  assert.equal(installs, 3);
  assert.deepEqual((await fs.readdir(path.dirname(directory))).sort(), ['os-arch']);
});
test('concurrent installers share one completed cache entry', async t => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), 'amith-race-'));
  t.after(() => fs.rm(root, { recursive: true, force: true }));
  let installs = 0;
  const install = async attempt => { installs++; await fs.writeFile(path.join(attempt, 'tool'), 'executable'); };
  await Promise.all([1, 2].map(() => tools.installCached(path.join(root, 'version'), 'tool', install, () => {})));
  assert.equal(installs, 1);
});
test('legacy discovery handles missing directories and paths with spaces', async t => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), 'amith-path-'));
  t.after(() => fs.rm(root, { recursive: true, force: true }));
  const directory = path.join(root, 'tools with spaces');
  await fs.mkdir(directory);
  await fs.writeFile(path.join(directory, 'command'), 'test');
  assert.deepEqual(await tools.legacyPaths([path.join(root, 'missing'), root]), [directory]);
});
