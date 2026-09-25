# Changelog

All notable changes to **cu-windows** (`dsh-computer-use`) are recorded here. Dates are local
machine dates; there are no git tags yet, so this file starts with the first released note.

中文提要：本文件记录 cu-windows（dsh-computer-use）的重要变更。目前还没有 git tag，所以从这一版
开始记录；每条下面都有一行中文说明。

## [2.0.0] - 2026-09-26

这一版把"谁负责开关接管特效"从每个调用方的自觉，改成由**会话**持有的结构性保证；CU 也第一次成为
宿主里常驻的 MCP 工具（不再每次调用重开进程）。

### Added

- **`scripts/cu-session.ps1` — one owner for the whole takeover.** A session file plus a
  same-user mutex (`Local\DSH-CU-Session-v2`) holds the overlay pid and the pill pid, and every
  helper re-checks ownership every 400 ms. A helper only counts as alive if **pid, process start
  time and executable path all match** (pid alone would misfire after pid reuse), and the session
  file is replaced atomically. A second task cannot take over a desktop a live session owns.
  中文：新增会话层，把叠层与药丸的归属收进一个带互斥锁和"pid+启动时间+路径"三重校验的会话文件，
  助手每 400 ms 自检归属；别的任务不能抢占正在使用的桌面。
- **`start` / `stop` actions** (`fxon` / `fxoff` remain aliases). Every ordinary action starts a
  session implicitly, and a repeated `start` is idempotent — it does not restart the six-second
  intro. `status -State done` closes the session too.
  中文：新增 `start`/`stop`（`fxon`/`fxoff` 为别名）；普通动作会自动开会话，重复 `start` 幂等，
  不会重播 6 秒开场；`status done` 同样收尾。
- **`mcp/cu-lifecycle.mjs` + `.cjs` — the host closes CU when its task ends.** A lifecycle hook
  writes a generation-specific stop marker on task idle, cancellation and disposal, so the effect
  cannot outlive the work that owns it; the MCP server also closes its own session on stdin EOF,
  and a crashed server is covered by the owner-identity check above.
  中文：新增宿主生命周期钩子：任务 idle / 取消 / dispose 时写 stop 标记收尾；MCP 断开自行清理，
  MCP 崩溃由会话归属校验兜底。
- **`tests/verify-cu.mjs` and `tests/verify-lifecycle.mjs`** — real regression suites. The first
  drives a real MCP server on an isolated runtime dir and asserts 20+ behaviours (no UI on
  discovery, protocol fallback, idempotent `start`, Chinese status text, screenshots that do not
  restart the effect, measured dim phase ≥6 s → 10%, `expect` refusal, `stop`, `status done`,
  stop-marker teardown, helper exit after disconnect) — plus the same with `--crash`. The second
  unit-tests the hook: task completion, mid-tool cancellation, disposal, progress injection, and
  other-task isolation.
  中文：新增两个真回归套件（真起 MCP、隔离运行时、20+ 行为断言，含崩溃路径；钩子覆盖任务完成、
  工具中途取消、dispose、进度注入与跨任务隔离）。

### Changed

- **`mcp__cu__cu` is the ordinary route now, and it is persistent.** The MCP tool keeps one warm
  PowerShell process and returns screenshots as image blocks even without `path`; application
  MCP tools take priority for their own product. `mcp/cu-batch.mjs` is demoted to a hidden-process
  fallback for one complete batch and rejects `--keep-fx` (a session cannot be kept alive by a
  process that exits with the batch).
  中文：常驻 MCP 工具成为常规路径（截图可直接作为图像块返回、无需路径）；产品自带的 MCP 优先；
  批量驱动降级为单批后备，并拒绝 `--keep-fx`。
- **Helper processes are created hidden and inherit no handles** (`CreateProcess` with
  `bInheritHandles=false`), replacing the old `Start-Process` + handle-flag juggling: no terminal
  flash, and a detached helper can no longer hold a caller's stdio pipe open.
  中文：助手进程改为隐藏创建且不继承任何句柄，不再有黑窗闪烁，也不会再抓住调用方管道不放。
- **`docs/SKILL.md` is now a 47-line routing guide**, and the previous long-form diagnostics moved
  verbatim to `docs/references/legacy-diagnostics.md` (561 lines). The knowledge is relocated, not
  dropped — but anyone following a link into the old single file needs to know where it went.
  中文：技能文档精简为 47 行路由指南，原 561 行长文档**原样搬**到 `docs/references/`。
- **The MCP server no longer writes argument payloads to its log** (typed text and clipboard
  contents stayed out of the log), and a malformed request still gets a `-32700` reply.
  中文：服务器不再把参数内容写进日志；坏请求仍会明确回错。

### Fixed

- **The pill no longer outlives its run, and the effect no longer restarts on every batch** —
  both were symptoms of the same missing owner that 1.1.1 worked around with per-batch
  `fxon`/`fxoff`. The session layer removes the workaround.
  中文：药丸不再残留、特效不再每批重播——1.1.1 用的"每批自己开关"权宜做法由会话层取代。

### Verification

Measured on the machine that reported the bugs (3840x2160, PowerShell 7.6.6):

| check | result |
|---|---|
| `node tests/verify-cu.mjs` | `passed: true`, ~15 s, dim phase `elapsed 6.017 s → targetOpacity 0.1` |
| `node tests/verify-cu.mjs --crash` | `passed: true`, ~15 s (helpers exit after the server is killed) |
| `node tests/verify-lifecycle.mjs` | PASS — completion, mid-tool cancellation, disposal, progress, isolation |
| parse errors, pwsh 7.6.6 and Windows PowerShell 5.1 | 0 on every shipped `.ps1`; ASCII-only constraint holds |

中文验证：两个套件加上崩溃变体全部通过；叠层相位实测 6.017 秒降到 10%；所有脚本双宿主 0 解析错误。

## [1.1.1] - 2026-09-26

一天里第三次收到"特效又没了 / 按键点不动"之后做的排查。结论写在最前面：**叠层和输入注入本身
都是好的**（实测 `fxon` 出图、光标真的移动、合成输入真的落进记事本并被 `WM_GETTEXT` 读回）。
坏的是它们**外面那一圈**：调用方、启动时残留的状态行，以及"谁来开特效"这件事没人负责。

### Fixed

- **The MCP warm-up call never reached the toolkit (`Start-Process` argument quoting).** The
  warm-up exists to start the status chip from a throwaway child whose stdio are files, and it
  passed `-Text 'cu-mcp boot'` as one element of an `-ArgumentList` array. `Start-Process` joins
  those elements into a command line **without quoting**, so the child received `-Text cu-mcp`
  plus a stray positional `boot` and died in parameter binding:
  `cu.ps1: A positional parameter cannot be found that accepts argument 'boot'`. Nothing was
  posted to the status file, the chip was never pre-started, and the only symptom at the top was
  an indicator that appeared to do nothing. Fix: quote the value. Measured before/after in one
  run: stderr `... accepts argument 'boot'` / stdout empty → stderr empty / stdout
  `posted: [note] cu ready`, chip pid file written.
  中文：预热调用因为 `Start-Process` 不自动加引号，`-Text 'cu-mcp boot'` 被拆成两个参数、
  绑定失败；药丸因此收不到任何状态，看起来像"点了没反应"。加引号后实测恢复正常。
- **The pill kept showing the previous run's last line, which reads as a dead indicator.** The
  boot sequence cleared `%TEMP%\cu-status.txt` and then posted a new line, but that order is
  wrong: while the OLD chip process is alive, an empty status file makes its reader return early,
  so it sat on its last-known text (`wtext` after a test batch, `shot full screen` an hour after
  that run ended). Fixed by killing the recorded chip first, clearing the pid file, then posting
  one fresh line, so `cu.ps1`'s own guard starts a clean chip that renders the current state.
  Verified: one chip process, `chip.err` empty, `chip.out` = `posted: [note] cu ready`.
  中文：药丸一直显示上一轮最后一条动作，看起来像坏了。原因是"先清文件、后杀旧药丸"的顺序反了；
  改成先杀旧药丸再清文件再发新状态，实测只剩一个药丸进程且显示当前状态。
- **No one was responsible for switching the overlay on.** Investigated on this machine:
  `fxon` produced a correct full-screen overlay (captured and verified) and `fxstatus` reported
  it live — but nothing in the fast path ever called it, so after any `fxoff` the takeover visual
  simply never came back, and the report was "the effect is gone again". The batch driver
  `cu-batch.mjs` now turns the overlay **on as its first action and off as its last one**, and
  asks `fxstatus` first so an already-running overlay is never restarted (restarting replays the
  6 s intro and reads as a flash). Flags: `--no-fx`, `--keep-fx`, `--fx-text "<headline>"`.
  Verified end to end: `[-1] fxon` → plan → `[-1] fxoff`, overlay process gone afterwards,
  screenshot while it was up.
  中文：**没有人负责开特效**。批量驱动现在自动开/关（先 `fxstatus` 判断，避免重播开场动画），
  并给出 `--no-fx` / `--keep-fx` / `--fx-text` 三个开关。

### Added

- `cu fxstatus [-Json]` — report whether the takeover overlay is up, changing nothing. `-Json`
  prints `{"on":true,"pid":N}`, which is what the batch driver parses. Put into
  `docs/SKILL.md`'s action table as the answer to "is it already up?".
  中文：新增 `fxstatus`：只报告叠层状态、不改变任何东西，供调用方避免重复 `fxon`。
- `cu fxon -Text "<headline>"` — a per-run headline, forwarded to `fx.ps1`'s new `-Text`. The
  words still live in `scripts/fx-text.txt` by default (it is the only way to keep a headline
  inside an ASCII-only script), so the file remains the fallback; this is for a caller that wants
  a different line for one run. Measured: the overlay process command line is
  `... -File fx.ps1 -DurationSec 86400 -WatchPid 32556 -Text "大肥鱼接管测试"`, and the captured
  screen shows that exact headline.
  中文：`fxon -Text` 可指定本次文案（`fx.ps1` 新增 `-Text`），默认仍读 `fx-text.txt`。
- `cu <input action> -Expect "<title substring>"` — refuse to inject input unless the foreground
  window's title still matches. This exists for the failure `docs/SKILL.md` keeps documenting:
  `SetForegroundWindow` can fail silently, `focus` reports success, and then every keystroke lands
  in another window while each action still reports success. With `-Expect`, a mismatch prints one
  line naming the window that *would* have received the input and exits non-zero, injecting
  nothing. Covers `click`, `key`, `type`, `paste`, `scroll`, `drag`; the empty default leaves all
  previous behaviour unchanged. Verified on a throwaway Notepad: six mismatching probes all
  refused with exit 1, and the matching control typed `cu_expect_probe_ok` which was read back
  from the edit control.
  中文：输入类动作支持 `-Expect "<窗口标题子串>"`：前台窗口标题不匹配就拒绝注入、退出码非零并
  说明"输入没有发出去"，专门治"焦点悄悄跑掉、动作却报成功"这个老问题；默认空值，行为不变。
  The MCP wrapper maps `expect` too, so a batch plan carries the same guard
  (`{"action":"key","keys":"enter","expect":"Slay the Spire 2"}`). Verified through the real MCP
  path: the matching step returned `sent keys: f24`, the mismatching one returned the refusal line
  and the activity chip turned red with the same message.
  中文：MCP 也映射了 `expect`，护栏可以直接写进批量计划；实测匹配的那步正常发送、不匹配的那步拒绝
  并让药丸变红报错。
- `mcp/cu-mcp.ps1` and `mcp/cu-batch.mjs` — the warm-process MCP server and its batch driver are
  now in the repo instead of living only on this machine. They are **tailored to this machine**
  (absolute paths, Store-aliased `pwsh.exe`); read them before reuse. Measured on this box: a
  fresh `pwsh -File cu.ps1 <action>` costs ~2.4 s, the warm path ~90-150 ms.
  中文：把机器本地的 MCP 服务器与批量驱动收进仓库（含绝对路径，属于本机定制，复用前先读）。

### Fixed (found while verifying the additions above, in the MCP layer)

- **A non-ASCII argument killed the request, and the failure looked like a hang.** The MCP server
  set `[Console]::OutputEncoding = UTF8` but never the *input* encoding, so the reader decoded the
  client's UTF-8 JSON with the ANSI codepage: `大肥鱼` arrived as `澶ц偉楸?`, `ConvertFrom-Json`
  failed, and the request was answered with nothing at all. Measured: the same `fxon` call took
  **334 ms** with a CJK headline but **90 s (client timeout)** before the fix; the server log line
  was `bad json: ..."澶ц偉楸兼帴绠℃祴璇?}}`. Fixed with `[Console]::InputEncoding = UTF8`.
  中文：MCP 服务器只设了输出编码没设输入编码，UTF-8 的中文到服务器变成乱码 → JSON 解析失败 →
  请求永远等不到回复（表现为 90 秒超时）。补上输入编码后 334 ms 返回。
- **A malformed request line got no reply at all.** The parse-failure path logged and `continue`d,
  so the caller waited for an answer that never came. It now replies with JSON-RPC `-32700` and a
  message naming the likely cause, which turns a mystery hang into an error message.
  中文：请求行解析失败时原来只记日志、不回复；现在回一个 -32700 错误，把"莫名卡住"变成明确的报错。

### Notes

- Orphaned helpers are a real residue of a crashed caller: two takeover overlays, whose parent
  process no longer existed and whose watchdog pid was the *harness* window (still alive), were
  found running and had to be killed by hand. `fxkill.cmd` is the intended answer; a run that
  ends cleanly must still call `fxoff`.
  中文：调用方崩溃会留下孤儿叠层（本次实测有两个，父进程已死、看门狗却指向仍活着的宿主窗口），
  只能手动清掉；正常收尾的流程必须自己 `fxoff`。

## [1.1.0] - 2026-09-26

这一版包含两批改动：2026-09-25 晚上在本机做但一直没有推送的修复，以及 2026-09-26 的"管道被占住
导致卡死"修复。

### Fixed

- **A piped caller could hang forever (`Start-Detached`).** The long-lived helpers (the activity
  chip and the fx overlay) inherited the caller's stdout pipe, so any caller that captured
  `cu.ps1` through a pipe — an agent harness, a `| Out-Null`, a CI step — waited for an EOF that
  never arrived: the action looked hung with no output at all. Root cause: the CIM branch does not
  succeed in this environment, so the `Start-Process` fallback runs; it must pass two redirect
  handles, which means the child is created with `bInheritHandles=TRUE`, and that hands over every
  inheritable handle the caller owns, redirects or not. Fix: clear `HANDLE_FLAG_INHERIT` on the
  toolkit's own stdin/stdout/stderr for the duration of the spawn and restore it afterwards, so the
  helper starts with clean stdio while still outliving the action.
  中文：修掉"带管道的调用方永远卡住"的 bug —— 常驻的状态药丸/覆盖层会继承调用方的输出管道。
- **Host name for the detached helpers is derived from `$PSHOME`** instead of assuming
  `powershell`. Once PowerShell 7 was installed, the store alias `powershell.exe` also launched
  pwsh, while the duplicate-chip guard still filtered on `Name='powershell.exe'`: the guard never
  saw the chip, so every action stacked another pill on the same spot.
  中文：常驻助手用哪种宿主改为从 `$PSHOME` 推导，修掉装完 PS7 后"每次动作叠一个新药丸"的问题。
- **Duplicate-chip detection matches the closing quote** after `cu-status.ps1` rather than the bare
  substring, so a diagnostic shell whose command line merely mentions the file is no longer mistaken
  for the chip (a self-matching kill once produced a silent, output-less failure).
  中文：药丸去重改为匹配 `cu-status.ps1"` 的收尾引号，避免把自己的诊断进程误判成药丸。

### Changed

- **The helpers watch a window title instead of a hardcoded `-WatchTitle` parameter**: closing the
  embedding application takes the chip and the overlay with it, so no fog is stranded on screen.
  中文：药丸/覆盖层改为按窗口标题找宿主，关闭宿主应用就会一起退出，不会留下没人能关的雾。
- **Overlay and chip wording** is now personalised (`DaFeiYu is taking over`, chip label `DaFeiYu`)
  rather than the generic `computer use in progress` / `Computer Use`.
  中文：覆盖层与药丸的文案改成个性化版本（原来的通用文案仍可从 README 的自定义说明里改回）。

### Added

- `scripts/fonts/GrenzeGotisch.ttf` — the blackletter face the overlay actually uses here (SIL Open
  Font License 1.1, like the other two).
  中文：补上覆盖层实际使用的哥特字体文件。
- This changelog.
  中文：本更新日志。

### Docs

- `docs/SKILL.md`: PowerShell 7 is now documented as installed alongside 5.1 (both hosts verified;
  the MSIX alias and the "restart the app or `pwsh` is invisible" trap), the `fxon` overlay flags,
  the accessibility wake-up measurements for Chromium/Electron apps (DSH, Codex/ChatGPT desktop,
  VS Code, Edge, Steam), the name-matching rules for duplicate controls, and the kill switch.
  中文：技能文档补上 PS7/5.1 双宿主说明、`fxon` 参数、Chromium/Electron 无障碍唤醒实测数据、
  重名控件的匹配规则与 kill switch。

### Verification of the 2026-09-26 fix

Measured on the machine that hit it (3840x2160, PowerShell 7.6.6):

| | before | after |
|---|---|---|
| piped `cu windows -Json \| Out-Null`, chip not running | never returned (25 s and 40 s runs, released only by killing the chip) | returns in ~5 s (including the one-off chip start) |
| that call plus `cu shot` plus the overlay plus `fxoff` | hung at the first step | 11.4 s total |
| chip after the caller exits | — | still running (long-lived as designed) |

Reproduction that isolates it without any MCP server in the path:

```powershell
# kill the chip first, then run this inside a shell whose stdout is captured
& pwsh -NoProfile -ExecutionPolicy Bypass -File <skill>\scripts\cu.ps1 windows -Json 2>&1 | Out-Null
# before the fix: never returns.  after: returns in a few seconds.
```

中文验证：把药丸杀掉再带管道调用 `cu windows` —— 修复前永不返回（杀了药丸才解锁），修复后约 5 秒
返回；完整一串（windows + shot + 覆盖层 + fxoff）共 11.4 秒；调用方退出后药丸仍在运行。
