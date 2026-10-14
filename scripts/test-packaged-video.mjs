import { spawn } from 'node:child_process';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';
import assert from 'node:assert/strict';
import { fileURLToPath } from 'node:url';
import { createVideoFixture } from '../backend/tests/video-fixture.js';
const root=path.dirname(path.dirname(fileURLToPath(import.meta.url)));
const resources=process.argv[2]||path.join(root,'release/Fetch.app/Contents/Resources');
const bin=path.join(resources,'Runtime/bin');
const temp=await mkdtemp(path.join(os.tmpdir(),'fetch-packaged-video-'));
const fixture=await createVideoFixture();
const token='fixture-native-session-'+ 'a'.repeat(48);
const ready=path.join(temp,'ready.json');
let service;
try{
  service=spawn(path.join(bin,'node'),[path.join(resources,'backend/server/native.js')],{env:{...process.env,PATH:bin+':/usr/bin:/bin',FETCH_NATIVE_TOKEN:token,FETCH_DATA_DIR:path.join(temp,'state'),FETCH_DOWNLOAD_DIR:path.join(temp,'files'),FETCH_READY_FILE:ready,FETCH_PARENT_PID:String(process.pid),ARIA2_BIN:path.join(bin,'aria2c'),YTDLP_BIN:path.join(bin,'yt-dlp')},stdio:['ignore','ignore','pipe']});
  let port;
  for(let i=0;i<250;i++){try{port=JSON.parse(await readFile(ready,'utf8')).port;break;}catch{}if(service.exitCode!==null)throw new Error('Packaged service exited');await new Promise(r=>setTimeout(r,100));}
  assert.ok(port,'Service did not start');
  const base='http://127.0.0.1:'+port;
  const auth={Authorization:'Bearer '+token};
  let response=await fetch(base+'/api/state',{headers:auth});let state=await response.json();
  const headers={...auth,'Content-Type':'application/json','X-Fetch-Key':state.key};
  response=await fetch(base+'/api/videos/analyze',{method:'POST',headers,body:JSON.stringify({source:fixture.base+'/page'})});
  assert.equal(response.status,200);assert.ok((await response.json()).formatCount>0);
  response=await fetch(base+'/api/videos/analyze',{method:'POST',headers,body:'null'});assert.equal(response.status,400);
  response=await fetch(base+'/api/videos/analyze',{method:'POST',headers:{'Content-Type':'application/json'},body:'{}'});assert.equal(response.status,401);
  response=await fetch(base+'/api/videos/analyze',{method:'POST',headers:{...headers,'X-Fetch-Key':'invalid'},body:'{}'});assert.equal(response.status,403);
  console.log('PASS: packaged video analysis, invalid payload, native authorization and CSRF');
  for(const format of ['original','mp4','webm','mkv','mov']){
    response=await fetch(base+'/api/downloads',{method:'POST',headers,body:JSON.stringify({type:'video',source:fixture.base+'/opaque',mode:'video',format,resolution:'best'})});
    assert.equal(response.status,201);const {id}=await response.json();
    let job;
    const deadline=Date.now()+45000;
    while(Date.now()<deadline){state=await(await fetch(base+'/api/state',{headers:auth})).json();job=state.jobs.find(j=>j.id===id);if(['completed','error'].includes(job.status))break;await new Promise(r=>setTimeout(r,100));}
    assert.equal(job.status,'completed',job.error||'Timed out');
    const file=job.files[0].path;assert.equal(path.extname(file),'.'+(format==='original'?'mp4':format));
    const probe=spawn(path.join(bin,'ffprobe'),['-v','error','-show_entries','stream=codec_type','-of','json',file],{stdio:['ignore','pipe','pipe']});
    let output='';probe.stdout.on('data',data=>output+=data);assert.equal(await new Promise(resolve=>probe.on('close',resolve)),0);
    assert.ok(JSON.parse(output).streams.some(s=>s.codec_type==='video'));assert.ok(JSON.parse(output).streams.some(s=>s.codec_type==='audio'));
    console.log('PASS: packaged extensionless video -> '+format);
  }
}finally{
  if(service && service.exitCode===null){service.kill('SIGTERM');await new Promise(resolve=>{service.once('close',resolve);setTimeout(()=>{if(service.exitCode===null)service.kill('SIGKILL');},8000).unref();});}
  await fixture.close();await rm(temp,{recursive:true,force:true});
}
