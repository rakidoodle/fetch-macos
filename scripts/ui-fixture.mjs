import { createFixture } from '../backend/tests/fixture.js';
import { mkdtemp, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
const fixture = await createFixture({ length: 24 * 1024 * 1024, delay: 16, port: Number(process.env.FETCH_FIXTURE_PORT || 0) });
const dir = await mkdtemp(path.join(os.tmpdir(), 'fetch-ui-'));
await writeFile(path.join(dir, 'fixture.torrent'), Buffer.from(fixture.torrent, 'base64'));
await writeFile(path.join(dir, 'session.json'), JSON.stringify({ base: fixture.base, magnet: fixture.magnet, directory: dir, torrentFile: path.join(dir, 'fixture.torrent') }));
console.log(JSON.stringify({ base: fixture.base, magnet: fixture.magnet, directory: dir }));
let closed = false;
async function stop() { if (closed) return; closed = true; await fixture.close(); process.exit(0); }
process.on('SIGTERM', stop); process.on('SIGINT', stop);
