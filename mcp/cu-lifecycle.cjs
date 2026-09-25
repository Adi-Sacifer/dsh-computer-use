// CommonJS entry point for the desktop host's module loader.
const fs=require('node:fs');
const path=require('node:path');
const {pathToFileURL}=require('node:url');
module.exports={name:'cu-lifecycle',async apply(ctx){
  const file=path.join(__dirname,'cu-lifecycle-startup.log');
  try{
    const plugin=await import(pathToFileURL(path.join(__dirname,'cu-lifecycle.mjs')).href+'?build=2');
    plugin.apply(ctx);
    fs.appendFileSync(file,new Date().toISOString()+' registered host='+process.pid+'\n');
  }catch(error){fs.appendFileSync(file,new Date().toISOString()+' '+error.stack+'\n');throw error;}
}};
