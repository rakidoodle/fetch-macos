import { mkdtemp, rm } from 'node:fs/promises';
import { spawnSync } from 'node:child_process';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import assert from 'node:assert/strict';
import { DownloadManager } from '../backend/server/manager.js';
const root = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
const bin = path.join(root, 'release/Fetch.app/Contents/Resources/Runtime/bin');
process.env.PATH = `${bin}:/usr/bin:/bin`;
const dir = await mkdtemp(path.join(os.tmpdir(), 'fetch-native-live-'));
const manager = await new DownloadManager({ dataDir: path.join(dir, 'state'), downloadDir: path.join(dir, 'downloads'), aria2: path.join(bin, 'aria2c'), ytdlp: path.join(bin, 'yt-dlp'), pollMs: 100 }).init();
const delay = ms => new Promise(r => setTimeout(r, ms));
async function until(fn, timeout = 240000) { const end = Date.now() + timeout; while (Date.now() < end) { if (fn()) return; await delay(100); } throw new Error('Live transfer timed out'); }
async function complete(job) {
  await until(() => ['completed', 'error'].includes(job.status));
  assert.equal(job.status, 'completed', job.error);
  const probe = spawnSync(path.join(bin, 'ffprobe'), ['-v', 'quiet', '-show_streams', '-of', 'json', job.files[0].path], { encoding: 'utf8' });
  assert.equal(probe.status, 0, probe.stderr); return JSON.parse(probe.stdout);
}
try {
  const source = 'https://www.youtube.com/watch?v=YE7VzlLtp-4';
  const video = await manager.run(() => manager.add({ type: 'youtube', source, mode: 'video', resolution: '360', format: 'mp4' }));
  await until(() => video.completed > 0 || video.status === 'error');
  assert.notEqual(video.status, 'error', video.error);
  assert.equal(video.status, 'downloading', 'Transfer finished before pause could be verified');
  await manager.run(() => manager.action(video.id, 'pause'));
  const paused = video.completed; await delay(600); assert.equal(video.status, 'paused'); assert.equal(video.speed, 0); assert.equal(video.completed, paused);
  await manager.run(() => manager.action(video.id, 'resume'));
  console.log('PASS: real YouTube bundled-engine pause/resume');
  const media = await complete(video);
  assert.ok(media.streams.some(s => s.codec_type === 'video' && s.height <= 360)); assert.ok(media.streams.some(s => s.codec_type === 'audio'));
  console.log(`PASS: real YouTube MP4 video and audio, resolution cap, ${video.total} bytes`);
  const audio = await manager.run(() => manager.add({ type: 'youtube', source, mode: 'audio', resolution: 'best', format: 'mp3' }));
  const mp3 = await complete(audio);
  assert.ok(mp3.streams.some(s => s.codec_name === 'mp3')); assert.ok(!mp3.streams.some(s => s.codec_type === 'video'));
  console.log(`PASS: real YouTube MP3 extraction and conversion, ${audio.total} bytes`);
  for (const format of ['m4a', 'flac', 'wav', 'opus']) {
    const target = path.join(dir, 'sample.' + format);
    const conversion = spawnSync(path.join(bin, 'ffmpeg'), ['-v', 'error', '-f', 'lavfi', '-i', 'sine=frequency=440:duration=1', target], { encoding: 'utf8' });
    assert.equal(conversion.status, 0, conversion.stderr);
    const probe = spawnSync(path.join(bin, 'ffprobe'), ['-v', 'quiet', '-show_streams', '-of', 'json', target], { encoding: 'utf8' });
    assert.equal(probe.status, 0); assert.ok(JSON.parse(probe.stdout).streams.some(s => s.codec_type === 'audio'));
  }
  console.log('PASS: bundled FFmpeg M4A, FLAC, WAV, Opus encoders and file outputs');
} finally { await manager.close(); await rm(dir, { recursive: true, force: true }); }
