import http from 'node:http';
import net from 'node:net';
import { createHash } from 'node:crypto';

export function bencode(value) {
  if (Buffer.isBuffer(value)) return Buffer.concat([Buffer.from(`${value.length}:`), value]);
  if (typeof value === 'string') return bencode(Buffer.from(value));
  if (typeof value === 'number') return Buffer.from(`i${value}e`);
  if (Array.isArray(value)) return Buffer.concat([Buffer.from('l'), ...value.map(bencode), Buffer.from('e')]);
  return Buffer.concat([Buffer.from('d'), ...Object.keys(value).sort().flatMap(key => [bencode(key), bencode(value[key])]), Buffer.from('e')]);
}
function bdecode(buffer, offset = 0) {
  let at = offset;
  function read() {
    const ch = String.fromCharCode(buffer[at++]);
    if (ch === 'i') { const end = buffer.indexOf(101, at); const n = Number(buffer.toString('ascii', at, end)); at = end + 1; return n; }
    if (ch === 'd' || ch === 'l') { const result = ch === 'd' ? {} : []; while (buffer[at] !== 101) { if (ch === 'd') { const key = read().toString(); result[key] = read(); } else result.push(read()); } at++; return result; }
    at--; const colon = buffer.indexOf(58, at); const len = Number(buffer.toString('ascii', at, colon)); at = colon + 1; const data = buffer.subarray(at, at + len); at += len; return data;
  }
  return { value: read(), end: at };
}
export async function createFixture({ length = 12 * 1024 * 1024, delay = 8, port = 0 } = {}) {
  const data = Buffer.alloc(length); for (let i = 0; i < data.length; i++) data[i] = (i * 17 + Math.floor(i / 256)) % 256;
  const pieceLength = 256 * 1024; const pieces = [];
  for (let i = 0; i < data.length; i += pieceLength) pieces.push(createHash('sha1').update(data.subarray(i, i + pieceLength)).digest());
  const info = { name: 'fixture.bin', length: data.length, 'piece length': pieceLength, pieces: Buffer.concat(pieces) };
  const metadata = bencode(info); const infoHash = createHash('sha1').update(metadata).digest();
  const stats = { requests: [], concurrent: 0, maxConcurrent: 0, peerBytes: 0, metadataRequests: 0, fail: true };
  const peerSockets = new Set();
  const peer = net.createServer(socket => {
    peerSockets.add(socket); socket.on('error', () => {}); socket.on('close', () => peerSockets.delete(socket));
    let buffer = Buffer.alloc(0); let handshaken = false; let metadataId = 1;
    function send(id, payload = Buffer.alloc(0)) { const frame = Buffer.alloc(5); frame.writeUInt32BE(payload.length + 1); frame[4] = id; socket.write(Buffer.concat([frame, payload])); }
    socket.on('data', chunk => {
      buffer = Buffer.concat([buffer, chunk]);
      if (!handshaken) {
        if (buffer.length < 68) return;
        if (!buffer.subarray(28, 48).equals(infoHash)) return socket.destroy();
        const response = Buffer.concat([Buffer.from([19]), Buffer.from('BitTorrent protocol'), Buffer.from([0, 0, 0, 0, 0, 16, 0, 0]), infoHash, Buffer.from('-FT0001-123456789012')]);
        socket.write(response); handshaken = true; buffer = buffer.subarray(68);
        const bitfield = Buffer.alloc(Math.ceil(pieces.length / 8), 255); if (pieces.length % 8) bitfield[bitfield.length - 1] = 255 << (8 - pieces.length % 8) & 255;
        send(5, bitfield); send(1); send(20, Buffer.concat([Buffer.from([0]), bencode({ m: { ut_metadata: 1 }, metadata_size: metadata.length })]));
      }
      while (buffer.length >= 4) {
        const len = buffer.readUInt32BE(); if (buffer.length < 4 + len) return;
        const message = buffer.subarray(4, 4 + len); buffer = buffer.subarray(4 + len); if (!len) continue;
        if (message[0] === 6 && message.length === 13) {
          const index = message.readUInt32BE(1); const begin = message.readUInt32BE(5); const size = message.readUInt32BE(9);
          if (size > 128 * 1024) return socket.destroy();
          const start = index * pieceLength + begin; const bytes = data.subarray(start, start + size); stats.peerBytes += bytes.length;
          const header = Buffer.alloc(8); header.writeUInt32BE(index); header.writeUInt32BE(begin, 4); send(7, Buffer.concat([header, bytes]));
        }
        if (message[0] === 20 && message[1] === 0) { try { metadataId = bdecode(message.subarray(2)).value.m?.ut_metadata || 1; } catch {} }
        if (message[0] === 20 && message[1] === 1) {
          try { const request = bdecode(message.subarray(2)).value; if (request.msg_type === 0) { stats.metadataRequests++; send(20, Buffer.concat([Buffer.from([metadataId]), bencode({ msg_type: 1, piece: request.piece, total_size: metadata.length }), metadata.subarray(request.piece * 16384, (request.piece + 1) * 16384)])); } } catch { /* Ignore invalid extension frames. */ }
        }
      }
    });
  });
  await new Promise(resolve => peer.listen(0, '127.0.0.1', resolve)); const peerPort = peer.address().port;
  const server = http.createServer((req, res) => {
    if (req.url.startsWith('/announce')) { const compact = Buffer.from([127, 0, 0, 1, peerPort >> 8, peerPort & 255]); res.end(bencode({ interval: 1, complete: 1, incomplete: 0, peers: compact })); return; }
    if (req.url.startsWith('/fixture.torrent')) { res.end(bencode({ announce: `${base}/announce`, info })); return; }
    if (req.url.startsWith('/webseed.torrent')) { res.end(bencode({ info, 'url-list': `${base}/file.bin` })); return; }
    if (req.url === '/redirect') { res.writeHead(302, { Location: '/file.bin' }); res.end(); return; }
    if (req.url === '/missing' || req.url === '/flaky' && stats.fail) { res.writeHead(404); res.end('Not found'); return; }
    if (!['/file.bin', '/no-range', '/flaky', '/tiny', '/truncate'].includes(req.url)) { res.writeHead(404); res.end(); return; }
    let start = 0; let end = req.url === '/tiny' ? 1023 : data.length - 1;
    const match = req.headers.range?.match(/^bytes=(\d+)-(\d*)$/);
    const ranged = match && req.url !== '/no-range';
    if (ranged) { start = Number(match[1]); if (match[2]) end = Math.min(end, Number(match[2])); if (start > end) { res.writeHead(416, { 'Content-Range': `bytes */${data.length}` }); res.end(); return; } }
    stats.requests.push({ url: req.url, start, end, range: req.headers.range });
    res.writeHead(ranged ? 206 : 200, { 'Content-Type': 'application/octet-stream', 'Content-Length': end - start + 1, ...(req.url !== '/no-range' ? { 'Accept-Ranges': 'bytes' } : {}), ...(ranged ? { 'Content-Range': `bytes ${start}-${end}/${data.length}` } : {}), ...(req.url !== '/fixture.bin' ? { 'Content-Disposition': 'attachment; filename="fixture.bin"' } : {}) });
    if (req.method === 'HEAD') { res.end(); return; }
    stats.concurrent++; stats.maxConcurrent = Math.max(stats.maxConcurrent, stats.concurrent);
    let at = start; const timer = setInterval(() => { if (res.writableEnded || res.destroyed) { clearInterval(timer); return; } if (req.url === '/truncate' && at > start + 128 * 1024) return res.destroy(); const next = Math.min(end + 1, at + 64 * 1024); res.write(data.subarray(at, next)); at = next; if (at > end) { clearInterval(timer); res.end(); } }, delay);
    res.on('close', () => { clearInterval(timer); stats.concurrent--; });
  });
  let base = ''; await new Promise(resolve => server.listen(port, '127.0.0.1', resolve)); base = `http://127.0.0.1:${server.address().port}`;
  return { data, stats, base, torrent: bencode({ announce: `${base}/announce`, info }).toString('base64'), magnet: `magnet:?xt=urn:btih:${infoHash.toString('hex')}&dn=fixture.bin&tr=${encodeURIComponent(`${base}/announce`)}`, close: async () => { for (const socket of peerSockets) socket.destroy(); await Promise.all([new Promise(r => { server.closeAllConnections(); server.close(r); }), new Promise(r => peer.close(r))]); } };
}
