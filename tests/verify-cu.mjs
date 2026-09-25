import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import {fileURLToPath} from 'node:url';
import {spawn} from 'node:child_process';
import assert from 'node:assert/strict';
const root=path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const runtime=fs.mkdtempSync(path.join(os.tmpdir(),'dsh-cu-test-'));
fs.mkdirSync(runtime,{recursive:true});
const ps=process.env.LOCALAPPDATA+'\\Microsoft\\WindowsApps\\pwsh.exe';
const p=spawn(ps,['-NoProfile','-NonInteractive','-STA','-WindowStyle','Hidden','-ExecutionPolicy','Bypass','-File',root+'/mcp/cu-mcp.ps1','-CuPath',root+'/scripts/cu.ps1','-LogPath',runtime+'/server.log'],{windowsHide:true,stdio:['pipe','pipe','pipe'],env:{...process.env,DSH_CU_RUNTIME_DIR:runtime}});
let buf='',next=1,err=''; const pending=new Map(); const timings=[];
p.stdout.setEncoding('utf8');
p.stdout.on('data',d=>{buf+=d;for(let i;(i=buf.indexOf('\n'))>=0;){const line=buf.slice(0,i).trim();buf=buf.slice(i+1);if(!line)continue;let m;try{m=JSON.parse(line)}catch{console.error('NON-JSON STDOUT',line);continue;}const w=pending.get(m.id);if(w){clearTimeout(w.timer);pending.delete(m.id);w.resolve(m)}}});
p.stderr.on('data',d=>err+=d);
p.on('error',e=>{for(const w of pending.values())w.reject(e)});
p.on('exit',()=>{for(const w of pending.values()){clearTimeout(w.timer);w.reject(Error('server exited: '+err))}});
const request=(method,params)=>new Promise((resolve,reject)=>{const id=next++;const timer=setTimeout(()=>{pending.delete(id);reject(Error('timeout '+method+' '+err))},15000);pending.set(id,{resolve,reject,timer});p.stdin.write(JSON.stringify({jsonrpc:'2.0',id,method,params})+'\n')});
const act=async args=>{const t=Date.now();const r=await request('tools/call',{name:'cu',arguments:args});timings.push({action:args.action,ms:Date.now()-t,error:!!r.result?.isError});return r};
const ok=r=>{assert.ok(!r.error&&!r.result?.isError,JSON.stringify(r));return r.result};
const state=async()=>JSON.parse(ok(await act({action:'fxstatus',json:true})).content[0].text);
const delay=ms=>new Promise(r=>setTimeout(r,ms));
const alive=pid=>{try{process.kill(pid,0);return true}catch{return false}};
const gone=async(...ids)=>{const until=Date.now()+5000;while(ids.some(alive)&&Date.now()<until)await delay(100);for(const pid of ids)assert.equal(alive(pid),false,'helper must exit: '+pid);};
let passed=false;
try{
 const init=ok(await request('initialize',{protocolVersion:'2026-07-28',capabilities:{},clientInfo:{name:'regression',version:'1'}}));
 assert.equal(init.protocolVersion,'2025-06-18');
 p.stdin.write(JSON.stringify({jsonrpc:'2.0',method:'notifications/initialized'})+'\n');
 const schema=ok(await request('tools/list',{})).tools[0].inputSchema;
 assert.ok(schema.properties.action.enum.includes('stop'));
 assert.equal((await state()).active,false);
 assert.ok(!fs.existsSync(runtime+'/session.json'),'discovery/probes must not create UI');
 ok(await act({action:'start',text:'大肥鱼接管测试 / 中文正常'}));
 await delay(3000);
 const first=await state();assert.equal(first.on,true);assert.equal(first.pill,true);
 ok(await act({action:'start'}));
 const second=await state();assert.equal(second.pid,first.pid);assert.equal(second.chipPid,first.chipPid);
 ok(await act({action:'status',text:'正在检查截图：第 1/2 步',state:'busy'}));
 assert.ok(fs.readFileSync(runtime+'/status.txt','utf8').includes('正在检查截图'));
 for(let i=0;i<3;i++){
   const shot=ok(await act({action:'shot',x:0,y:0,w:160,h:120}));
   assert.ok(shot.content.some(c=>c.type==='image'&&c.data.length>20),'default screenshot path must return an image');
 }
 assert.equal((await state()).pid,first.pid,'screenshots must not restart effects');
 await delay(4500);
 const phase=JSON.parse(fs.readFileSync(runtime+'/fx-phase.json','utf8'));
 assert.equal(phase.targetOpacity,.1);assert.ok(phase.elapsed>=6&&phase.elapsed<8,JSON.stringify(phase));
 const mismatch=await act({action:'key',keys:'f24',expect:'THIS_WINDOW_MUST_NOT_EXIST_CU_REGRESSION'});
 assert.equal(mismatch.result.isError,true);assert.match(mismatch.result.content[0].text,/EXPECT MISMATCH/);
 ok(await act({action:'stop'}));
 const stopped=await state();assert.equal(stopped.on,false);assert.equal(stopped.pill,false);
 assert.equal(alive(first.pid),false);assert.equal(alive(first.chipPid),false);
 ok(await act({action:'cursor'})); // implicit activation also works after explicit stop
 const auto=await state();assert.equal(auto.on,true);assert.equal(auto.pill,true);
 ok(await act({action:'status',state:'done',text:'检查完成'}));
 assert.equal((await state()).active,false);
 ok(await act({action:'start'})); const endedTask=await state();
 await delay(1500);
 fs.writeFileSync(runtime+'/stop-'+endedTask.sessionId,'task cancelled');
 await gone(endedTask.pid,endedTask.chipPid);
 assert.equal((await state()).active,false,'host stop marker must be observed');
 ok(await act({action:'start'})); const eof=await state();
 await delay(1500);
 if(process.argv.includes('--crash'))p.kill();else p.stdin.end();
 await new Promise(resolve=>p.once('exit',resolve));await gone(eof.pid,eof.chipPid);
 console.log(JSON.stringify({passed:true,phase,timings},null,2));
 fs.writeFileSync(path.join(runtime,'test-result.json'),JSON.stringify({passed:true,phase,timings},null,2));
 passed=true;
}finally{
 if(p.exitCode===null)p.kill();
 // Each run used to leave its temp runtime dir behind (measured: five leftovers after a few
 // runs). A green run has nothing to preserve, so it cleans up after itself; a failing run keeps
 // the directory, which is where the server log and artifacts needed to debug it live.
 if(passed)try{fs.rmSync(runtime,{recursive:true,force:true})}catch{}
}
