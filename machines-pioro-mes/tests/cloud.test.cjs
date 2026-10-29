'use strict';
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
const config = { url: 'https://machines-pioro.supabase.co', key: 'sb_publishable_abcdefghijklmno', workspaceId: 'ef99212a-cc28-4ec7-8fa0-5a1d91115641' };
const response = (status, data) => ({ ok: status >= 200 && status < 300, status, text: async () => JSON.stringify(data) });
function fixture() {
  const htmlPath = path.join(__dirname, '..', 'index.html');
  let source;
  if (fs.existsSync(htmlPath)) {
    const html = fs.readFileSync(htmlPath, 'utf8');
    const match = html.match(/<script\b[^>]*\bid=["']cloud-client["'][^>]*>([\s\S]*?)<\/script>/i);
    if (!match) throw new Error('Missing inline script#cloud-client in index.html');
    source = match[1];
  } else source = fs.readFileSync(path.join(__dirname, '..', '..', '..', 'work', 'cloud.js'), 'utf8');
  const memory = new Map();
  const context = vm.createContext({ URL, TextEncoder, AbortController, setTimeout, clearTimeout, atob, module: { exports: {} },
    sessionStorage: { getItem: key => memory.get(key) || null, setItem: (key, value) => memory.set(key, String(value)), removeItem: key => memory.delete(key) },
    fetch: async () => { throw new Error('Unexpected network call'); }
  });
  new vm.Script(source, { filename: 'cloud-client.js' }).runInContext(context);
  const { MESCloud } = context.module.exports;
  return { context, memory, MESCloud, cloud: new MESCloud(config) };
}
function session(cloud) { cloud._remember({ access_token: 'access', refresh_token: 'refresh', expires_in: 3600, user: { id: 'operator' } }); }

test('cloud configuration accepts public credentials only', () => {
  const { MESCloud } = fixture();
  assert.throws(() => new MESCloud({ ...config, key: 'sb_secret_abcdefghijklmno' }));
  const role = Buffer.from(JSON.stringify({ role: 'service_role' })).toString('base64url');
  assert.throws(() => new MESCloud({ ...config, key: 'a.' + role + '.b' }));
  assert.throws(() => new MESCloud({ ...config, url: 'http://machines-pioro.supabase.co' }));
  assert.throws(() => new MESCloud({ ...config, url: 'https://attacker.example' }));
  assert.throws(() => new MESCloud({ ...config, workspaceId: 'invalid' }));
});

test('cloud read without a session does not call the network', async () => {
  const { cloud, context } = fixture(); let called = false;
  context.fetch = async () => { called = true; throw new Error('Unexpected network call'); };
  assert.equal(await cloud.getUser(), null);
  await assert.rejects(() => cloud.pull(), error => error.code === 'AUTH');
  assert.equal(called, false);
});

test('auth and CAS requests have correct workspace, version and headers', async () => {
  const { cloud, context, memory } = fixture(); const calls = [];
  context.fetch = async (url, options) => {
    calls.push({ url, options, body: options.body && JSON.parse(options.body) });
    if (url.includes('/auth/v1/token')) return response(200, { access_token: 'access', refresh_token: 'refresh', expires_in: 3600, user: { id: 'operator' } });
    return response(200, { state: { schemaVersion: 1 }, version: 8, role: 'operator' });
  };
  assert.equal((await cloud.signIn(' operator@example.com ', 'secret')).id, 'operator');
  assert.equal(calls[0].body.email, 'operator@example.com');
  assert.equal(calls[0].options.credentials, 'omit');
  assert.equal(calls[0].options.headers.apikey, config.key);
  assert.equal((await cloud.pull()).version, 8);
  assert.equal(calls[1].body.p_workspace_id, config.workspaceId);
  assert.equal(calls[1].options.headers.Authorization, 'Bearer access');
  const state = { schemaVersion: 1 };
  await cloud.push(state, 8);
  assert.deepEqual(calls[2].body, { p_workspace_id: config.workspaceId, p_expected_version: 8, p_state: state });
  const saved = JSON.parse(memory.get(cloud.storageKey));
  assert.equal(saved.access_token, 'access');
  assert.equal(JSON.stringify(saved).includes('secret'), false);
});

test('conflicts never change local snapshot; invalid version and oversize fail before network', async () => {
  const { cloud, context } = fixture(); session(cloud); let calls = 0;
  context.fetch = async () => { calls++; return response(409, { code: 'PT409' }); };
  const state = { schemaVersion: 1, revision: 4 }; const before = JSON.stringify(state);
  await assert.rejects(() => cloud.push(state, 2), error => error.code === 'CONFLICT' && error.status === 409);
  assert.equal(JSON.stringify(state), before);
  await assert.rejects(() => cloud.push(state, -1), error => error.code === 'VERSION');
  await assert.rejects(() => cloud.push({ data: 'x'.repeat(2097153) }, 2), error => error.code === 'TOO_LARGE');
  assert.equal(calls, 1);
});

test('expiring access token is refreshed before reading', async () => {
  const { cloud, context } = fixture(); session(cloud); cloud.session.expires_at = 1; const paths = [];
  context.fetch = async (url, options) => {
    paths.push(url);
    if (url.includes('grant_type=refresh_token')) return response(200, { access_token: 'new-access', refresh_token: 'new-refresh', expires_in: 3600 });
    assert.equal(options.headers.Authorization, 'Bearer new-access');
    return response(200, { state: null, version: 0, role: 'operator' });
  };
  assert.equal((await cloud.pull()).version, 0);
  assert.equal(paths.length, 2);
  assert.ok(paths[0].includes('refresh_token'));
});

test('failed remote logout still removes the local session', async () => {
  const { cloud, context, memory } = fixture(); session(cloud);
  context.fetch = async () => { throw new Error('Offline'); };
  await assert.rejects(() => cloud.signOut(), error => error.code === 'NETWORK');
  assert.equal(cloud.session, null);
  assert.equal(memory.has(cloud.storageKey), false);
});
