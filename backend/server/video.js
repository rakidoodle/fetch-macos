import { spawn } from 'node:child_process';

export function mediaEnvironment() {
  return Object.fromEntries(['PATH','HOME','TMPDIR','LANG','LC_ALL','SSL_CERT_FILE','SSL_CERT_DIR'].filter(key=>process.env[key]!==undefined).map(key=>[key,process.env[key]]));
}
export function mediaURL(value) {
  if (typeof value !== 'string' || value.length > 8192) throw new Error('Enter a valid video URL.');
  let url;
  try { url = new URL(value); } catch { throw new Error('Enter a valid video URL.'); }
  if (!['http:', 'https:'].includes(url.protocol) || url.username || url.password) throw new Error('Use an HTTP or HTTPS URL without embedded credentials.');
  return url;
}
export function mediaError(text) {
  if (/DRM|protected content/i.test(text)) return 'This video is DRM-protected and cannot be downloaded by Fetch.';
  if (/Unsupported URL|No video formats|no video found/i.test(text)) return 'No downloadable video found. Open the player, press Play, then choose a detected stream.';
  if (/403|401|sign in|login|Forbidden/i.test(text)) return 'The site requires a fresh player session. Open the player and try again.';
  if (/timed out|timeout/i.test(text)) return 'Video detection timed out. Try again or open the player.';
  if (/Requested format.*not available/i.test(text)) return 'Selected quality is unavailable. Choose Best available or another format.';
  return 'Video request failed. Try again or open the player.';
}
export function videoContext(value, page) {
  if (!value) return undefined;
  if (typeof value !== 'object' || Array.isArray(value)) throw new Error('Invalid player session.');
  const target = mediaURL(value.url), reference = mediaURL(value.referer || page);
  if (typeof value.userAgent !== 'string' || value.userAgent.length > 1024 || /[\r\n]/.test(value.userAgent)) throw new Error('Invalid player browser details.');
  if (!Array.isArray(value.cookies) || value.cookies.length > 100) throw new Error('Invalid player cookies.');
  const cookies = value.cookies.map(c => {
    if (!c || typeof c !== 'object') throw new Error('Invalid player cookie.');
    const { name, value, domain, path = '/', secure = false, expires = 0 } = c;
    if (![name,value,domain,path].every(s => typeof s === 'string' && s.length <= 8192 && !/[\t\r\n]/.test(s)) || !name || !domain || !path.startsWith('/') || !Number.isFinite(expires) || typeof secure !== 'boolean') throw new Error('Invalid player cookie.');
    const host = domain.replace(/^\./,'').toLowerCase();
    if (target.hostname !== host && !target.hostname.endsWith('.'+host)) throw new Error('Cookie does not belong to the detected video host.');
    return { name,value,domain,path,secure,expires:Math.max(0,Math.floor(expires)) };
  });
  if (JSON.stringify(cookies).length > 65536) throw new Error('Player session is too large.');
  return { url:target.href, referer:reference.href, userAgent:value.userAgent, cookies };
}
export function cookieText(cookies) {
  const rows = cookies.map(cookie => {
    // Python's cookie jar treats a single-label localhost as localhost.local.
    // This maps only that host; normal website cookie scopes remain unchanged.
    const domain = cookie.domain.replace(/^\./, '') === 'localhost' ? 'localhost.local' : cookie.domain;
    const subdomains = domain === cookie.domain && domain.startsWith('.') ? 'TRUE' : 'FALSE';
    return [domain, subdomains, cookie.path, cookie.secure ? 'TRUE' : 'FALSE', cookie.expires, cookie.name, cookie.value].join('\t');
  });
  return '# Netscape HTTP Cookie File\n' + rows.join('\n') + '\n';
}

export async function analyzeVideo(manager, source) {
  const url = mediaURL(source);
  if (manager.closing) throw new Error('Download service is stopping.');
  if (manager.probes.size >= 2) throw new Error('Video detection is busy. Try again shortly.');
  const child = spawn(manager.ytdlp,['--ignore-config','--no-cache-dir','--skip-download','--dump-single-json','--no-playlist','--socket-timeout','10','--retries','0','--extractor-retries','0','--js-runtimes','node','--',url.href],{env:mediaEnvironment(),stdio:['ignore','pipe','pipe'],detached:process.platform!=='win32'});
  manager.probes.add(child);
  try {
    const info = await new Promise((resolve,reject) => {
      let output='', errors='', settled=false;
      const finish=(error,value) => { if(settled)return;settled=true;clearTimeout(timer);error?reject(error):resolve(value); };
      const stop=() => { try { process.kill(-child.pid,'SIGKILL'); } catch { child.kill('SIGKILL'); } };
      const timer=setTimeout(()=>{stop();finish(new Error('Video detection timed out. Try again or open the player.'));},30000);
      child.stdout.on('data',data=>{ output+=data; if(output.length>4_000_000){stop();finish(new Error('Video page returned too much metadata. Open its player instead.'));} });
      child.stderr.on('data',data=>{errors=(errors+data).slice(-8000);});
      child.on('error',()=>finish(new Error('Video engine could not start. Restart Fetch.')));
      child.on('close',code=>{
        if(code!==0)return finish(new Error(mediaError(errors)));
        try { finish(null,JSON.parse(output)); } catch { finish(new Error('Video engine returned invalid metadata.')); }
      });
    });
    const formats=(info.formats||[]).filter(f=>!f.has_drm && f.vcodec!=='none');
    if(info.has_drm || (!formats.length && !info.url))throw new Error('No unprotected downloadable video found. Open its player instead.');
    return { title:String(info.title||'Web video').slice(0,300), extractor:String(info.extractor||'generic').slice(0,80), resolutions:[...new Set(formats.map(f=>f.height).filter(n=>Number.isFinite(n)&&n>0))].sort((a,b)=>b-a), formatCount:formats.length||1 };
  } finally { manager.probes.delete(child); }
}
