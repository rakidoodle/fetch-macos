import http from 'node:http';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';

export async function createVideoFixture() {
  const dir=await mkdtemp(path.join(os.tmpdir(),'fetch-video-fixture-'));
  function ffmpeg(args) {
    const result=spawnSync('ffmpeg',['-hide_banner','-loglevel','error','-y',...args],{cwd:dir,encoding:'utf8'});
    if(result.status!==0)throw new Error('Video fixture encoding failed: '+result.stderr);
  }
  ffmpeg(['-f','lavfi','-i','testsrc=size=320x180:rate=12','-f','lavfi','-i','sine=frequency=440:sample_rate=44100','-t','3','-c:v','libx264','-pix_fmt','yuv420p','-g','12','-c:a','aac','-movflags','+faststart','source.mp4']);
  ffmpeg(['-i','source.mp4','-c','copy','-hls_time','1','-hls_list_size','0','stream.m3u8']);
  ffmpeg(['-i','source.mp4','-c','copy','-f','dash','stream.mpd']);
  const requests=[];
  let base='';
  const server=http.createServer(async(req,res)=>{
    try {
      const url=new URL(req.url,base);
      requests.push({path:url.pathname,cookie:req.headers.cookie,referer:req.headers.referer});
      res.setHeader('Access-Control-Allow-Origin','*');
      if(url.pathname==='/empty'){res.setHeader('Content-Type','text/html');return res.end('<html><title>No media</title><p>No video</p></html>');}
      if(url.pathname==='/opaque'){res.setHeader('Content-Type','text/html');return res.end('<html><title>Opaque video test</title><video controls src="/media?key=fixture"></video></html>');}
      if(url.pathname==='/page'){res.setHeader('Content-Type','text/html');return res.end('<html><title>Fixture Video</title><video controls src="/source.mp4"></video></html>');}
      if(url.pathname==='/browser'){res.setHeader('Content-Type','text/html');return res.end(`<html><title>Embedded Player Test</title><iframe width="640" height="320" src="${base.replace('127.0.0.1','localhost')}/frame"></iframe></html>`);}
      if(url.pathname==='/frame'){res.setHeader('Content-Type','text/html');res.setHeader('Set-Cookie','fixtureSession=test-only-cookie; Path=/; HttpOnly; SameSite=Lax');return res.end('<html><video controls width="500" src="/protected.mp4?key=test-only-link"></video><button onclick="fetch(\'/stream.m3u8\');fetch(\'/stream.mpd\')">Detect streams</button></html>');}
      if(url.pathname==='/protected.mp4'){
        if(!req.headers.cookie?.includes('fixtureSession=test-only-cookie') || !req.headers.referer || url.searchParams.get('key')!=='test-only-link'){res.statusCode=403;return res.end('Fresh session required');}
      }
      const name=['/protected.mp4','/media'].includes(url.pathname)?'source.mp4':url.pathname.slice(1);
      if(!/^[a-zA-Z0-9_.-]+$/.test(name)){res.statusCode=404;return res.end();}
      let bytes;
      try { bytes=await readFile(path.join(dir,name)); } catch {res.statusCode=404;return res.end();}
      const ext=path.extname(name);
      res.setHeader('Content-Type',ext==='.mp4'?'video/mp4':ext==='.m3u8'?'application/vnd.apple.mpegurl':ext==='.mpd'?'application/dash+xml':ext==='.ts'?'video/mp2t':'application/octet-stream');
      res.setHeader('Accept-Ranges','bytes');
      const match=req.headers.range?.match(/^bytes=(\d+)-(\d*)$/);
      if(match){const start=Number(match[1]),end=match[2]?Math.min(Number(match[2]),bytes.length-1):bytes.length-1;res.statusCode=206;res.setHeader('Content-Range',`bytes ${start}-${end}/${bytes.length}`);bytes=bytes.subarray(start,end+1);}
      res.setHeader('Content-Length',bytes.length);res.end(bytes);
    }catch {res.statusCode=500;res.end();}
  });
  await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
  base=`http://127.0.0.1:${server.address().port}`;
  return {base,dir,requests,close:async()=>{server.closeAllConnections();await new Promise(resolve=>server.close(resolve));await rm(dir,{recursive:true,force:true});}};
}
