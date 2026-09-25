// CLI fallback only. Prefer the registered, persistent mcp__cu__cu tool.
import {spawn} from 'node:child_process';
import {fileURLToPath} from 'node:url';
import path from 'node:path';
const argv=process.argv.slice(2);
if(argv.includes('--keep-fx')){console.error('--keep-fx is unsupported: use the persistent MCP tool for a multi-call CU session.');process.exit(2);}
const noFx=argv.includes('--no-fx');
const at=argv.indexOf('--fx-text'),headline=at>=0?argv[at+1]:undefined;
let source='';process.stdin.setEncoding('utf8');for await(const chunk of process.stdin)source+=chunk;
let plan;try{plan=JSON.parse(source);if(!Array.isArray(plan)||!plan.length)throw Error('Expected a nonempty JSON action array');}catch(e){console.error(e.message);process.exit(2);}
const server=path.join(path.dirname(fileURLToPath(import.meta.url)),'cu-mcp.ps1');
const executable=process.env.LOCALAPPDATA+'\\Microsoft\\WindowsApps\\pwsh.exe';
const child=spawn(executable,['-NoLogo','-NoProfile','-NonInteractive','-STA','-WindowStyle','Hidden','-ExecutionPolicy','Bypass','-File',server],{windowsHide:true,stdio:['pipe','pipe','pipe']});
let buffer='',seq=0,stderr='';const waiting=new Map();
function fail(error){for(const w of waiting.values()){clearTimeout(w.timer);w.reject(error)}waiting.clear();}
child.on('error',fail);child.on('exit',code=>fail(Error('CU server exited ('+code+'): '+stderr.slice(-1500))));
child.stdin.on('error',fail);child.stderr.on('data',d=>{stderr=(stderr+d.toString('utf8')).slice(-4000)});
child.stdout.setEncoding('utf8');child.stdout.on('data',d=>{buffer+=d;for(let i;(i=buffer.indexOf('\n'))>=0;){const line=buffer.slice(0,i).trim();buffer=buffer.slice(i+1);if(!line)continue;let reply;try{reply=JSON.parse(line)}catch{fail(Error('Invalid MCP output'));continue;}const w=waiting.get(reply.id);if(w){clearTimeout(w.timer);waiting.delete(reply.id);w.resolve(reply)}}});
function request(method,params){return new Promise((resolve,reject)=>{const id=++seq;const timer=setTimeout(()=>{waiting.delete(id);reject(Error(method+' timed out'));},120000);waiting.set(id,{resolve,reject,timer});child.stdin.write(JSON.stringify({jsonrpc:'2.0',id,method,params})+'\n');});}
function check(reply){if(reply.error||reply.result?.isError)throw Error(reply.error?.message||reply.result.content.filter(c=>c.type==='text').map(c=>c.text).join('\n'));return reply.result;}
async function action(args){return check(await request('tools/call',{name:'cu',arguments:args}));}
try{
 check(await request('initialize',{protocolVersion:'2025-06-18',capabilities:{},clientInfo:{name:'cu-batch-fallback',version:'2'}}));
 child.stdin.write(JSON.stringify({jsonrpc:'2.0',method:'notifications/initialized'})+'\n');
 if(!noFx)await action({action:'start',...(headline?{text:headline}:{})});
 for(let i=0;i<plan.length;i++){
   const args={...plan[i],...(noFx?{noChip:true}:{})};const t=Date.now();
   const result=await action(args);
   console.log(`[${i+1}/${plan.length}] ${args.action} ${Date.now()-t}ms :: `+result.content.map(c=>c.type==='image'?'<image>':c.text||'').join(' | '));
 }
}catch(e){console.error(e.message);process.exitCode=1;}
finally{
 if(child.exitCode===null&&!child.killed){
   // EOF runs owner-scoped cleanup in the server; watchdog also handles a forced exit.
   child.stdin.end();
   const killer=setTimeout(()=>child.kill(),2000);
   await new Promise(resolve=>{child.once('exit',resolve);if(child.exitCode!==null)resolve()});clearTimeout(killer);
 }
}
