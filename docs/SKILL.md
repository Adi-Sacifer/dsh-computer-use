---
name: computer-use
description: Operate the Windows desktop when a task requires GUI interaction. Prefer the target product's available MCP tools; use the persistent CU MCP for screenshots, UI Automation, mouse and keyboard when GUI fallback is needed.
whenToUse: A task involves operating an application or seeing the desktop. Check available application MCP tools first, then use CU only for the remaining GUI work.
---

# Windows computer use

## Tool routing

1. For software, websites and services, use the relevant available **application MCP** when it supports the requested operation. Check its actual tools before falling back; do not invent a missing connector.
2. For GUI work, call **`mcp__cu__cu` directly**. This is a persistent MCP server: consecutive calls reuse the same PowerShell process and return screenshots as image blocks.
3. Do not run `powershell`, `pwsh`, `cu.cmd`, or `cu-batch.mjs` for each screenshot/action when the MCP tool is available. Do not open a terminal window to take screenshots.
4. If CU MCP is missing, report that the plugin is unavailable and inspect its registration/connection first. `mcp/cu-batch.mjs` is a hidden-process fallback for one complete batch only; it is not the ordinary route and does not retain a session between batches.

## Automatic session and progress

- Call `{"action":"start"}` when beginning GUI work. Ordinary CU actions also start a session automatically. This starts the edge effect and bottom progress pill together.
- The edge effect begins at full strength, fades after **6 seconds** to **10%**, and remains faint while CU is active. Repeated `start`/`fxon` calls are idempotent. Screenshots never stop, hide or restart it.
- Use `{"action":"status","text":"正在检查导出结果（第 2/3 步）","state":"busy"}` to show a real task phase. Report known steps, not invented percentages. Each action automatically updates the pill; the host shows when the model is preparing the next step.
- Call `{"action":"stop"}` as soon as GUI work finishes, fails or is cancelled, before the final response. It closes **both** effect and pill. `status` with `state:"done"` also closes both. No extra user confirmation is needed.
- The host lifecycle hook additionally closes them when the owning task becomes idle or is disposed. Server disconnect/crash also closes them. Neither MCP startup nor tool discovery starts the visual effect.
- `{"action":"fxstatus","json":true}` is a read-only probe returning `active`, `on`, `pill`, PIDs and session ID. It never opens the pill.
- `fxon`/`fxoff` remain aliases for `start`/`stop`. A different task must not take over the desktop while the current task owns it.

## Observe, act, verify

Use the tool's argument schema. Common calls:

```json
{"action":"windows","json":true}
{"action":"focus","hwnd":12345}
{"action":"uia","hwnd":12345,"mode":"find","name":"保存"}
{"action":"uia","hwnd":12345,"mode":"click","name":"保存"}
{"action":"shot"}
{"action":"key","keys":"ctrl+s","expect":"目标窗口标题"}
```

- Inspect a screenshot or UI state before acting, then verify the result.
- Prefer UIA control names and exact rectangles over coordinate estimation. `uia` automatically wakes Chromium/Electron accessibility. Use a window handle from `windows`; title substrings can match several windows.
- Coordinates are physical screen pixels. The MCP image may be downscaled; do not use preview pixels as screen coordinates. Use UIA, `shot` with `grid`, or a small crop (`x,y,w,h`).
- Check foreground focus before input. Use `expect` on click/key/type/paste/drag/scroll; a mismatch injects nothing and returns an error. Stop a dependent sequence after failure.
- Pass Chinese strings directly as JSON. Do not route them through cmd.exe quoting.
- `shot` returns an image even when `path` is omitted. With a provided path, use an absolute PNG path.
- `status` states are `busy`, `note`, `ok`, `err`, `done`. The pill stays present for the whole active session, including long model/API waits.

The scripts live in `scripts/`; the MCP server and lifecycle hook are installed under `~/.dsh/mcp/`. See `references/legacy-diagnostics.md` only for detailed DPI, focus and UIA diagnostics. Its older per-call launch and overlay lifetime recipes are historical; use the lifecycle and routing above.
