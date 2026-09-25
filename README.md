# cu-windows — give an LLM agent real eyes and hands on Windows

A **single-file PowerShell toolkit** that lets an AI agent drive a Windows desktop: screenshot the
screen, find a control, click it, type into it, and *verify it worked*. No Python, no Node, no
installer, no dependencies beyond what ships with Windows.

```
scripts/cu.ps1    ~1200 lines, ASCII-only, PowerShell 5.1
```

**[中文说明 / Chinese README](README.zh-CN.md)**

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
