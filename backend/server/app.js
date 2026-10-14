import express from 'express';
import { randomBytes } from 'node:crypto';
import path from 'node:path';
import { realpath } from 'node:fs/promises';

export function createApp(manager, { allowedPort } = {}) {
  const app = express(); const key = randomBytes(32).toString('hex');
  app.disable('x-powered-by');
  app.use((req, res, next) => {
    const host = req.headers.host || '';
    if (!/^(localhost|127\.0\.0\.1)(:\d+)?$/.test(host) || (allowedPort && host.includes(':') && host.split(':')[1] !== String(allowedPort))) return res.status(403).json({ error: 'Local access only.' });
    const origin = req.headers.origin;
    if (origin && origin !== `http://${host}`) return res.status(403).json({ error: 'Cross-origin requests are blocked.' });
    res.setHeader('X-Content-Type-Options', 'nosniff'); res.setHeader('Referrer-Policy', 'no-referrer');
    if (req.path.startsWith('/api')) res.setHeader('Cache-Control', 'no-store');
    if (!['GET', 'HEAD'].includes(req.method) && req.headers['x-fetch-key'] !== key) return res.status(403).json({ error: 'Refresh the app before trying again.' });
    next();
  });
  app.use(express.json({ limit: '8mb' }));
  app.get('/api/state', (req, res) => res.json({ ...manager.snapshot(), key }));
  app.get('/api/health', (req, res) => res.json({ ok: true, engines: manager.engines }));
  app.post('/api/downloads', async (req, res) => {
    const job = await manager.run(() => manager.add(req.body)); res.status(201).json({ id: job.id });
  });
  app.post('/api/downloads/:id/:action', async (req, res) => { await manager.run(() => manager.action(req.params.id, req.params.action)); res.json({ ok: true }); });
  app.put('/api/settings', async (req, res) => { await manager.run(() => manager.updateSettings(req.body)); res.json({ ok: true }); });
  app.get('/api/downloads/:id/files/:index', async (req, res, next) => {
    try {
      const job = manager.jobs.find(j => j.id === req.params.id);
      if (!job || job.status !== 'completed') return res.status(404).json({ error: 'Completed file not found.' });
      if (!/^\d+$/.test(req.params.index)) return res.status(404).json({ error: 'File not found.' });
      const file = job.files[Number(req.params.index)]; if (!file) return res.status(404).json({ error: 'File not found.' });
      const root = await realpath(path.join(manager.downloadDir, job.id)); const target = await realpath(file.path);
      if (!target.startsWith(root + path.sep)) return res.status(403).json({ error: 'File is outside this download folder.' });
      res.download(target, file.name, { dotfiles: 'allow' }, error => { if (error && !res.headersSent) next(error); });
    } catch (e) { if (e.code === 'ENOENT') return res.status(404).json({ error: 'File was moved or deleted from disk.' }); next(e); }
  });
  app.use('/api', (req, res) => res.status(404).json({ error: 'API endpoint not found.' }));
  app.use((error, req, res, next) => { if (res.headersSent) return next(error); res.status(error.status || 400).json({ error: error.type === 'entity.parse.failed' ? 'Invalid JSON request.' : error.message || 'Request failed.' }); });
  return app;
}
