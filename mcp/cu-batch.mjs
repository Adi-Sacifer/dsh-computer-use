// Batch driver for the cu MCP server: run several cu actions in ONE warm process.
//
// Why: the harness spawns a fresh pwsh per tool call, and cu.ps1 costs ~1 s per action plus
// process start. Booting the MCP server once and feeding it a plan of several actions costs
// ~2-3 s total for the whole batch, so a turn that needs "screenshot, click, click, end turn"
// fits in a single tool call. The plan arrives on stdin as a JSON array of cu arguments, e.g.
//
//   [{"action":"shot","x":0,"y":0,"w":1920,"h":1080,"path":"C:\\...\\s1.png"},
//    {"action":"click","x":3419,"y":1754}]
//
// Prints one line per step: index, action, duration, and the toolkit's own report text.
//
// Overlay (the "dafeiyu is taking over" effect): the batch turns it ON as its first action and
// OFF as its last one, so the takeover visual follows the automation by itself. Before this,
// fxon had to be remembered as a separate step, and when it was forgotten the user saw the
// effect "disappear again" even though nothing was broken. Flags:
//   --no-fx     never touch the overlay (leave whatever is on screen alone)
//   --keep-fx   turn it on if it is off, and leave it up when the batch ends
//   --fx-text   headline text; an empty value keeps the toolkit's own default
import { spawn } from 'node:child_process';

const srv = 'C:\\Users\\Administrator\\.dsh\\mcp\\cu-mcp.ps1';
const pwsh = (process.env.LOCALAPPDATA || 'C:\\Users\\Administrator\\AppData\\Local') + '\\Microsoft\\WindowsApps\\pwsh.exe';

// actions that already drive the overlay themselves - never auto-inject around them
const FX_ACTIONS = new Set(['fxon', 'fxoff']);
// actions that inject input and therefore need the target window to be foreground
const INPUT_ACTIONS = new Set(['click', 'key', 'type', 'paste', 'drag', 'scroll']);

const argv = process.argv.slice(2);
const flag = (name) => argv.includes(name);
const value = (name) => {
  const i = argv.indexOf(name);
  return i >= 0 && i + 1 < argv.length ? argv[i + 1] : null;
};
const noFx = flag('--no-fx');
const keepFx = flag('--keep-fx');
const fxText = value('--fx-text');

const stdin = await new Promise((res) => {
  let d = '';
  process.stdin.setEncoding('utf8');
  process.stdin.on('data', (c) => { d += c; });
  process.stdin.on('end', () => res(d));
});
let plan;
try { plan = JSON.parse(stdin); } catch (e) { console.log('BAD PLAN JSON: ' + e.message); process.exit(2); }
if (!Array.isArray(plan) || plan.length === 0) { console.log('EMPTY PLAN'); process.exit(2); }

const p = spawn(pwsh, ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', srv], { stdio: ['pipe', 'pipe', 'pipe'] });
let buf = '';
const waiters = new Map();
p.stdout.on('data', (d) => {
  buf += d.toString('utf8');
  let i;
  while ((i = buf.indexOf('\n')) >= 0) {
    const line = buf.slice(0, i).trim();
    buf = buf.slice(i + 1);
    if (!line) continue;
    let m;
    try { m = JSON.parse(line); } catch { continue; }
    if (m.id !== undefined && waiters.has(m.id)) { waiters.get(m.id)(m); waiters.delete(m.id); }
  }
});
p.stderr.on('data', () => {});
p.on('error', (e) => { console.log('SPAWN ERROR: ' + e.message); process.exit(3); });

let nextId = 1;
function call(method, params) {
  const id = nextId++;
  return new Promise((resolve) => {
    waiters.set(id, resolve);
    p.stdin.write(JSON.stringify({ jsonrpc: '2.0', id, method, params }) + '\n');
    setTimeout(() => { if (waiters.has(id)) { waiters.delete(id); resolve({ timeout: true }); } }, 90000);
  });
}

function show(i, action, ms, r) {
  if (r.timeout) { console.log(`[${i}] ${action} TIMEOUT after ${ms} ms`); return; }
  const content = (r.result && r.result.content) || [];
  const parts = content.map((c) => (c.type === 'image' ? `<image ${c.mimeType} ${Math.round((c.data || '').length / 1365)} KB>` : String(c.text || '').replace(/\s+/g, ' ').trim()));
  console.log(`[${i}] ${action} ${ms}ms :: ${parts.join(' | ').slice(0, 3000)}`);
}

async function act(i, args) {
  const t = Date.now();
  const r = await call('tools/call', { name: 'cu', arguments: args });
  show(i, args.action, Date.now() - t, r);
  return r;
}

async function main() {
  const init = await call('initialize', { protocolVersion: '2026-07-28', capabilities: {}, clientInfo: { name: 'batch', version: '0' } });
  p.stdin.write(JSON.stringify({ jsonrpc: '2.0', method: 'notifications/initialized' }) + '\n');
  if (init.timeout) { console.log('initialize TIMED OUT'); p.kill(); process.exit(4); }

  const t0 = Date.now();

  // Is the overlay already up? fxon is idempotent-ish (it replaces the old pid), but turning it
  // on again mid-run would restart the intro animation, so check first.
  let fxWasOn = false;
  if (!noFx) {
    const probe = await call('tools/call', { name: 'cu', arguments: { action: 'fxstatus', json: true } });
    const txt = probe.timeout ? '' : (((probe.result || {}).content || []).map((c) => String(c.text || '')).join(' '));
    try { fxWasOn = JSON.parse(txt).on === true; } catch { fxWasOn = false; }
  }
  if (!noFx && !fxWasOn) {
    const args = { action: 'fxon' };
    if (fxText) args.text = fxText;
    await act(-1, args);
  }

  for (let i = 0; i < plan.length; i++) {
    const args = plan[i];
    const r = await act(i, args);
    if (r.timeout) break;
  }

  if (!noFx && !keepFx && !fxWasOn) await act(-1, { action: 'fxoff' });
  console.log(`batch done in ${Date.now() - t0} ms (${plan.length} actions + server boot)`);
  p.stdin.end();
  setTimeout(() => { p.kill(); process.exit(0); }, 400);
}
main();
