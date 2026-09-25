import fs from 'node:fs';
import path from 'node:path';
import assert from 'node:assert/strict';
import {apply} from '../mcp/cu-lifecycle.mjs';
const root=path.join(process.env.TEMP,'dsh-cu-lifecycle-test-'+Date.now());fs.mkdirSync(root,{recursive:true});process.env.DSH_CU_RUNTIME_DIR=root;
const handlers=new Map();let dispose;const ctx={on:(name,fn)=>handlers.set(name,fn),effect:fn=>{dispose=fn();},logger:{info:()=>{}}};apply(ctx);
const task={status:'running'},other={status:'running'};
let nextId=0;
const session=()=>{const s={active:true,id:'test-'+(++nextId)};fs.writeFileSync(path.join(root,'session.json'),JSON.stringify(s));fs.writeFileSync(path.join(root,'status.txt'),'1|busy|3|test');return s;};
const execute=async(agent,body,signal=new AbortController().signal)=>handlers.get('tools/execute')({name:'mcp__cu__cu',arguments:{action:'start'},agent,signal},body);
let current;
await execute(task,async()=>{current=session();return {isError:false}});
await assert.rejects(execute(other,async()=>({})),/another task/);
await handlers.get('agent/pre-step')({agent:task},async()=>({kind:'enter'}));assert.match(fs.readFileSync(path.join(root,'status.txt'),'utf8'),/正在分析/);
handlers.get('agent/status')({agent:other,status:'idle'});assert.ok(!fs.existsSync(path.join(root,'stop-'+current.id)));
handlers.get('agent/status')({agent:task,status:'idle'});assert.ok(fs.existsSync(path.join(root,'stop-'+current.id)));
const controller=new AbortController();await execute(task,async()=>{current=session();controller.abort();return {isError:true}},controller.signal);assert.ok(fs.existsSync(path.join(root,'stop-'+current.id)));
await execute(task,async()=>{current=session();return {}});handlers.get('agent/disposed')({agent:task});assert.ok(fs.existsSync(path.join(root,'stop-'+current.id)));
await execute(task,async()=>{current=session();return {}});dispose();assert.ok(fs.existsSync(path.join(root,'stop-'+current.id)));
console.log('PASS: task completion, cancellation during a tool, disposal, progress, other-task isolation.');
// Green run: drop the temp runtime dir instead of leaving one behind per run. On failure the
// directory survives (the throw happens above), which is where the session/status files are.
try{fs.rmSync(root,{recursive:true,force:true})}catch{}
