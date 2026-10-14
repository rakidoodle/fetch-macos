import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, readFile, rm, stat } from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';
import { spawnSync } from 'node:child_process';
import { DownloadManager, validateSource, youtubeFormatArgs } from '../server/manager.js';
import { videoContext, cookieText, mediaError } from '../server/video.js';
import { createVideoFixture } from './video-fixture.js';

test('Web video accepts general sites, containers, and keeps source credentials invalid',()=>{
  for(const format of ['original','mp4','webm','mkv','mov']) {
    const source=validateSource({type:'video',source:'https://example.com/player',format});
    assert.equal(source.format,format); assert.ok(youtubeFormatArgs(source).includes('-f'));
  }
  assert.throws(()=>validateSource({type:'video',source:'https://user:password@example.com/player'}));
  assert.throws(()=>validateSource({type:'video',source:'file:///private/video'}));
  assert.throws(()=>validateSource({type:'video',source:'https://example.com/player',format:'exe'}));
  assert.throws(()=>validateSource({type:'youtube',source:'https://example.com/player'}));
});
test('Player cookies are host scoped, bounded, and errors do not reveal signed links',()=>{
  const valid={url:'https://media.example.com/video.mp4?signature=test-only',userAgent:'Test Browser',cookies:[{name:'session',value:'test-only-cookie',domain:'.example.com',path:'/',secure:true,expires:0}]};
  const context=videoContext(valid,'https://example.com/page');
  assert.ok(cookieText(context.cookies).includes('.example.com\tTRUE'));
  assert.throws(()=>videoContext({...valid,cookies:[{...valid.cookies[0],domain:'.other.com'}]},'https://example.com/page'));
  assert.throws(()=>videoContext({...valid,userAgent:'Browser\r\nHeader: injected'},'https://example.com/page'));
  assert.throws(()=>videoContext({...valid,cookies:[{...valid.cookies[0],value:'a\nb'}]},'https://example.com/page'));
  const error=mediaError('ERROR: Failed https://media.example.com/video?secret=do-not-expose');
  assert.ok(!error.includes('do-not-expose'));assert.ok(!error.includes('media.example.com'));
  assert.match(mediaError('DRM protected'),/DRM/);
});
test('Real generic pages, all video containers, HLS/DASH and private player sessions',{timeout:180000},async()=>{
  const fixture=await createVideoFixture();
  const temp=await mkdtemp(path.join(os.tmpdir(),'fetch-video-test-'));
  let manager;
  async function wait(job){
    const deadline=Date.now()+45000;
    while(Date.now()<deadline){if(job.status==='error')throw new Error(job.error);if(job.status==='completed')return;await new Promise(r=>setTimeout(r,100));}
    throw new Error('Timed out: '+job.status);
  }
  function inspect(file){const p=spawnSync('ffprobe',['-v','error','-show_streams','-show_format','-of','json',file],{encoding:'utf8'});assert.equal(p.status,0);return JSON.parse(p.stdout);}
  try{
    manager=await new DownloadManager({dataDir:path.join(temp,'state'),downloadDir:path.join(temp,'files'),pollMs:100}).init();
    const info=await manager.analyzeVideo(fixture.base+'/page');assert.ok(info.formatCount>0);
    assert.ok(!JSON.stringify(info).includes('http://'));
    await assert.rejects(manager.analyzeVideo(fixture.base+'/empty'),/No downloadable|No unprotected/);
    for(const format of ['original','mp4','webm','mkv','mov']){
      const job=await manager.add({type:'video',source:fixture.base+'/page',format});await wait(job);
      const file=job.files[0];assert.equal(path.extname(file.path),'.'+(format==='original'?'mp4':format));
      const media=inspect(file.path);assert.ok(media.streams.some(s=>s.codec_type==='video'));assert.ok(media.streams.some(s=>s.codec_type==='audio'));
    }
    for(const source of ['/stream.m3u8','/stream.mpd']){
      const job=await manager.add({type:'video',source:fixture.base+source,format:'mkv'});await wait(job);assert.ok(inspect(job.files[0].path).streams.some(s=>s.codec_type==='video'));
    }
    const context={url:fixture.base+'/protected.mp4?key=test-only-link',userAgent:'Fixture Browser',cookies:[{name:'fixtureSession',value:'test-only-cookie',domain:'127.0.0.1',path:'/',secure:false,expires:0}]};
    const job=await manager.add({type:'video',source:fixture.base+'/browser',format:'mp4',context});await wait(job);
    const localContext={...context,url:context.url.replace('127.0.0.1','localhost'),cookies:[{...context.cookies[0],domain:'localhost'}]};
    const localhostJob=await manager.add({type:'video',source:fixture.base.replace('127.0.0.1','localhost')+'/frame',format:'mp4',context:localContext});await wait(localhostJob);
    assert.ok(inspect(localhostJob.files[0].path).streams.some(s=>s.codec_type==='video'));
    await manager.persist();const history=await readFile(path.join(temp,'state/state.json'),'utf8');
    assert.ok(!history.includes('test-only-cookie'));assert.ok(!history.includes('test-only-link'));assert.ok(!JSON.stringify(manager.snapshot()).includes('test-only-cookie'));
    assert.equal((await stat(path.join(temp,'state/state.json'))).mode & 0o777,0o600);
    assert.equal(manager.sessionDirs.size,0);
    await manager.close();manager=await new DownloadManager({dataDir:path.join(temp,'state'),downloadDir:path.join(temp,'files'),pollMs:100}).init();
    const restored=manager.jobs.find(j=>j.id===job.id);assert.ok(restored.browserDetected);restored.status='paused';
    await manager.action(restored.id,'resume');assert.equal(restored.status,'error');assert.match(restored.error,/session expired/);
    console.log('PASS: generic video, five containers, real HLS/DASH, cookie/referrer session, private history and session recovery');
  }finally{await manager?.close();await fixture.close();await rm(temp,{recursive:true,force:true});}
});
