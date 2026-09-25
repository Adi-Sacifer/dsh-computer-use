# cu-windows — give an LLM agent real eyes and hands on Windows

Current routing: prefer the application's own MCP tools, then the persistent `mcp__cu__cu` tool
for desktop work. A CU session owns both the six-second edge effect and the progress pill, and
closes them on `stop`, task completion and cancellation. See [current usage](docs/SKILL.md) and
[changes](CHANGELOG.md).

A **single-file PowerShell toolkit** that lets an AI agent drive a Windows desktop: screenshot the
screen, find a control, click it, type into it, and *verify it worked*. No Python, no Node, no
installer, no dependencies beyond what ships with Windows.

```
scripts/cu.ps1    ~1200 lines, ASCII-only, PowerShell 5.1
```

**[中文说明 / Chinese README](README.zh-CN.md)** · **[Changelog](CHANGELOG.md)**

---

## Why another one

Most desktop-automation snippets fail the same way: they click, nothing happens, and neither the
agent nor the human can tell whether the coordinates were wrong, the window moved, or the control
simply ignored the input. This toolkit was built by driving a real machine for days and fixing
every one of those failures at the root. Two of the findings are, as far as I can tell, not widely
written down:

### 1. Chromium and Electron apps expose no accessibility tree — until you wake it

Any web page in Chrome or Edge, VS Code, Slack, Discord, and every Electron desktop app keeps its
accessibility engine **switched off** until something asks for an accessibility object. Until then
a UI Automation query returns almost nothing, so the agent gives up on UIA and falls back to
eyeballing a downscaled screenshot — which is how clicks land on the neighbouring button.

`cu.ps1` sends `WM_GETOBJECT` / `OBJID_CLIENT` to the window and its children — exactly what a
screen reader does on startup — then polls until the tree stops growing.

Measured, on a plain Electron window:

| | before wake | after wake |
|---|---|---|
| UIA nodes | 13 (4 named, no useful rects) | **158 (140 named, every one with a real rectangle)** |

That turns "guess the coordinates from a screenshot" into `uia -Mode find -Name "Save"`, which
prints the element's exact rectangle *and* the exact pixel to click. In a browser it means real DOM
elements: `Button | Start game | 1690,1290 462x141`, `Edit | Message | 2376,1596 1247x77`.

### 2. Synthetic mouse *movement* can be what breaks the click

A click is not `down`+`up` where you think it is. Measured: sending `MOUSEEVENTF_MOVE` to position
the pointer, then `down`/`up`, is **rejected** by some app frameworks — while the identical
`down`/`up` after the pointer was moved by a *physical* mouse is accepted.

`cu.ps1` therefore positions the cursor with `SetCursorPos` (a real cursor move) and sends **no
synthetic movement events at all**.

---

## What you get

| | |
|---|---|
| **See** | full screen / region / single-window screenshots, with an optional labelled coordinate grid where **every** gridline is numbered |
| **Find** | UI Automation tree, ranked name search returning exact rectangles, on-screen flags and the click point; works on native apps, Flutter (partially), and Chromium/Electron/web **after the wake-up** |
| **Act** | click, double-click, drag, scroll, Unicode-safe typing (CJK/emoji), clipboard paste, key chords, window focus/move/show |
| **Verify** | every click reports **which window ended up under the point**; refuses to click outside the desktop; warns when `SendInput` was blocked (UIPI / elevated target); warns when a point is over a different element than intended |
| **Progress** | a tiny always-on-top activity chip that shows what the agent is doing right now — click-through, never steals focus, and **invisible to screen capture** |
| **Overlay** | an optional full-screen "takeover in progress" effect, also click-through and non-activating |

## Requirements

- Windows 10 (build 19041+) or Windows 11
- Windows PowerShell 5.1 (the one that ships with Windows — no PowerShell 7 needed)
- Nothing else. No Python, no Node, no packages.

## Quick start

```powershell
# 1. put the scripts somewhere
#    e.g. C:\tools\cu\scripts\

# 2. take a look
powershell -NoProfile -ExecutionPolicy Bypass -File C:\tools\cu\scripts\cu.ps1 info

# 3. find a control by name and click it
powershell -NoProfile -ExecutionPolicy Bypass -File C:\tools\cu\scripts\cu.ps1 uia -Mode find -Name "Save"
powershell -NoProfile -ExecutionPolicy Bypass -File C:\tools\cu\scripts\cu.ps1 uia -Mode click -Name "Save"

# 4. if the tree looks empty, wake it and look again
powershell -NoProfile -ExecutionPolicy Bypass -File C:\tools\cu\scripts\cu.ps1 wake -Hwnd 123456
```

Typical output:

```
$ cu.ps1 uia -Mode find -Name "Message" -Hwnd 460604
a11y     : woke 2 hwnd(s), tree 12 -> 107 nodes in 680 ms
[1] Edit           | Message       | 2376,1596 1247x77 | onScreen=True | click 3000,1634
[2] Text           | Message       | 2376,1597  99x32  | onScreen=True | click 2426,1613
NEXT: 'uia -Mode click -Name "Message" -Index <n>' acts on match [n]; the 'click x,y' on each line is the exact point.
```

## Using it as an agent skill

`docs/SKILL.md` is written to be loaded straight into an agent's context as a skill — it carries
the front-matter, the action table, the safety rules, and the measured findings. Drop `docs/SKILL.md`
plus `scripts/` into your agent's skill directory and it works as-is.

## The activity chip

A one-line pill, bottom-centre, always on top, click-through, and it never takes focus. It says
what the agent is doing right now (`uia find Message · step 12`), pulses while busy, turns green on
success, red on failure, and fades when idle.

**It is also excluded from screen capture** (`SetWindowDisplayAffinity(WDA_EXCLUDEFROMCAPTURE)`), so
the human sees it and the agent's own screenshots do not — which matters, because the agent is
taking screenshots constantly and a visible indicator would sit inside every one of them.

That exclusion is why the chip is **opaque rather than translucent**: Windows refuses
`SetWindowDisplayAffinity` on layered windows (measured: `error 8`), and WPF only gives real
per-pixel transparency to a layered window. Rounded shape comes from a window region instead. The
trade-off is documented in the source so nobody "improves" it back into a bug.

## Making the overlay say your thing

The takeover overlay's two lines of text live in **plain UTF-8 files**, not in the script. Edit
them, restart the overlay, done:

| File | What it is | Ships as |
|---|---|---|
| `scripts/fx-text.txt` | the big glowing headline | `the machine is being driven` |
| `scripts/fx-subtext.txt` | the small blackletter line under it | `COMPUTER USE` |

```powershell
# 1. write whatever you want - the file is read as UTF-8 explicitly
Set-Content scripts\fx-text.txt    'MACHINE UNDER REMOTE CONTROL' -Encoding UTF8 -NoNewline
Set-Content scripts\fx-subtext.txt 'THE AGENT IS DRIVING' -Encoding UTF8 -NoNewline

# 2. restart the overlay (fxon replaces any running instance)
cu.ps1 fxoff
cu.ps1 fxon
```

Any language works, including CJK and emoji. If a file is missing or empty, the overlay falls
back to the built-in English default rather than showing nothing.

> **Why text lives in files and not in a parameter.** `fx.ps1` is deliberately ASCII-only:
> PowerShell 5.1 reads a BOM-less UTF-8 `.ps1` as the ANSI codepage, which corrupts non-ASCII
> source and breaks parsing. Non-ASCII also survives a command line badly — the shell can
> re-encode it before the script ever sees it. So the script stays ASCII and the words live in
> UTF-8 data files. Save those files as **UTF-8**; saving as ANSI/GBK will show up as mojibake.

### The rest of the look

These go through `fxon`:

```powershell
cu.ps1 fxon -Font "Source Han Serif SC Heavy"   # CJK headline family
cu.ps1 fxon -SubFont "Impact"                   # Latin subtitle family
cu.ps1 fxon -Accent "#FF6B6B"                   # glow colour
cu.ps1 fxon -DimPct 100                         # stay at full strength, never fade
cu.ps1 fxon -DimAfter 6                         # seconds before easing to ambient
```

Two face-selection traps worth knowing, both measured:

- A real blackletter face (**UnifrakturCook**, **UnifrakturMaguntia** — both bundled here) carries
  **no CJK glyphs**. That is why the gothic flavour rides on the Latin subtitle while the headline
  uses a CJK serif. Check that a face exists before using it: `Kingsoft UE` rendered CJK as tofu
  boxes, and `Gabriola` / `Impact` / `Bahnschrift` have no CJK at all and fall back silently.
- `-SubFont` also accepts a font straight off disk, with no installation:
  `file:///C:/path/font.ttf#FamilyName`.

Rather than passing flags every time, just edit the defaults at the top of `scripts/fx.ps1`
(`$Font`, `$Accent`, and so on) — or point `-TextFile` / `-SubTextFile` somewhere else entirely.

### If the overlay ever gets stuck

Double-click **`scripts/fxkill.cmd`**. It kills the overlay and the activity chip, and clears
their state files. It needs no agent, no host application and no terminal — it just works.

```
Killing overlay/chip process 12345
Done. Overlay/chip processes killed: 1
```

This exists because a full-screen always-on-top window with nobody left to dismiss it is the
worst possible failure mode for a tool like this. Both helpers also watch the host application's
process and take themselves down when it exits (`-WatchTitle`), and both are click-through, so
neither can ever block a click even while it is up. The kill switch is the third layer, for the
case where all of that fails.

## One warm process: the MCP server and the batch driver

Every `pwsh -File scripts\cu.ps1 <action>` costs **~2.4 s**, and almost none of it is the action: it
is process start plus the `Add-Type` compile of the P/Invoke block, paid again on every single call.
A four-step turn therefore spends ten seconds doing nothing.

`mcp/cu-mcp.ps1` is a small **MCP (stdio) server** that keeps **one warm PowerShell process** instead.
It loads `cu.ps1` once and from then on re-invokes *that same script* in-process — same file, same
behaviour — and PowerShell 7 caches the identical `Add-Type` after the first call (786 ms, then
~3 ms).

| one action | cost |
|---|---|
| fresh `pwsh -File cu.ps1 <action>` | ~2400 ms |
| through the warm server | **~90–150 ms** |

### Registering it as an MCP server

`-CuPath` is the toolkit to wrap — point it at your own `cu.ps1`. Then register the server in the
host config; seen from the model the tool is named `cu` (in this harness, `mcp__cu__cu`):

```yaml
- id: mcp-cu
  name: "@deepseek-ai/dsh-mcp-client"
  config:
    serverName: cu
    transport: stdio
    command: 'C:\Users\Administrator\AppData\Local\Microsoft\WindowsApps\pwsh.exe'
    args:
      - '-NoProfile'
      - '-ExecutionPolicy'
      - 'Bypass'
      - '-File'
      - 'C:\Users\Administrator\.dsh\mcp\cu-mcp.ps1'
    toolCallTimeoutMs: 120000
    failOnStartupError: false
```

The tool takes the same arguments as `cu.ps1` — `action` plus `x`, `y`, `keys`, `mode`, `name`,
`path`, `json` and so on — and `action: shot` also returns the screenshot as an MCP image block.
`expect` is mapped too, so a plan can carry the foreground guard with each input action
(`{"action":"key","keys":"enter","expect":"Slay the Spire 2"}`): if the named window is not in
front, that step refuses and says so instead of typing into whatever is.

### The batch driver

`mcp/cu-batch.mjs` goes one step further: it boots that server **once** and feeds it a whole **plan**
from stdin — a JSON array of cu actions — printing one line per step. A turn that needs
"look, find, click, look" becomes a single process launch:

```powershell
@'
[{"action":"shot","path":"C:\\tmp\\s1.png"},
 {"action":"uia","mode":"find","name":"Save"},
 {"action":"click","x":3419,"y":1754},
 {"action":"shot","path":"C:\\tmp\\s2.png"}]
'@ | node C:\Users\Administrator\.dsh\mcp\cu-batch.mjs
```

```
[0] shot 148ms :: C:\tmp\s1.png  3840x2160  1284 KB
[1] uia 121ms :: a11y : woke 1 hwnd(s), tree 12 -> 107 nodes in 680 ms [1] Button | Save | 3419,1754 126x48 | onScreen=True | click 3482,1778
[2] click 131ms :: left click x1 at 3419,1754 over 'Untitled - Notepad'
[3] shot 142ms :: C:\tmp\s2.png  3840x2160  1290 KB
batch done in 1904 ms (4 actions + server boot)
```

**The takeover overlay now follows the batch by itself**: the driver turns it **on as its first
action and off as its last one**, so the effect tracks the automation instead of having to be
remembered as a separate step. Before switching it on it asks `cu fxstatus -Json` whether the overlay
is already up — `fxon` always starts a *fresh* overlay, which replays the 6 s intro and reads as a
flash, so a running one is left alone. (That probe needs a toolkit build that has `fxstatus`.)

| flag | effect |
|---|---|
| *(none)* | overlay on for the batch, off after it; left alone if it was already up |
| `--no-fx` | never touch the overlay |
| `--keep-fx` | turn it on if needed, and leave it up when the batch ends |
| `--fx-text "<headline>"` | headline for this batch — see the note below |

> **`--fx-text` reaches the overlay.** The driver passes the headline to `fxon`, which forwards it
> to `fx.ps1 -Text` — so the words change for that batch without touching
> `scripts/fx-text.txt` (which stays the default, and is still how you set the headline
> permanently). Non-ASCII headlines work: the MCP server decodes its input as UTF-8, a bug that
> used to turn a CJK headline into mojibake and a request that never returned.

### Asking whether the overlay is up

`fxstatus` reports the overlay's state and changes nothing — the answer to "is it already up?":

```powershell
cu.ps1 fxstatus          # fx on - overlay pid 12345   /   fx off (nothing is running)
cu.ps1 fxstatus -Json    # {"on":true,"pid":12345}
```

The pid file alone is only a hint (it can go stale), so the process is checked for real before `on`
is reported. `-Json` is the form the batch driver parses.

> **Both scripts are tailored to this machine — a worked example, not a package.** They carry
> absolute paths and assume this box: `cu-mcp.ps1` defaults `-CuPath` to
> `C:\Users\Administrator\.dsh\skills\computer-use\scripts\cu.ps1` and logs next to itself, and
> `cu-batch.mjs` spawns `C:\Users\Administrator\.dsh\mcp\cu-mcp.ps1` with the Store-aliased
> `pwsh.exe` under `%LOCALAPPDATA%\Microsoft\WindowsApps`. `mcp/` in this repo holds byte-identical
> copies of both files; copy them out and edit those paths before reusing them anywhere else.

## Diagnostics

`diagnostics/` holds the minimal repro scripts used to establish the findings above — an
accessibility wake probe, a display-affinity probe, a sizing probe, and two two-line PowerShell
repros for language traps that cost real debugging time. They are small, self-contained, and each
prints what it measured.

## Known limits

- `uia` on **Flutter** apps exposes a single `FLUTTERVIEW` pane; some Flutter widgets (notably
  custom pill switches) ignore synthetic pointer input entirely. Keyboard navigation is the way in.
- UIA rects are physical pixels. Every process in your chain must be DPI-aware, or coordinates are
  silently scaled — `cu.ps1` sets per-monitor-V2 awareness itself, but a helper script you write
  does not inherit it.
- Browser *chrome* (tab strip, address bar) is not in the accessibility tree; only page content is.

## License

MIT — see [LICENSE](LICENSE).

The two bundled blackletter fonts are from [Google Fonts](https://fonts.google.com/) and are
licensed under the SIL Open Font License 1.1; see `scripts/fonts/`. Delete the folder if you do not
want them — the overlay falls back to a system font.
