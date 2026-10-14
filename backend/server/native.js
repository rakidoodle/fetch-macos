import express from 'express';
import { timingSafeEqual } from 'node:crypto';
import { writeFile, unlink } from 'node:fs/promises';
import { DownloadManager } from './manager.js';
import { createApp } from './app.js';

const token = process.env.FETCH_NATIVE_TOKEN;
if (!token || token.length < 32) throw new Error('Native session token is required.');
const manager = await new DownloadManager({
  dataDir: process.env.FETCH_DATA_DIR,
  downloadDir: process.env.FETCH_DOWNLOAD_DIR,
  aria2: process.env.ARIA2_BIN || 'aria2c',
  ytdlp: process.env.YTDLP_BIN || 'yt-dlp',
}).init();
const app = express();
app.use((req, res, next) => {
  const given = Buffer.from((req.headers.authorization || '').replace(/^Bearer /, ''));
  const expected = Buffer.from(token);
  if (given.length !== expected.length || !timingSafeEqual(given, expected)) return res.status(401).json({ error: 'Native session authorization is required.' });
  next();
});
app.use(createApp(manager));
const server = app.listen(0, '127.0.0.1');
let stopping = false;
const parent = Number(process.env.FETCH_PARENT_PID || 0);
const parentTimer = parent ? setInterval(() => {
  try { process.kill(parent, 0); } catch (error) { if (error.code === 'ESRCH') void stop(); }
}, 2000) : null;
async function stop() {
  if (stopping) return;
  stopping = true;
  clearInterval(parentTimer);
  server.closeAllConnections();
  server.close();
  try { await manager.close(); } finally {
    if (process.env.FETCH_READY_FILE) await unlink(process.env.FETCH_READY_FILE).catch(() => {});
    process.exit(0);
  }
}
server.on('listening', async () => {
  const info = { port: server.address().port, pid: process.pid };
  if (process.env.FETCH_READY_FILE) await writeFile(process.env.FETCH_READY_FILE, JSON.stringify(info), { mode: 0o600 });
  console.log(`Fetch native service ready on port ${info.port}`);
});
server.on('error', async error => { console.error(error.message); await manager.close(); process.exit(1); });
process.on('SIGTERM', stop);
process.on('SIGINT', stop);
