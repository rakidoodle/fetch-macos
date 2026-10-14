import { spawn, spawnSync, execFile } from 'node:child_process';
import { randomBytes, randomUUID } from 'node:crypto';
import { mkdir, readFile, writeFile, rename, stat, mkdtemp, rm } from 'node:fs/promises';
import path from 'node:path';
import net from 'node:net';
import os from 'node:os';
import { promisify } from 'node:util';
const runFile = promisify(execFile);
import { analyzeVideo, videoContext, cookieText, mediaError, mediaEnvironment } from './video.js';
const isMedia = type => ['youtube', 'video'].includes(type);
import { EventEmitter } from 'node:events';

export const ACTIVE = ['downloading', 'processing'];
export function validateSource(input) {
  if (!input || typeof input !== 'object' || Array.isArray(input)) throw new Error('Enter a download link.');
  const type = input.type;
  if (!['web', 'youtube', 'video', 'torrent'].includes(type)) throw new Error('Choose a supported download type.');
  const source = String(input.source || '').trim();
  if (source.length > 8192) throw new Error('Download link is too long.');
  if (type === 'torrent' && input.torrent) {
    if (typeof input.torrent !== 'string' || input.torrent.length > 7_000_000 || !/^[A-Za-z0-9+/]+={0,2}$/.test(input.torrent)) throw new Error('Invalid torrent file.');
    const bytes = Buffer.from(input.torrent, 'base64');
    if (bytes[0] !== 100 || bytes.at(-1) !== 101) throw new Error('Invalid torrent file.');
    return { type, source: String(input.name || 'Uploaded torrent').slice(0, 200), torrent: input.torrent, quality: 'best' };
  }
  let url;
  try { url = new URL(source); } catch { throw new Error('Enter a valid URL.'); }
  if (type === 'torrent') {
    if (url.protocol === 'magnet:') {
      if (!/^urn:btih:([a-f\d]{40}|[a-z2-7]{32})$/i.test(url.searchParams.get('xt') || '')) throw new Error('Magnet link needs a valid BitTorrent info hash.');
    } else if (!['http:', 'https:'].includes(url.protocol) || !url.pathname.toLowerCase().endsWith('.torrent')) throw new Error('Use a magnet link, .torrent URL, or upload a torrent file.');
  } else if (!['http:', 'https:'].includes(url.protocol)) throw new Error('Only HTTP and HTTPS links are supported.');
  if (url.username || url.password) throw new Error('Links with embedded credentials are not supported.');
  if (type === 'youtube' && !['youtube.com', 'www.youtube.com', 'm.youtube.com', 'music.youtube.com', 'youtu.be'].includes(url.hostname.toLowerCase())) throw new Error('Enter a YouTube video URL.');
  const quality = input.quality || 'best';
  if (!['best', '2160', '1440', '1080', '720', '480', '360', '240', '144', 'audio'].includes(quality)) throw new Error('Choose a supported video quality.');
  return { type, source: url.href, quality, ...(isMedia(type) ? youtubeOptions(input) : {}) };
}
export function youtubeOptions(input) {
  const mode = input.mode ?? (input.quality === 'audio' ? 'audio' : 'video');
  if (!['video', 'audio'].includes(mode)) throw new Error('Choose video or audio.');
  const resolution = input.resolution ?? (input.quality === 'audio' ? 'best' : input.quality || 'best');
  if (!['best', '2160', '1440', '1080', '720', '480', '360', '240', '144'].includes(resolution)) throw new Error('Choose a supported resolution.');
  const format = input.format ?? (mode === 'audio' ? 'mp3' : 'mp4');
  const formats = mode === 'audio' ? ['mp3', 'm4a', 'flac', 'wav', 'opus'] : ['original', 'mp4', 'webm', 'mkv', 'mov'];
  if (!formats.includes(format)) throw new Error(`Choose a supported ${mode} format.`);
  return { mode, resolution, format, quality: mode === 'audio' ? 'audio' : resolution };
}
export function youtubeFormatArgs(input) {
  const { mode, resolution, format } = youtubeOptions(input);
  if (mode === 'audio') return ['-f', 'bestaudio/best', '--extract-audio', '--audio-format', format];
  const cap = resolution === 'best' ? '' : `[height<=${resolution}]`;
  const selection = `bv*${cap}+ba/b${cap}`;
  if (format === 'original') return ['-f', selection];
  if (format === 'webm') return ['-f', `bv*${cap}[ext=webm]+ba[ext=webm]/b${cap}[ext=webm]/${selection}`, '--merge-output-format', 'mkv', '--recode-video', 'webm'];
  if (format === 'mp4') return ['-f', `bv*${cap}[ext=mp4]+ba[ext=m4a]/b${cap}[ext=mp4]/${selection}`, '--merge-output-format', 'mp4', '--recode-video', 'mp4'];
  if (format === 'mov') return ['-f', selection, '--merge-output-format', 'mkv', '--recode-video', 'mov'];
  return ['-f', selection, '--merge-output-format', 'mkv', '--remux-video', 'mkv'];
}
export function validateSettings(input) {
  if (!input || typeof input !== 'object') throw new Error('Invalid settings.');
  const { connections, maxActive, speedLimit } = input;
  if (!Number.isInteger(connections) || connections < 1 || connections > 16) throw new Error('Connections must be between 1 and 16.');
  if (!Number.isInteger(maxActive) || maxActive < 1 || maxActive > 8) throw new Error('Active downloads must be between 1 and 8.');
  if (!Number.isInteger(speedLimit) || speedLimit < 0 || speedLimit > 1_000_000) throw new Error('Speed limit must be 0–1,000,000 KiB/s.');
  return { connections, maxActive, speedLimit };
}
async function freePort() {
  const s = net.createServer();
  await new Promise((resolve, reject) => { s.once('error', reject); s.listen(0, '127.0.0.1', resolve); });
  const port = s.address().port;
  await new Promise(resolve => s.close(resolve));
  return port;
}
export class DownloadManager extends EventEmitter {
  constructor({ dataDir, downloadDir, aria2 = 'aria2c', ytdlp = 'yt-dlp', pollMs = 500 }) {
    super(); this.dataDir = dataDir; this.downloadDir = downloadDir; this.aria2 = aria2; this.ytdlp = ytdlp;
    this.pollMs = pollMs; this.jobs = []; this.events = []; this.settings = { connections: 8, maxActive: 3, speedLimit: 0 };
    this.processes = new Map(); this.contexts = new Map(); this.probes = new Set(); this.sessionDirs = new Set(); this.lock = Promise.resolve(); this.closing = false;
  }
  run(fn) { const promise = this.lock.then(fn); this.lock = promise.catch(() => {}); return promise; }
  async init() {
    await mkdir(this.dataDir, { recursive: true }); await mkdir(this.downloadDir, { recursive: true });
    try {
      const state = JSON.parse(await readFile(path.join(this.dataDir, 'state.json'), 'utf8'));
      this.settings = validateSettings(state.settings); this.jobs = state.jobs; this.events = state.events || [];
      for (const job of this.jobs) { delete job.gid; job.speed = 0; job.connections = 0; if (ACTIVE.includes(job.status) || job.status === 'queued') job.status = 'paused'; }
    } catch (error) { if (error.code !== 'ENOENT') throw new Error(`Cannot read saved downloads: ${error.message}`); }
    this.engines = { aria2: spawnSync(this.aria2, ['--version']).status === 0, youtube: spawnSync(this.ytdlp, ['--version']).status === 0, ffmpeg: spawnSync('ffmpeg', ['-version']).status === 0 };
    if (this.engines.aria2) {
      this.rpcPort = await freePort(); this.secret = randomBytes(24).toString('hex');
      this.daemon = spawn(this.aria2, ['--enable-rpc', '--rpc-listen-all=false', `--rpc-listen-port=${this.rpcPort}`, `--rpc-secret=${this.secret}`, '--rpc-allow-origin-all=false', '--enable-dht=true', `--dht-file-path=${path.join(this.dataDir, 'dht.dat')}`, `--dht-listen-port=${await freePort()}`, '--enable-dht6=false', '--bt-enable-lpd=false', '--seed-time=0', '--summary-interval=0', '--console-log-level=error', '--file-allocation=none', '--max-concurrent-downloads=64', `--max-overall-download-limit=${this.settings.speedLimit}K`, '--max-overall-upload-limit=1M', `--listen-port=${await freePort()}`], { stdio: ['ignore', 'ignore', 'pipe'] });
      let startupError = ''; this.daemon.stderr.on('data', b => { startupError = (startupError + b.toString()).slice(-2000); });
      this.daemon.on('error', e => { startupError = e.message; });
      let ready = false;
      for (let i = 0; i < 60; i++) { try { await this.rpc('getVersion'); ready = true; break; } catch { await new Promise(r => setTimeout(r, 50)); } }
      if (!ready) { this.daemon.kill(); throw new Error(`aria2 did not start. ${startupError}`); }
      this.daemon.on('exit', () => { if (!this.closing) { this.engines.aria2 = false; for (const j of this.jobs) if (!isMedia(j.type) && ACTIVE.includes(j.status)) { j.status = 'error'; j.error = 'Download engine stopped. Restart the app to recover.'; } this.changed(); } });
    }
    await this.persist(); this.timer = setInterval(() => this.run(() => this.tick()).catch(e => { this.lastError = e.message; }), this.pollMs);
    return this;
  }
  async rpc(method, ...params) {
    const response = await fetch(`http://127.0.0.1:${this.rpcPort}/jsonrpc`, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ jsonrpc: '2.0', id: randomUUID(), method: `aria2.${method}`, params: [`token:${this.secret}`, ...params] }), signal: AbortSignal.timeout(5000) });
    const result = await response.json(); if (result.error) throw new Error(result.error.message); return result.result;
  }
  async persist() {
    const target = path.join(this.dataDir, 'state.json');
    await writeFile(`${target}.tmp`, JSON.stringify({ settings: this.settings, jobs: this.jobs, events: this.events }), { mode: 0o600 }); await rename(`${target}.tmp`, target);
  }
  changed() { this.emit('change'); }
  event(job, verb) { this.events.unshift({ id: randomUUID(), jobId: job.id, name: job.name, verb, time: Date.now(), type: job.type }); this.events = this.events.slice(0, 60); }
  snapshot() { return { jobs: this.jobs.map(({ torrent, gid, ...job }) => job), events: this.events, settings: this.settings, engines: this.engines, downloadDir: this.downloadDir, error: this.lastError || null }; }
  async add(input) {
    const source = validateSource(input);
    const context = isMedia(source.type) ? videoContext(input.context, source.source) : undefined;
    if (isMedia(source.type) && !this.engines.youtube) throw new Error('yt-dlp is missing. Install it, then restart the app.');
    if (isMedia(source.type) && !this.engines.ffmpeg) throw new Error('FFmpeg is missing. Install it, then restart the app.');
    if (!isMedia(source.type) && !this.engines.aria2) throw new Error('aria2 is missing. Install it, then restart the app.');
    const job = { id: randomUUID(), ...source, name: source.type === 'torrent' ? 'Resolving torrent…' : isMedia(source.type) ? 'Fetching video details…' : decodeName(source.source), status: 'queued', created: Date.now(), total: 0, completed: 0, speed: 0, connections: 0, segments: [], files: [], error: null };
    await mkdir(path.join(this.downloadDir, job.id), { recursive: true });
    if (context) { this.contexts.set(job.id, context); job.browserDetected = true; }
    this.jobs.unshift(job); this.event(job, 'added'); await this.schedule(); await this.persist(); this.changed(); return job;
  }
  async schedule() {
    if (this.closing) return;
    let available = this.settings.maxActive - this.jobs.filter(j => ACTIVE.includes(j.status)).length;
    for (const job of [...this.jobs].reverse()) {
      if (available <= 0) break;
      if (job.status !== 'queued') continue;
      available--;
      try { await this.start(job); } catch (e) { job.status = 'error'; job.error = e.message; this.event(job, 'failed'); }
    }
  }
  async start(job) {
    job.error = null;
    if (isMedia(job.type)) {
      const paused = this.processes.get(job.id);
      if (paused) { signalProcess(paused, 'SIGCONT'); job.status = job.resumePhase === 'processing' ? 'processing' : 'downloading'; delete job.resumePhase; return; }
      return this.startYoutube(job);
    }
    if (job.gid) { await this.rpc('unpause', job.gid); job.status = 'downloading'; return; }
    const options = { dir: path.join(this.downloadDir, job.id), split: String(this.settings.connections), 'max-connection-per-server': String(this.settings.connections), 'min-split-size': '1M', 'continue': 'true', 'auto-file-renaming': 'false', 'allow-overwrite': 'false', 'max-tries': '3', 'retry-wait': '1', 'timeout': '30', 'connect-timeout': '15', 'seed-time': '0', 'bt-stop-timeout': '180', 'check-integrity': 'true' };
    job.gid = job.torrent ? await this.rpc('addTorrent', job.torrent, [], options) : await this.rpc('addUri', [job.source], options);
    job.status = 'downloading';
  }
  async analyzeVideo(source) { return analyzeVideo(this, source); }
  async startYoutube(job) {
    const context = this.contexts.get(job.id);
    if (job.browserDetected && !context) throw new Error('Player session expired. Add this page again with Open Player to refresh the stream.');
    let sessionDir;
    if (context) {
      sessionDir = await mkdtemp(path.join(os.tmpdir(), 'fetch-media-')); this.sessionDirs.add(sessionDir);
      await writeFile(path.join(sessionDir, 'cookies.txt'), cookieText(context.cookies), { mode: 0o600 });
    }
    const args = ['--ignore-config', '--no-cache-dir', '--no-simulate', '--no-playlist', '--no-colors', '--newline', '--progress', '--progress-delta', '0.3', '--continue', '--no-overwrites', '--restrict-filenames', '--socket-timeout', '30', '--retries', '3', '--js-runtimes', 'node', '--concurrent-fragments', String(this.settings.connections), '--paths', path.join(this.downloadDir, job.id), '--output', '%(title).150B [%(id)s].%(ext)s', '--print', 'before_dl:FETCH_META:%(title)j', '--print', 'after_move:FETCH_FILE:%(filepath)j', '--progress-template', 'download:FETCH_PROGRESS:%(progress)j', '--progress-template', 'postprocess:FETCH_PROCESS:%(progress)j'];
    if (this.settings.speedLimit) args.push('--limit-rate', `${this.settings.speedLimit}K`);
    args.push(...youtubeFormatArgs(job));
    if (context) args.push('--cookies', path.join(sessionDir, 'cookies.txt'), '--add-headers', `Referer:${context.referer}`, '--add-headers', `User-Agent:${context.userAgent}`);
    args.push('--', context?.url || job.source);
    const child = spawn(this.ytdlp, args, { env: mediaEnvironment(), stdio: ['ignore', 'pipe', 'pipe'], detached: process.platform !== 'win32' });
    this.processes.set(job.id, child); job.status = 'downloading'; let buffer = ''; let errors = ''; const streams = new Map();
    child.stdout.on('data', chunk => {
      if (this.processes.get(job.id) !== child || ['paused', 'queued', 'canceled'].includes(job.status)) return;
      buffer += chunk.toString(); const lines = buffer.split('\n'); buffer = lines.pop() || '';
      for (const line of lines) {
        try {
          if (/^\[(VideoConvertor|VideoRemuxer|Merger|ExtractAudio)\]/.test(line) && job.status === 'downloading') { job.status = 'processing'; job.speed = 0; }
          if (line.startsWith('FETCH_META:')) job.name = JSON.parse(line.slice(11));
          if (line.startsWith('FETCH_FILE:')) { const file = JSON.parse(line.slice(11)); job.files = [{ path: file, name: path.basename(file) }]; }
          if (line.startsWith('FETCH_PROCESS:') && job.status === 'downloading') { job.status = 'processing'; job.speed = 0; }
          if (line.startsWith('FETCH_PROGRESS:')) {
            const progress = JSON.parse(line.slice(15));
            streams.set(progress.filename || 'media', { total: Number(progress.total_bytes || progress.total_bytes_estimate || 0), completed: Number(progress.downloaded_bytes || 0) });
            job.total = [...streams.values()].reduce((sum, item) => sum + item.total, 0); job.completed = [...streams.values()].reduce((sum, item) => sum + item.completed, 0); job.speed = Number(progress.speed || 0); job.eta = Number(progress.eta || 0);
          }
        } catch { /* Ignore non-JSON diagnostic lines from the external engine. */ }
      }
      this.changed();
    });
    child.stderr.on('data', chunk => { errors = (errors + chunk.toString()).slice(-4000); });
    child.on('error', error => { errors = error.message; });
    child.on('close', code => this.run(async () => {
      if (sessionDir) { await rm(sessionDir, { recursive: true, force: true }); this.sessionDirs.delete(sessionDir); }
      if (this.processes.get(job.id) !== child) return;
      this.processes.delete(job.id); job.speed = 0;
      if (job.status === 'canceled' || this.closing) return;
      if (code === 0 && job.files.length) {
        try { await this.identifyOriginal(job); const info = await stat(job.files[0].path); job.total = info.size; job.completed = info.size; job.status = 'completed'; job.finished = Date.now(); this.contexts.delete(job.id); this.event(job, 'completed'); }
        catch { job.status = 'error'; job.error = 'Video output was not found. Retry this download.'; }
      } else { job.status = 'error'; job.error = mediaError(errors); this.event(job, 'failed'); }
      await this.schedule(); await this.persist(); this.changed();
    }).catch(e => { this.lastError = e.message; }));
  }
  async identifyOriginal(job) {
    if (job.format !== 'original' || !job.files[0] || !['', '.unknown_video', '.bin'].includes(path.extname(job.files[0].path))) return;
    const file = job.files[0].path;
    const { stdout } = await runFile('ffprobe', ['-v', 'error', '-show_entries', 'format=format_name:format_tags=major_brand:stream=codec_type', '-of', 'json', file], { env: mediaEnvironment(), timeout: 10000, maxBuffer: 512000 });
    const metadata = JSON.parse(stdout);
    const container = metadata.format?.format_name || '';
    let extension;
    if (container.includes('mp4')) extension = metadata.format.tags?.major_brand?.trim() === 'qt' ? 'mov' : 'mp4';
    else if (container.includes('matroska')) {
      const { open } = await import('node:fs/promises');
      const handle = await open(file, 'r');
      try { const header = Buffer.alloc(128); await handle.read(header, 0, 128, 0); extension = header.includes(Buffer.from('webm')) ? 'webm' : 'mkv'; } finally { await handle.close(); }
    } else extension = { avi:'avi', flv:'flv', mpegts:'ts', mpeg:'mpg', ogg:'ogv', asf:'wmv' }[container];
    if (!extension) throw new Error('Unknown video container.');
    const target = file.replace(/\.[^/.]+$/, '') + '.' + extension;
    await rename(file, target);
    job.files[0] = { ...job.files[0], path: target, name: path.basename(target) };
  }
  async tick() {
    let dirty = false;
    if (this.engines.aria2) for (const job of this.jobs) {
      if (!job.gid || !ACTIVE.includes(job.status)) continue;
      try {
        let result = await this.rpc('tellStatus', job.gid);
        if (result.followedBy?.length) { job.gid = result.followedBy[0]; result = await this.rpc('tellStatus', job.gid); }
        job.total = Number(result.totalLength); job.completed = Number(result.completedLength); job.speed = Number(result.downloadSpeed); job.connections = Number(result.connections); job.seeders = Number(result.numSeeders || 0);
        job.eta = job.speed ? Math.ceil((job.total - job.completed) / job.speed) : 0;
        job.files = (result.files || []).filter(f => f.path).map(f => ({ path: f.path, name: path.basename(f.path), size: Number(f.length) }));
        if (result.bittorrent?.info?.name) job.name = result.bittorrent.info.name; else if (job.files.length) job.name = job.files[0].name;
        job.segments = pieceMap(result.bitfield, Number(result.numPieces || 0));
        if (result.status === 'complete') { job.status = 'completed'; job.speed = 0; job.finished = Date.now(); this.event(job, 'completed'); await this.rpc('removeDownloadResult', job.gid).catch(() => {}); delete job.gid; dirty = true; }
        if (result.status === 'error') { job.status = 'error'; job.speed = 0; job.error = result.errorMessage || `Download failed (aria2 code ${result.errorCode}).`; delete job.gid; this.event(job, 'failed'); dirty = true; }
      } catch (e) { job.status = 'error'; job.speed = 0; job.error = e.message; delete job.gid; dirty = true; }
    }
    await this.schedule();
    if (dirty || Date.now() - (this.lastSave || 0) > 3000) { await this.persist(); this.lastSave = Date.now(); }
    this.changed();
  }
  async action(id, action) {
    const job = this.jobs.find(j => j.id === id); if (!job) throw new Error('Download not found.');
    if (action === 'pause' && (ACTIVE.includes(job.status) || job.status === 'queued')) {
      if (job.gid) await this.rpc('forcePause', job.gid);
      if (this.processes.has(id)) job.resumePhase = job.status;
      signalProcess(this.processes.get(id), 'SIGSTOP'); job.status = 'paused'; job.speed = 0; this.event(job, 'paused');
    } else if (action === 'resume' && ['paused', 'error', 'canceled'].includes(job.status)) { job.status = 'queued'; job.error = null; this.event(job, 'resumed'); }
    else if (action === 'cancel' && !['completed', 'canceled'].includes(job.status)) {
      if (job.gid) { await this.rpc('forceRemove', job.gid); delete job.gid; }
      const child = this.processes.get(id); if (child) { this.processes.delete(id); signalProcess(child, 'SIGCONT'); signalProcess(child, 'SIGTERM'); }
      job.status = 'canceled'; job.speed = 0; this.event(job, 'canceled');
    } else if (action === 'remove' && !ACTIVE.includes(job.status) && job.status !== 'queued') {
      if (job.gid) { await this.rpc('forceRemove', job.gid).catch(() => {}); delete job.gid; }
      const child = this.processes.get(id); if (child) { this.processes.delete(id); signalProcess(child, 'SIGCONT'); signalProcess(child, 'SIGTERM'); }
      this.jobs = this.jobs.filter(j => j.id !== id); this.contexts.delete(id);
    } else throw new Error('This action is unavailable for the current download state.');
    await this.schedule(); await this.persist(); this.changed();
  }
  async updateSettings(input) {
    const settings = validateSettings(input);
    if (this.engines.aria2) await this.rpc('changeGlobalOption', { 'max-overall-download-limit': `${settings.speedLimit}K` });
    this.settings = settings; await this.schedule(); await this.persist(); this.changed();
  }
  async close() {
    this.closing = true; clearInterval(this.timer);
    for (const child of this.probes) { signalProcess(child, 'SIGKILL'); }
    await this.lock;
    for (const [id, child] of this.processes) { this.processes.delete(id); signalProcess(child, 'SIGCONT'); signalProcess(child, 'SIGTERM'); }
    for (const job of this.jobs) if (ACTIVE.includes(job.status) || job.status === 'queued') { job.status = 'paused'; job.speed = 0; }
    if (this.daemon?.exitCode === null) {
      const ended = new Promise(resolve => this.daemon.once('exit', resolve));
      await this.rpc('forceShutdown').catch(() => this.daemon.kill());
      await Promise.race([ended, new Promise(resolve => setTimeout(() => { this.daemon.kill('SIGKILL'); resolve(); }, 2000))]);
    }
    for (const folder of this.sessionDirs) await rm(folder, { recursive: true, force: true });
    this.sessionDirs.clear(); this.contexts.clear();
    await this.persist();
  }
}
function decodeName(source) { try { return decodeURIComponent(new URL(source).pathname.split('/').pop()) || new URL(source).hostname; } catch { return 'Web file'; } }
export function pieceMap(hex = '', count = 0) {
  if (!count || !hex) return [];
  const bits = [...hex].flatMap(c => parseInt(c, 16).toString(2).padStart(4, '0').split('').map(Number)).slice(0, count);
  const groups = Math.min(32, count);
  return Array.from({ length: groups }, (_, i) => { const part = bits.slice(Math.floor(i * count / groups), Math.floor((i + 1) * count / groups)); return part.reduce((a, b) => a + b, 0) / part.length; });
}

function signalProcess(child, signal) {
  if (!child || child.exitCode !== null) return;
  try { if (process.platform !== 'win32') process.kill(-child.pid, signal); else child.kill(signal); } catch (e) { if (e.code !== 'ESRCH') throw e; }
}
