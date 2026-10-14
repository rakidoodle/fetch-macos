import { createFixture } from '../backend/tests/fixture.js';
import { mkdtemp, writeFile, readFile, rm } from 'node:fs/promises';
import { spawn } from 'node:child_process';
import path from 'node:path';
import os from 'node:os';
import http from 'node:http';
import { fileURLToPath } from 'node:url';
import assert from 'node:assert/strict';

const root = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
const resources = process.argv[2] || path.join(root, 'release/Fetch.app/Contents/Resources');
const fixture = await createFixture({ length: 12 * 1024 * 1024, delay: 8 });
const temp = await mkdtemp(path.join(os.tmpdir(), 'fetch-packaged-test-'));
let service;
try {
  const torrent = path.join(temp, 'fixture.torrent');
  await writeFile(torrent, Buffer.from(fixture.torrent, 'base64'));
  const probe = spawn(path.join(root, '.build/release/FetchProbe'), [resources, fixture.base, torrent, fixture.magnet], { stdio: 'inherit' });
  const code = await new Promise((resolve, reject) => { probe.on('error', reject); probe.on('exit', resolve); });
  assert.equal(code, 0, 'Native Swift client integration failed');
  const token = 'test-native-token-' + 'a'.repeat(48);
  const ready = path.join(temp, 'ready.json');
  const bin = path.join(resources, 'Runtime/bin');
  service = spawn(path.join(bin, 'node'), [path.join(resources, 'backend/server/native.js')], {
    env: { ...process.env, PATH: `${bin}:/usr/bin:/bin`, FETCH_NATIVE_TOKEN: token, FETCH_DATA_DIR: path.join(temp, 'state'), FETCH_DOWNLOAD_DIR: path.join(temp, 'files'), FETCH_READY_FILE: ready, ARIA2_BIN: path.join(bin, 'aria2c'), YTDLP_BIN: path.join(bin, 'yt-dlp'), FETCH_PARENT_PID: String(process.pid) },
    stdio: ['ignore', 'ignore', 'pipe']
  });
  let errors = ''; service.stderr.on('data', chunk => { errors += chunk; });
  let port;
  for (let i = 0; i < 250; i++) {
    try { port = JSON.parse(await readFile(ready, 'utf8')).port; break; } catch {}
    if (service.exitCode !== null) throw new Error(errors);
    await new Promise(r => setTimeout(r, 100));
  }
  assert.ok(port, 'Packaged service startup timed out');
  const base = `http://127.0.0.1:${port}`;
  assert.equal((await fetch(base + '/api/state')).status, 401);
  assert.equal((await fetch(base + '/api/state', { headers: { Authorization: 'Bearer wrong' } })).status, 401);
  const headers = { Authorization: `Bearer ${token}` };
  const state = await (await fetch(base + '/api/state', { headers })).json();
  assert.equal(state.engines.aria2, true); assert.equal(state.engines.youtube, true); assert.equal(state.engines.ffmpeg, true);
  const payload = { method: 'POST', headers: { ...headers, 'Content-Type': 'application/json' }, body: JSON.stringify({ type: 'web', source: fixture.base + '/tiny' }) };
  assert.equal((await fetch(base + '/api/downloads', payload)).status, 403);
  assert.equal((await fetch(base + '/api/downloads', { ...payload, headers: { ...payload.headers, 'X-Fetch-Key': state.key, Origin: 'https://evil.test' } })).status, 403);
  assert.equal((await fetch(base + '/api/downloads', { ...payload, headers: { ...payload.headers, 'X-Fetch-Key': state.key }, body: 'invalid' })).status, 400);
  const blockedHost = await new Promise((resolve, reject) => { const req = http.get(base + '/api/state', { headers: { ...headers, Host: 'evil.test' } }, res => { res.resume(); resolve(res.statusCode); }); req.on('error', reject); });
  assert.equal(blockedHost, 403);
  assert.equal((await fetch(base + '/api/health', { headers })).status, 200);
  assert.equal((await fetch(base + '/api/not-found', { headers })).status, 404);
  console.log('PASS: packaged API session authentication, CSRF, origin, host, malformed JSON, health, missing endpoints');
} finally {
  if (service && service.exitCode === null) { service.kill('SIGTERM'); await new Promise(resolve => service.once('exit', resolve)); }
  await fixture.close();
  await rm(temp, { recursive: true, force: true });
}
