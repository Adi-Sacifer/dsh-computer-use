---
name: computer-use
description: Operate the Windows desktop directly - screenshot the screen, click, type (Unicode/CJK safe), press keys, scroll, drag, and drive applications through UI Automation. Use when a task requires seeing or controlling a GUI, or automating an app that exposes no CLI.
whenToUse: The task needs to look at the screen, click or type in an application, or drive a GUI that has no command-line interface or API.
---

# Computer use (Windows desktop control)

> **Public release note.** This document is the working field-notes file the toolkit ships with.
> Concrete application names, window titles and personal labels have been replaced with generic
> wording for publication; the measured numbers are kept, because they show the magnitude of each
> problem rather than identify a machine.

You can see and control this machine's desktop. The toolkit lives next to this file:

- `scripts/cu.ps1` — the whole toolkit (ASCII-only source, by necessity; see Environment).
- `scripts/cu.cmd` — thin wrapper that adds `-ExecutionPolicy Bypass`. **ASCII arguments only.**

Loop: **screenshot → read the image → act → screenshot again to verify.** Never assume an action
landed; always confirm with a fresh screenshot or a state query.

## Invoking the toolkit

The machine's shell is **Windows PowerShell 5.1** (there is no `pwsh` 7), and the execution policy
is `Restricted`, so a `.ps1` cannot be run bare. Always launch it like this:

```powershell
$cu = "<skill base dir>\scripts\cu.ps1"
& powershell -NoProfile -ExecutionPolicy Bypass -File $cu <action> [args...]
```

Use this form **always** when any argument contains non-ASCII (Chinese text to type, a Chinese
window title). `cmd.exe` mangles non-ASCII argv, so `cu.cmd` is only safe for pure-ASCII calls:

```powershell
& "<skill base dir>\scripts\cu.cmd" info
```

Both forms return exit code 0 on success and non-zero on failure. In a multi-step script, check
`$LASTEXITCODE` before continuing — a failed `focus` must abort a following `type`.

## Actions

| Action | Purpose |
|---|---|
| `info` | Screen size, cursor position, foreground window, shell version |
| `shot [-KeepFx]` | Screenshot → PNG. Full screen; or `-X -Y -W -H` region; or `-Hwnd n` / `-Title "win"` for one window. `-Grid 400` overlays a labelled coordinate grid. The capture does **not** touch the overlay: the ambient fog is part of the picture, deliberately (see below). `-KeepFx` is now a no-op kept for compatibility. An unrecognised selector silently falls back to full screen, so always check the reported size |
| `cursor` | Print cursor position |
| `move -X -Y` | Move the pointer |
| `click [-X -Y] [-Button left\|right\|middle] [-Double] [-Count n]` | Click (at the current position if no `-X`). Refuses targets outside the desktop instead of letting `SetCursorPos` clamp silently, and reports **which window ended up under the point** |
| `drag -X1 -Y1 -X2 -Y2` | Press, move in steps, release |
| `scroll [-Amount n] [-X -Y]` | Wheel; negative scrolls down |
| `type -Text "..."` | Type text, **Unicode-safe**: Chinese, emoji, and newlines work |
| `paste -Text "..."` | Clipboard + `Ctrl+V`; faster for long text, restores the old clipboard |
| `key -Keys "ctrl+s"` | Chord or single key: `enter`, `alt+tab`, `win`, `f5`, `ctrl+shift+t` |
| `windows [-All] [-Json]` | List visible top-level windows: hwnd, pid, process, rect, title. `-Json` emits one compact JSON object per line (NDJSON) — use it for parsing instead of the table |
| `focus -Title "..." \| -Hwnd n` | Bring a window to the front |
| `clip [-Text "..."]` | Read the clipboard, or set it |
| `uia -Mode tree\|find\|click\|settext\|focus [-Name "..."] [-Text "..."] [-Index n] [-Exact] [-Depth n] [-Title "win"] [-Hwnd n] [-All]` | UI Automation. **Wakes Chromium/Electron accessibility first, then enumerates.** `find` returns ranked matches each ending in its exact `click x,y`; `-Index n` acts on the nth ranked match; `-Exact` requires a whole-name match. Prefer `-Hwnd` (from `windows -Json`) over `-Title`: duplicate titles exist here and matching is by substring. `-All` on `tree` also prints unnamed nodes; `-NoWake` skips the wake |
| `wake [-Hwnd n \| -Title "win"] [-WakeMs n]` | Explicitly turn a Chromium/Electron window's accessibility tree on (or diagnose why it stays empty) and report `tree : N -> M nodes` |
| `status -Text "..." [-State busy\|note\|ok\|err\|done]` | Post a progress line to the activity chip. Use it for the phases that are **not** computer-use — waiting on an API, generating a file, thinking — so "is it still working?" has an answer even when no window is being clicked. `-State done` shows a green finish and auto-hides shortly after |
| `sleep -DelayMs n` | Wait |
| `fxon [-DurationSec n]` | Show the takeover overlay: black fog from every screen edge, a glowing gradient headline, and a blackletter Latin subtitle. Click-through, never steals focus. Full strength for `-DimAfterSec` (6 s), then eases to `-Dim` (10%) and **stays there** for the whole takeover; `-DurationSec` defaults to 86400 and is only a backstop |
| `fxoff` | Hide the overlay at once |

## Coordinates: always prefer UIA over pixels

`cu.ps1` sets DPI awareness itself — `SetProcessDpiAwarenessContext(-4)` (per-monitor V2) with a
fallback to `SetProcessDPIAware()` — so every number it reports and accepts is a **physical
pixel**. The desktop is **3840x2160 at 175% scaling** (verified after the change: `info` still
reports `virtualScreen : 3840x2160`, not the 2194x1234 a DPI-unaware process would see).

`shot` output is 3840x2160, but reading it back through the image tool downscales it (a preview of
1708x961). **Do not estimate coordinates off a downscaled preview by eye.** Instead:

1. **Best: use `uia`.** `uia -Mode find -Name "保存"` returns real control rectangles; then
   `uia -Mode click -Name "保存"` invokes the control's own pattern, or clicks its centre. This
   works regardless of scaling, and survives layout changes. Every `-Name` is a **substring** match.
2. Otherwise take the shot with `-Grid 400`; the labels are true physical coordinates, so read the
   target position directly off the gridlines.
3. Or capture a region (`-X -Y -W -H`) so less downscaling happens.

`uia` targets the foreground window unless `-Hwnd` or `-Title` names one. `uia -Mode tree` prints
control type, name, automation id, and rect — use it first on an unfamiliar app.

### UIA coverage: Chromium/Electron must be WOKEN first (measured)

**The single biggest cause of "the pointer keeps landing on the wrong button" was this:**
Chromium and Electron apps (any web page in Chrome/Edge, VS Code, the 某 Electron 聊天应用/该 Electron 应用 desktop
app, 宿主 itself) keep their **accessibility engine switched off** until something asks for an
accessibility object. A fresh UIA query on such a window therefore returns almost nothing, the
agent gives up on UIA and falls back to eyeballing a downscaled screenshot — and eyeballing a
3840x2160 capture that the image reader shrank to ~1708 px wide is how clicks end up on the
neighbouring control.

`cu.ps1` now fixes this automatically: **every `uia` action first sends
`WM_GETOBJECT`/`OBJID_CLIENT` (and `UiaRootObjectId`) to the target window and each of its
child windows — exactly what a screen reader does on startup — then polls until the tree stops
growing.** Measured on this desktop:

| Window | Before wake | After wake |
|---|---|---|
| 宿主 (Electron) | 13 nodes, 4 named, no usable rects | **158 nodes, 140 named, all with real rects** |
| 该 Electron 应用 / 某 Electron 聊天应用 desktop | 7 nodes, 1 named | **~100 nodes**, incl. `Edit 输入框 2376,1596 1247x77` |

The wake **persists for the life of the target process** — a second query is instant, and it
does not need repeating. `uia` prints what happened (`a11y : woke 1 hwnd(s), tree 13 -> 158
nodes in 400 ms`), and `wake [-Hwnd n | -Title "win"]` does it explicitly and reports the
result.

**If a tree still looks empty, suspect the wrong window, not a failed wake.** Measured: the
该 Electron 应用 app's window `133060` stayed at 13 nodes no matter what was poked, because it is an
empty companion window — the real UI lived in window `460604` of the *same* process, which had
a full tree. Always run `windows -Json` and pick the window that is actually on screen.

So the order of preference is now:

1. **`uia -Mode find -Name "..."`** — returns ranked matches with real rects, an `onScreen`
   flag, and **the exact click point on each line** (`click 3000,1634`). No arithmetic, no
   scaling error.
2. `shot -Grid 400` — the labels are true physical coordinates. Every gridline is labelled
   (not every other one), so nothing has to be interpolated by eye.
3. A region capture (`-X -Y -W -H`) so the image is not downscaled at all.

| App | What UIA exposes |
|---|---|
| File Explorer | Full tree: Ribbon, `Shell 文件夹视图`, StatusBar, window buttons `最小化`/`最大化`/`关闭`. `uia -Mode click` works via `InvokePattern` |
| **Electron / Chromium (宿主, VS Code, 该 Electron 应用/某 Electron 聊天应用 desktop, 某个 CEF 应用, and web pages in Edge)** | **Full tree once woken — buttons, menu bar, `Edit` boxes and table cells with exact rects. This is now the normal case, not an exception.** Measured on a web page in Edge: `woke 2 hwnd(s), tree 47 -> 162 nodes`, then `Button | 开始按钮 | 1690,1290 462x141`, `MenuItem | 账单入口`, and a `DataItem` table cell that copies an API key when clicked. `uia -Mode click` used `InvokePattern` — no coordinates involved at all |
| Classic Win10 Notepad | Only two unnamed `Pane`s — screenshot it |
| Flutter (一个 Flutter 应用 and similar) | One `Pane` named `FLUTTERVIEW`. Screenshots only — **and see the switch warning below** |

`uia` targets the foreground window unless `-Hwnd` or `-Title` names one — **prefer `-Hwnd`**:
titles are duplicated here (two windows are both called `某 Electron 聊天应用`) and matching is by substring.

### Acting on the right match, not just any match

`-Name` is a case-insensitive **substring** match, so it usually hits several controls
(`输入框` matched both the `Edit` box and its placeholder `Text`). Two rules keep that honest:

- Matches are **ranked**: on-screen and clickable first, then partly off screen, then
  no-usable-rectangle. The old code silently acted on "the first hit", which is often a hidden
  duplicate.
- `-Index n` picks the nth ranked match; `-Exact` requires the whole name to be equal. If the
  index is out of range you get a clear error instead of a wrong click.
- Matching deliberately avoids `-like`, so a name containing `[`, `]` or `*` cannot turn into a
  wildcard and match the wrong control.

### Every click now proves where it landed

A click that lands on the wrong window used to look exactly like a control that ignores input.
Reviewing this fix (with 该 Electron 应用, on this desktop) produced the rule worth keeping: **split one
click into three checks — which window was selected, which screen point was computed, and who
actually owned that point when the input was injected.** `cu.ps1` now reports all three:

```
clicked [1] Edit | 输入框 | 2376,1596 1247x77 | onScreen=True | click 3000,1634
        via mouse@3000,1634 over '某 Electron 聊天应用' : '输入框'
```

- `click -X -Y ...` also ends with `over '<window title>'`, and it **refuses** to click outside
  the desktop instead of letting `SetCursorPos` silently clamp to the screen edge (which reports
  a plausible position while clicking somewhere else).
- Before injecting, `uia click` reverse-checks the point with
  `AutomationElement.FromPoint(x,y)` and warns when the point is really over a *different*
  element — a bounding rectangle can be partly occluded, and `IsOffscreen=false` does not mean
  "nothing is covering it".
- It also warns when the element is **disabled**, or when `SendInput` accepted fewer events than
  it sent — the signature of UIPI silently dropping input aimed at an **elevated** window. In
  that case the coordinates were fine and looking at them harder is a waste of time.
- When a name matches several controls and no `-Index` was given, the call says so instead of
  picking one quietly:
  `WARNING: 2 controls match '*输入框*' and no -Index was given - acting on [1]. Also matched: [2] 输入框`
- Stale rectangles are avoided by re-querying on every call (`uia` has no cached-element path),
  which matters after scrolling, window moves, list refresh, or animation. Virtualised list items
  may not exist in the tree until they are realised on screen — if a name is missing, scroll it
  into view and re-query rather than concluding the locator is wrong.

**Before blaming your own coordinates, check `IsIconic`.** A minimized window keeps reporting a
stale `rect` in `windows -Json` (e.g. `1569,478,700,1132`) while actually sitting at
`-32000,-32000`: every click you aim at that rect goes nowhere, and it looks exactly like a pointer
accuracy bug. Measured the hard way — a whole session of clicks on 该 Flutter 应用 missed because the window
had been minimized, and `focus -Hwnd` reported success anyway. Always confirm with
`[user32]::IsIconic($h)` (or `-Property minimized` if you add one) and `ShowWindow($h, 9)` first.

**Synthetic clicks do not drive every control.** Measured on the Flutter app: `Tab`-order buttons
and text fields respond to `click`/`type` normally, but its pill switches (系统代理开关 / 增强模式开关 /
自动续费开关) ignore synthetic pointer input entirely — while a `settings` tab 20 px away switches the
page on the first click. So the click pipeline is fine and those widgets are not.

This was chased to the end with an externally-authored probe (`Documents\input-diagnosis\`, from a
gpt-6-astra review) that gates on real state instead of trusting its own success. Result over
**7 strategies** — single click at 0/0 ms, 150/0, 0/80 and 150/80 ms move→down/down→up gaps, a
one-jump drag, and an 8-step interpolated drag — all on the same verified control:

| check | result |
|---|---|
| `SetCursorPos` / `GetPhysicalCursorPos` after the call | `1872,1413` = expected, error 0 |
| `WindowFromPoint(target)` | `FLUTTERVIEW`, root = the app window |
| top-level window owning the point | the app window (not an overlay) |
| `SendInput` return value | accepted = event count, `time=0` |
| pixel probe around the target | mean luminance 248.6 (the switch card is really there) |
| switch state after each trial | **unchanged in all 7** |
| positive control, same window, same session | clicking `设置` switched the page immediately |

So: coordinates, foreground, hit-testing and delivery were each independently verified, and the
widget still ignored every gesture. When a control refuses synthetic input: try keyboard navigation
(`tab` then `space`), and if that fails, hand that one click to the user rather than grinding. Do not
report "the app is broken" — report which control ignored which gesture.

**`SetForegroundWindow` is not reliable here, and a failed raise looks exactly like a broken
control.** One full matrix run produced seven plausible-looking "no change" results that were all
worthless: the probe's own log showed `class=Chrome_RenderWidgetHostHWND; root=66594` — the 宿主
window, not the target — i.e. the point belonged to another window the whole time. Before sending
input, assert **both**: `GetForegroundWindow() -eq $h` **and** `GetAncestor(WindowFromPoint(pt),2)
-eq $h`. A luminance probe alone is not enough — a window that does not fill the screen can be
covered by something equally bright. Also note `focus -Hwnd` can return success while the raise
silently failed.

Clicking through UIA is verified: invoking Explorer's maximize changed the window rect from
`1808,944,1993,1122` to `-12,-12,3864,2114`, and invoking it again restored the exact original rect.

## Safety rules

- **Verify the foreground window before typing.** Typing goes wherever focus is, including the
  user's chat box. Gate it:
  ```powershell
  & powershell -NoProfile -ExecutionPolicy Bypass -File $cu focus -Title "记事本"
  if ($LASTEXITCODE -ne 0) { throw 'focus failed - aborting' }
  $fg = (& powershell -NoProfile -ExecutionPolicy Bypass -File $cu info | Out-String)
  if ($fg -notmatch '记事本') { throw "foreground is not the target - aborting: $fg" }
  ```
- **Re-focus and re-verify before EVERY typing burst, not once per run.** Focus really does wander
  back to the harness window here between tool calls — measured mid-session: a `ctrl+l` plus a
  99-character URL meant for Edge went nowhere because the 宿主 window had become foreground, even
  though Edge had been foreground a minute earlier. Nothing was damaged only because the harness
  chat box happened to be empty. So `focus -Hwnd` → verify → then type, every single time.
  `<kbd>ctrl+1</kbd>`…`<kbd>ctrl+9</kbd>` are also unreliable for switching Edge tabs here.
- **Know what the UIA tree does NOT contain.** Measured on Edge: the page content is fully exposed,
  but the browser chrome — tab strip, address bar, toolbar — is not, so `uia find -Name "<tab title>"`
  returns a `0x0` element with an empty name and cannot be clicked. Reach a tab with a coordinate
  click read off a region capture, or just navigate in the current tab.
- **Transient UI has to be driven inside ONE tool call.** The Start menu, a dropdown, a context
  menu, a hover panel: all of them are dismissed the moment focus moves, and focus here really does
  move between tool calls because the harness window takes it back. Measured: `click` on Start
  followed by `type "notepad"` in the *next* call produced nothing, twice — the menu was already
  gone, while `info` still cheerfully reported `foreground : 搜索`. So open-search-and-type must be
  one call: `click start` → `sleep` → `type` → `sleep` → `shot`. The same applies to a model
  dropdown or any menu you have to open before you can pick from it.
- **Watch out for the window that is not where you think.** A screenshot of the top-left 1500x900
  found no Start menu at all, and the reasonable-looking conclusion was "the menu never opened" —
  it was open the whole time, in the bottom-left, where Windows 10 puts it. Check the geometry of
  what you are looking for before deciding it is missing.
- **Ask before anything destructive or irreversible**: deleting files, sending messages, submitting
  forms, purchases, closing an app with unsaved work. Approval prompts are off in this profile, so
  nothing will stop you — that is exactly why you must stop yourself.
- **Close what you opened** and leave the desktop as you found it.
- Prefer `key "ctrl+w"` / the app's own close path over killing processes; use `Stop-Process` only
  when a save dialog would block, and say so.
- `type`/`paste` clobber the clipboard (`paste` restores it); `type` does not.

## Environment facts worth remembering

- Shell: **Windows PowerShell 5.1 (Desktop)**. `pwsh` is absent. `-Version 7` syntax fails, and
  `$PSVersionTable.PSEdition` is `Desktop`.
- Execution policy is `Restricted`; do **not** change it machine-wide — pass `-ExecutionPolicy Bypass`
  per call instead.
- `cu.ps1` is deliberately **ASCII-only**: 5.1 reads BOM-less UTF-8 as the ANSI codepage, which
  corrupts non-ASCII source and breaks parsing. Keep it that way; put non-ASCII in arguments, not
  in the file (or save with a BOM).
- Per-call cost: `Add-Type` recompiles the P/Invoke block each run (~1s). Batch several actions into
  one `powershell` launch when latency matters, or accept it.
- **DPI awareness is per-process, and every process in the chain needs it.** `cu.ps1` sets it, but a
  helper script you write does not inherit it, and neither does a `powershell -File` child. A
  DPI-unaware process silently gets **virtual** coordinates: measured here, `GetSystemMetrics(0,0)`
  returned `2194x1234` instead of `3840x2160`, `GetWindowRect` returned `897,273 400x647` instead of
  the physical `1569,478 700x1132`, and `SetCursorPos(2500,900)` **clamped** to `2194,900`. Numbers
  like that look like pointer bugs but are a coordinate-space bug. This trap bit three separate
  scripts in one session. Call `SetProcessDpiAwarenessContext(-4)` (per-monitor V2) at the top of any
  process that computes or clicks coordinates, and print a known physical value to prove it.
- The bundle is watched: editing `SKILL.md` refreshes the catalog, but edits under `scripts/` do not.
- **Editing `cu.ps1`: never assign to a name that matches one of its `param()` names.** PowerShell
  variable names are case-insensitive, so the parameters also exist, *with their declared types*,
  as script-scope variables. `$h` **is** `[int]$H`, `$w` **is** `[int]$W`, `$p` is fine but `$x`,
  `$y`, `$count`, `$text`, `$name`, `$mode`, `$title`, `$path`, `$grid` are not. Assigning a
  non-int to one converts it or dies with a confusing
  `Cannot convert ... to type System.Int32` **attributed to `cu.ps1` rather than the offending
  line**. Both bugs found this way were real:
  - `$w = <object>` in the new `wake` action threw outright (took an instrumented bisect to find);
  - `$h = <hwnd>` hit `[int]$H`, so `place` was passing the **window handle as the height** to
    `MoveWindow` — a 100000-pixel-tall window.
  Use distinct locals at script scope: `$win`, `$report`, `$targetHwnd`, `$hits`. Also note
  `$hits` replaced `$matches`, which shadows the automatic `$Matches` variable.
- **PowerShell array unwrapping bit `uia` twice, in opposite directions — both are now fixed and
  both are easy to reintroduce:**
  - A function that returns `@($rows)` hands back a **scalar** when there is exactly one row, and
    `$scalar.Count` is `$null`. That made `-Index 1` fail with
    `only  match(es) for '*name*', requested -Index 1` — note the empty number in the message,
    which is the tell. A one-match search is the common case, not an edge case.
    Fix: `@(Get-UiaMatches $root)` at every call site.
  - The obvious-looking "fix" `return ,@($rows)` makes it worse when the caller *also* wraps with
    `@()`: the rows end up nested one level deep, every member access turns into array arithmetic,
    and the failure surfaces far away as
    `Method invocation failed because [System.Object[]] does not contain a method named
    'op_Division'` — from the rectangle maths in `Format-Match`. **`@()` at the call site XOR a
    leading comma, never both.**

## The activity chip (progress the user can actually watch)

The user's problem, in their words: when computer-use runs, the harness is behind whatever is
being driven, so they cannot see progress — and raising it covers the window being clicked, while
any mouse movement fights the synthetic pointer. The answer is `scripts/cu-status.ps1`: **one line
of text in a small pill, always on top, that says what is happening right now.**

It is on automatically. Every `cu.ps1` action writes one line to `%TEMP%\cu-status.txt` and the
chip picks it up; the chip starts itself on the first action and needs no `fxon`. A run therefore
looks like `shot · step 4` → `uia find 输入框 · step 5` → `click · step 6`, with a pulsing dot
while busy, a green dot when a step lands, red when one fails, and the colour draining out of the
pill once nothing has happened for a few seconds.

**It cannot disturb a run — this is the whole design, and every line of it is load-bearing:**

| Measure | Why |
|---|---|
| `WS_EX_TRANSPARENT` + `IsHitTestVisible=false` | every click passes straight through to whatever is underneath |
| `WS_EX_NOACTIVATE` + `ShowActivated=false` | never takes focus, so it can never swallow a keystroke |
| `WS_EX_TOOLWINDOW` | no taskbar button, no alt-tab entry |
| `SetWindowDisplayAffinity(WDA_EXCLUDEFROMCAPTURE)` | **visible on screen, invisible to screen capture** |
| topmost re-asserted every ~1 s | the 该 Electron 应用 pet is topmost too and would otherwise cover it |
| one status file, no IPC, no waiting | the chip can be dead and `cu.ps1` still works normally |

### The capture exclusion is the important one, and it costs the translucency

`cu.ps1` screenshots the desktop constantly. Without exclusion the chip would sit inside every
screenshot the agent reads, covering the very pixels it is trying to aim at. With it, the user
sees the chip and the agent's captures show what is behind it — verified: with the chip alive and
its window rect confirmed on screen, a capture of that exact region contained only wallpaper.

**Do not "improve" this by making the window translucent.** Measured with `_dev/probe-wda.ps1`:

| window | `SetWindowDisplayAffinity` |
|---|---|
| `AllowsTransparency=false` (plain) | **True** — works |
| `AllowsTransparency=true` (layered) | **False, error 8** — unsupported |

WPF only gives real per-pixel translucency to a layered window, so it is either a pretty
translucent chip that pollutes every screenshot, or an opaque chip the agent cannot see. The
point of the thing is to not disturb the agent, so it is **opaque**, and the rounded pill shape
comes from `SetWindowRgn` instead. `WDA_EXCLUDEFROMCAPTURE` also does not merely blank the window
to black the way `WDA_MONITOR` would — the region simply is not in the capture.

### Two traps that cost real time here

- **Never create the WPF window with `Visibility=Hidden` and then `ShowDialog()`.** The dialog
  returns immediately, the dispatcher never runs, the timer never ticks once, and the only symptom
  is a chip that never appears with no error anywhere. Position it before showing instead and
  correct it in `Loaded`.
- **`SizeToContent` does not re-measure when the text changes.** The window kept the width it had
  when the text was still the short startup placeholder, so longer messages were cut off
  mid-character. Fixed with an explicit `$win.UpdateLayout()` before re-clipping the region;
  measured afterwards: 4 chars → 133 DIP, 45 chars → 567 DIP, and it shrinks back again.
- **Launch it with `Win32_Process.Create`, not `Start-Process`.** A long-lived child that inherits
  the caller's stdout keeps that pipe open after `cu.ps1` exits, so the caller never sees EOF and
  appears to hang with *no output at all*. `Start-Detached` in `cu.ps1` does this for both the chip
  and the fx overlay.
- **Beware of your own diagnostics.** A cleanup one-liner that greps process command lines for
  `cu-status.ps1` matches the shell running it, kills it, and produces a silent no-output failure
  that looks exactly like a broken launcher. `Test-ChipRunning` now matches `cu-status\.ps1"`
  (with the closing quote) and skips `$PID`.

`scripts/fxkill.cmd` (a copy sits on the Desktop) kills both the overlay and the chip with no
harness and no agent involved.

## The takeover overlay

> **Lifecycle the user asked for, and what this bundle now does.** The overlay marks a takeover,
> and a takeover is exactly as long as computer use is in progress: it appears when the GUI work
> starts, dims to a faint permanent presence instead of vanishing, and is gone by the time the work
> stops. **`fxon` before your first GUI action of the run; `fxoff` the moment the GUI work is done —
> as the last action of the run, before you write your final message.**
>
> **Closing it is automatic and must never be a question.** Do not end a turn that used
> computer use with the overlay still up, and do not ask the user whether to close it — they have
> already told you to: *"when you are not using computer use, turn the overlay off automatically,
> instead of asking me whether to."* Asking is the same failure as leaving fog on their screen.
> The only reasons the overlay outlives a turn are that you are still mid-takeover (another GUI
> step is genuinely coming) or that the user explicitly asked to keep it for a demo.
>
> Do not leave it to a clock — `-DurationSec` defaults to 86400 s purely as a crash backstop. The
> user closing the harness is handled by the watchdog, not by you.
>
> Never re-`fxon` mid-run just because it "looks faint": faint *is* the settled state. Toggling it
> re-runs the 6 s full-strength intro and reads as a flash to the user. Learned the hard way: the
> overlay was muted by every screenshot, so a run of captures made it blink on and off; a `fxoff`
> fired as part of a test batch made the user ask why their effect had disappeared; and a finished
> GUI run left the overlay up because the agent asked instead of closing it.

**Default convention for ordinary work:** switch the overlay on when a run of GUI actions begins
(`fxon` — ambient defaults `-Dim 0.10` / `-DimAfterSec 6`), so the user always knows the machine is
being driven without the fog getting in the way; `fxoff` the moment the run ends. Reserve
`-DimPct 100` for a performance or demo that must stay at full strength throughout.

`fxon` launches `scripts/fx.ps1`: a borderless, topmost, full-screen WPF window that is
**click-through** (`WS_EX_TRANSPARENT`) and `WS_EX_NOACTIVATE`, so it never blocks the mouse and
never takes focus. Black fog creeps in from all four edges and a glowing headline sits at the top.

Turn it on when you start a run of GUI actions and off when you finish, so the user can see that the
machine is being driven:

```powershell
& powershell -NoProfile -ExecutionPolicy Bypass -File $cu fxon
# ... do the work ...
& powershell -NoProfile -ExecutionPolicy Bypass -File $cu fxoff
```

- The headline lives in `scripts/fx-text.txt` (UTF-8) and the Latin subtitle in
  `scripts/fx-subtext.txt`. Edit those files, not the script: `fx.ps1` is ASCII-only on purpose, so
  non-ASCII text must stay outside it.
- **Getting a gothic look with Chinese text:** a real Fraktur/blackletter face carries no CJK glyphs,
  so the gothic flavour rides on a Latin subtitle while the Chinese headline uses a heavy serif. The
  scripts ship three loose font files (used straight from disk, nothing is installed):
  `UnifrakturCook-Bold.ttf` (authentic, readable — the default), `UnifrakturMaguntia-Book.ttf` (very
  ornate, harder to read), `GrenzeGotisch.ttf` (gothic-flavoured display face with named weights).
  WPF loads them as `file:///C:/path/font.ttf#FamilyName`; `-SubFont` overrides.
- `-Font` selects the CJK headline family. The default `Source Han Serif SC Heavy` is the closest
  installed face to a dark-fantasy poster look. **Check that a face exists before using it** —
  measured here: `Kingsoft UE` renders CJK as tofu boxes, while `Gabriola`, `Impact` and `Bahnschrift`
  carry no CJK glyphs at all and silently fall back.
- `-Accent` (default `#3FA9F5`) sets the glow colour.
- **Failsafes — the overlay must never strand fog on the user's screen.** Both are tested:
  - *Watchdog:* `fxon` passes `-WatchPid` (the harness process) to `fx.ps1`, which polls it and fades
    itself out when that process disappears — so closing the harness that owns the takeover also ends
    the takeover. Measured: overlay gone **1.6 s** after the watched process died.
  - *Kill switch:* `scripts/fxkill.cmd` (a copy sits on the Desktop) kills every `fx.ps1` process and
    clears the state files with no harness and no agent involved. Use it if fog is ever stuck.
- **Ambient mode.** The overlay plays at full strength, then after `-DimAfterSec` (default 6) it eases
  down to `-Dim` (default 0.10) and stays there as a faint, permanent presence rather than
  disappearing — so the user can always tell the machine is being driven. `-DimPct 100` keeps it at
  full strength for the whole run.
- **Measured fade curve, and why `-Dim` is 0.10.** Probes on this desktop (corner 120,120 / title
  1920,140 / edge 60,1080 / bottom 1920,2080), overlay off → full-strength peak → settled ambient:

  | probe | overlay off | full strength | ambient 10% | full-strength drop |
  |---|---|---|---|---|
  | corner | 87.7 | 6.7 | 79.8 | -92% |
  | title | 139.3 | 10.6 | 127.2 | -92% |
  | edge-left | 39.4 | 6.0 | ~35 | -85% |
  | bottom | 14.2 | 2.2 | ~13 | -85% |

  The curve rises to the peak by t≈2 s, holds to t≈6 s, then eases out by t≈7.5 s and is **flat
  afterwards** — that flatness is the guarantee that nothing (a capture included) is interrupting it.
  `-Dim` was 0.25, which cost -22% on the edge and -23% on the title — visible in every screenshot.
  Swept: 25% → -22%, 15% → -13%, **10% → -9%**, 6% → -5%. 10% is the knee: the effect is still
  plainly there, a white window area loses only 2.4% (255 → 249), and the desktop edges stop looking
  polluted in captures. Lower is possible via `-DimPct`; do not go much below 6% or the effect stops
  being visible at all.
- **`shot` does NOT touch the overlay.** It used to write `%TEMP%\cu-fx.mute`, which `fx.ps1` polled
  to fade the overlay to 0 for the duration of a capture and back afterwards; that made the effect
  blink on every screenshot — more disruptive than the fog it avoided, and it broke the "the effect
  stays up while the machine is being driven" promise. The capture now simply contains the overlay.
  `-KeepFx` is retained as a no-op for compatibility. If you ever need a pixel-exact capture of the
  screen edges, the tool is not the problem: `fxoff` for that measurement and `fxon` after.
- The headline uses a white→pale-cyan vertical gradient fill, and a soft dark halo sits behind the
  title block so both lines stay legible over a light app. Fog depth is tuned so the middle of the
  screen stays clean. **The older numbers in this file (corner 237 → 42, title 250 → 77, "centre
  248 → 248", ambient 194) do not reproduce on this desktop** — they were recorded against a
  different wallpaper/window layout. Re-measure with the probe set above rather than trusting them.
  What does hold: the fog is an edge phenomenon, and a probe in the middle of a lit window barely
  moves (255 → 249 at ambient).
- Per-character `TextBlock`s supply the wide tracking and the staggered reveal, because WPF has no
  letter-spacing property.

## Recipes

**Click a button by name**
```powershell
& powershell -NoProfile -ExecutionPolicy Bypass -File $cu uia -Mode find -Name "新会话"
& powershell -NoProfile -ExecutionPolicy Bypass -File $cu uia -Mode click -Name "新会话"
```

**Read what a window says**
```powershell
& powershell -NoProfile -ExecutionPolicy Bypass -File $cu shot -Title "记事本" -Path "$env:TEMP\w.png"
# then read the PNG with the image reader
```

**Fill a field and submit**
```powershell
& powershell -NoProfile -ExecutionPolicy Bypass -File $cu uia -Mode settext -Name "搜索" -Text "agent"
& powershell -NoProfile -ExecutionPolicy Bypass -File $cu key -Keys "enter"
```
