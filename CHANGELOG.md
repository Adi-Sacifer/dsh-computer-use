# Changelog

All notable changes to **cu-windows** (`dsh-computer-use`) are recorded here. Dates are local
machine dates; there are no git tags yet, so this file starts with the first released note.

中文提要：本文件记录 cu-windows（dsh-computer-use）的重要变更。目前还没有 git tag，所以从这一版
开始记录；每条下面都有一行中文说明。

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
