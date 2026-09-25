// Host lifecycle hook: ends CU when its owning task finishes, is cancelled or disposed.
// No subprocesses or screen access: GUI helpers observe the generation-specific stop marker.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
export const name='cu-lifecycle';
// Event-only integration; it does not consume a scoped service instance.
export const inject=[];
export function apply(ctx) {
  const root=process.env.DSH_CU_RUNTIME_DIR||path.join(os.tmpdir(),'dsh-cu-session');
  const stateFile=path.join(root,'session.json');
  fs.mkdirSync(root,{recursive:true});
  const log=message=>{try{fs.appendFileSync(path.join(root,'lifecycle.log'),`${new Date().toISOString()} ${message}\n`);}catch{}};
  let owner=null;
  function read(){try{const s=JSON.parse(fs.readFileSync(stateFile,'utf8'));return s.active&&!fs.existsSync(path.join(root,'stop-'+s.id))?s:null;}catch{return null;}}
  function close(agent){
    if(!owner||owner.agent!==agent)return;
    const current=read();
    if(current?.id===owner.sessionId){fs.writeFileSync(path.join(root,'stop-'+current.id),'task ended\n');log('closed CU session '+current.id);}
    owner=null;
  }
  function progress(agent,message,state='busy'){
    const current=read();if(!owner||owner.agent!==agent||current?.id!==owner.sessionId)return;
    try{
      const file=path.join(root,'status.txt');
      const previous=fs.readFileSync(file,'utf8').split('|');
      fs.writeFileSync(file,`${Date.now()}|${state}|${previous[2]||0}|${message.replace(/[|\r\n]/g,' ')}`,'utf8');
    }catch{}
  }
  ctx.on('tools/execute',async(exec,next)=>{
    if(exec.name!=='mcp__cu__cu')return next();
    const action=exec.arguments?.action;
    if(action==='fxstatus')return next();
    const before=read();
    if(before&&owner?.sessionId===before.id&&owner.agent!==exec.agent)throw Error('CU is currently owned by another task; finish or stop that task first.');
    let result;
    const cancelled=()=>close(exec.agent);
    exec.signal?.addEventListener('abort',cancelled,{once:true});
    try{return result=await next();}
    finally{
      exec.signal?.removeEventListener('abort',cancelled);
      const current=read();
      if(current&&(!result?.isError||current.id!==before?.id))owner={agent:exec.agent,sessionId:current.id};
      else if(!current&&owner?.agent===exec.agent)owner=null;
      if(exec.signal?.aborted||exec.agent?.status==='idle')close(exec.agent);
    }
  });
  ctx.on('agent/pre-step',async(event,next)=>{
    progress(event.agent,'正在分析当前结果，准备下一步');
    return next();
  });
  ctx.on('agent/status',({agent,status})=>{if(status==='idle')close(agent);});
  ctx.on('agent/disposed',({agent})=>close(agent));
  ctx.effect(()=>()=>{if(owner)close(owner.agent);});
  ctx.logger.info('CU lifecycle ready: task completion/cancellation closes overlay and pill');
  log('CU lifecycle registered in DeepSeek host pid='+process.pid);
}
