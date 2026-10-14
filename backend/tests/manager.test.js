import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import os from 'node:os';
import http from 'node:http';
import path from 'node:path';
import { DownloadManager, validateSource, validateSettings, pieceMap } from '../server/manager.js';
import { createApp } from '../server/app.js';
import { createFixture } from './fixture.js';

let dir, manager, fixture, server, base, key;
const wait = ms => new Promise(r => setTimeout(r, ms));
async function until(predicate, timeout = 25000) { const end = Date.now() + timeout; while (Date.now() < end) { if (await predicate()) return; await wait(70); } throw new Error('Timed out waiting for condition.'); }
async function complete(job) { await until(() => ['completed', 'error'].includes(job.status)); assert.equal(job.status, 'completed', job.error); const file = await readFile(job.files[0].path); assert.deepEqual(file, fixture.data); return file; }
const add = data => manager.run(() => manager.add(data));
const action = (j, verb) => manager.run(() => manager.action(j.id, verb));

before(async () => { dir = await mkdtemp(path.join(os.tmpdir(), 'fetch-test-')); fixture = await createFixture(); manager = await new DownloadManager({ dataDir: path.join(dir, 'data'), downloadDir: path.join(dir, 'downloads'), pollMs: 80 }).init(); const app = createApp(manager); server = app.listen(0, '127.0.0.1'); await new Promise(r => server.once('listening', r)); base = `http://127.0.0.1:${server.address().port}`; key = (await (await fetch(`${base}/api/state`)).json()).key; });
after(async () => { await new Promise(r => { server.closeAllConnections(); server.close(r); }); await manager.close(); await fixture.close(); await rm(dir, { recursive: true, force: true }); });

test('Reject malformed sources, credential links, fake YouTube hosts, invalid magnets, and settings', () => {
  for (const source of ['', 'garbage', 'file:///etc/passwd', 'ftp://example.com/file', 'https://user:pass@example.com/file']) assert.throws(() => validateSource({ type: 'web', source }));
  assert.throws(() => validateSource({ type: 'youtube', source: 'https://youtube.com.evil.test/watch?v=x' }));
  assert.throws(() => validateSource({ type: 'torrent', source: 'magnet:?xt=urn:btih:abc' }));
  assert.throws(() => validateSource({ type: 'web', source: 'https://example.com', quality: 'invalid' }));
  assert.throws(() => validateSource({ type: 'torrent', torrent: 'bm90IHRvcnJlbnQ=' }));
  assert.throws(() => validateSettings({ connections: 17, maxActive: 1, speedLimit: 0 }));
  assert.throws(() => validateSettings({ connections: 8, maxActive: 1, speedLimit: -1 }));
  assert.deepEqual(pieceMap('a0', 4), [1, 0, 1, 0]);
});
test('API blocks cross-origin writes, missing CSRF keys, and DNS rebinding hosts', async () => {
  const payload = { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ type: 'web', source: `${fixture.base}/tiny` }) };
  assert.equal((await fetch(`${base}/api/downloads`, payload)).status, 403);
  assert.equal((await fetch(`${base}/api/downloads`, { ...payload, headers: { ...payload.headers, 'X-Fetch-Key': key, Origin: 'https://evil.test' } })).status, 403);
  const rebinding = await new Promise((resolve, reject) => { const req = http.get(`${base}/api/state`, { headers: { Host: 'evil.test' } }, response => { response.resume(); resolve(response.statusCode); }); req.on('error', reject); });
  assert.equal(rebinding, 403);
  assert.equal((await fetch(`${base}/api/downloads`, { ...payload, headers: { ...payload.headers, 'X-Fetch-Key': key }, body: 'invalid' })).status, 400);
  assert.equal((await fetch(`${base}/api/missing`)).status, 404);
});
test('Real segmented web download uses concurrent ranges and preserves every byte', async () => {
  fixture.stats.maxConcurrent = 0; fixture.stats.requests = [];
  const job = await add({ type: 'web', source: `${fixture.base}/file.bin` }); await complete(job);
  assert.ok(fixture.stats.requests.filter(r => r.range).length >= 2, 'Expected multiple range requests.');
  assert.ok(fixture.stats.maxConcurrent >= 2, 'Expected concurrent connections.');
  assert.ok(job.segments.every(p => p === 1));
  const response = await fetch(`${base}/api/downloads/${job.id}/files/0`); assert.equal(response.status, 200); assert.deepEqual(Buffer.from(await response.arrayBuffer()), fixture.data);
  assert.equal((await fetch(`${base}/api/downloads/${job.id}/files/garbage`)).status, 404);
});
test('Servers without ranges fall back to a full valid download', async () => { await complete(await add({ type: 'web', source: `${fixture.base}/no-range` })); });
test('Redirects and tiny files complete correctly', async () => {
  await complete(await add({ type: 'web', source: `${fixture.base}/redirect` }));
  const job = await add({ type: 'web', source: `${fixture.base}/tiny` }); await until(() => ['completed', 'error'].includes(job.status)); assert.equal(job.status, 'completed', job.error); assert.deepEqual(await readFile(job.files[0].path), fixture.data.subarray(0, 1024));
});
test('Pause and resume preserve byte integrity', async () => {
  const job = await add({ type: 'web', source: `${fixture.base}/file.bin` }); await until(() => job.completed > 0 && job.completed < job.total);
  await action(job, 'pause'); assert.equal(job.status, 'paused'); const progress = job.completed; await wait(250); assert.equal(job.completed, progress); assert.equal(job.speed, 0);
  await action(job, 'resume'); await complete(job);
});
test('Queue obeys concurrency and a paused job releases its slot', async () => {
  await manager.run(() => manager.updateSettings({ connections: 1, maxActive: 1, speedLimit: 0 }));
  const first = await add({ type: 'web', source: `${fixture.base}/file.bin` }); const second = await add({ type: 'web', source: `${fixture.base}/file.bin` });
  assert.equal(second.status, 'queued'); await action(first, 'pause'); assert.equal(second.status, 'downloading');
  await action(first, 'resume'); assert.equal(first.status, 'queued');
  await complete(second); await complete(first); await manager.run(() => manager.updateSettings({ connections: 8, maxActive: 3, speedLimit: 0 }));
});
test('Cancel, retry, and remove history retain safe files and state', async () => {
  const job = await add({ type: 'web', source: `${fixture.base}/file.bin` }); await until(() => job.completed > 0);
  await action(job, 'cancel'); assert.equal(job.status, 'canceled'); assert.equal(job.speed, 0);
  await action(job, 'resume'); await complete(job); const target = job.files[0].path;
  await action(job, 'remove'); assert.ok(!manager.jobs.some(j => j.id === job.id)); assert.deepEqual(await readFile(target), fixture.data);
});
test('HTTP failure has actionable error and retry succeeds', async () => {
  const job = await add({ type: 'web', source: `${fixture.base}/flaky` }); await until(() => job.status === 'error'); assert.ok(job.error); fixture.stats.fail = false;
  await action(job, 'resume'); await complete(job);
});
test('Truncated responses never become completed files', async () => { const job = await add({ type: 'web', source: `${fixture.base}/truncate` }); await until(() => job.status === 'error'); assert.ok(job.error); assert.equal((await fetch(`${base}/api/downloads/${job.id}/files/0`)).status, 404); });
test('Torrent upload transfers actual peer data with verified hashes', async () => {
  const before = fixture.stats.peerBytes; const job = await add({ type: 'torrent', torrent: fixture.torrent, name: 'fixture.torrent' });
  await complete(job); assert.ok(fixture.stats.peerBytes > before, 'Expected a real BitTorrent peer transfer.');
});
test('Magnet fetches peer metadata then downloads matching bytes', async () => {
  const before = fixture.stats.metadataRequests; const job = await add({ type: 'torrent', source: fixture.magnet });
  await complete(job); assert.ok(fixture.stats.metadataRequests > before, 'Expected real metadata extension requests.');
});
test('Remote torrent URL resolves into actual torrent payload', async () => { await complete(await add({ type: 'torrent', source: `${fixture.base}/fixture.torrent` })); });
test('Completed-file endpoint blocks escaping download directory', async () => {
  const job = manager.jobs.find(j => j.status === 'completed'); const previous = job.files; job.files = [{ name: 'state.json', path: path.join(dir, 'data', 'state.json') }];
  assert.equal((await fetch(`${base}/api/downloads/${job.id}/files/0`)).status, 403); job.files = previous;
});
test('Settings and history survive restart; interrupted files resume correctly', async () => {
  const job = await add({ type: 'web', source: `${fixture.base}/no-range` }); await until(() => job.completed > 0);
  const id = job.id; await manager.close();
  const recovered = await new DownloadManager({ dataDir: path.join(dir, 'data'), downloadDir: path.join(dir, 'downloads'), pollMs: 80 }).init();
  try { const restored = recovered.jobs.find(j => j.id === id); assert.equal(restored.status, 'paused'); assert.equal(recovered.settings.connections, 8); await recovered.run(() => recovered.action(id, 'resume')); await complete(restored); }
  finally { await recovered.close(); }
});
