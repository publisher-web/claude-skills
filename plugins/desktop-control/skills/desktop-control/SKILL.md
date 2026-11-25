---
name: desktop-control
description: Windowsの画面を見て操作する（窓の切り替え・ボタン一覧・文字で探してクリック・文字入力・キー・スクショ・画面の文字読み取り）。「画面を見て」「クリックして」「デスクトップを操作して」と言われたとき、またはGUIアプリの操作が必要でMCP等の手段がないときに使う。
---

# desktop-control

`dsk` = `desk.ps1` in this skill's folder (the base directory shown when the skill loads).
If `dsk` is on PATH (see the repo's install.ps1), call `dsk ...` from PowerShell (fast, preferred) or Bash.
Otherwise call it by full path: PowerShell `& "<skill dir>\desk.ps1" ...`; Bash or a restricted execution policy: `powershell -NoProfile -ExecutionPolicy Bypass -File "<skill dir>\desk.ps1" ...`.
Below, `dsk` means whichever form works.
One call can run several steps; it stops at the first error: `dsk "focus Studio; clickt 保存; changed 500"`

## Save tokens (images are the expensive part)
Text output ≈ 20–300 tokens. `shot` (1366x768) ≈ 1,400, `shot -w 800` ≈ 500, `shot win` = window size, `zoom` 300x150 ≈ 60.
1. GUI is the last resort: use MCP / CLI / files / settings when possible.
2. Work by text: `wins` → `focus` → `ui` or `find` → `clickt` / `click #n` → check with `ui <filter>` or `changed`.
3. `shot` only for unfamiliar or graphical screens (game view, canvas, unnamed icons). Prefer `shot win`, `-w 800`, or `zoom` on a small area. Don't re-shoot to verify; use `changed` / `ui` / `zoom`.
4. Batch steps in one call. Reuse coordinates while the screen is unchanged.

## Coordinates
X Y = pixels of the **last shot image** (the frame). `ui`/`find`/`ocr`/`changed` print coords in that frame, ready for `click`. `#n` = element number from the last `ui` or `shot -marks`. `focus` moves the frame to the window's monitor when the window is outside it. Clicks outside the frame are refused. Multi-monitor and mixed DPI are handled.

## Commands
- `shot [mon|win|all|N] [-w W] [-grid] [-marks] [-pw]` → `%TEMP%\claude-desk\shot.png` (then Read it). mon = monitor of the foreground window. `-marks` boxes+numbers clickable elements. `-pw` for windows that capture black.
- `zoom X Y W H [2] [-grid]` → `zoom.png` at real resolution (2 = double) for small text; prints the mapping back to the frame.
- `changed [ms]` → changed areas since the last shot/changed (waits up to ms for a change). `color X Y` → #RRGGBB.
- `wins [q]` windows front-to-back (`*` foreground, `(Claude Code)` = this session's window). `mon` monitors.
- `ui [filter] [-all] [-n N]` → `#3 btn "保存" @x,y`; edits show `="value"`, toggles `[on]/[off]`, `[sel]`, `[disabled]`.
- `find "text" [-ui|-ocr]` → UI Automation names first, OCR if needed. `ocr [X Y W H] [-en]` → text lines with positions.
- `waitfor "text" [sec] [-gone]` → wait until text appears / disappears.
- `focus "title|process" [max]` → errors if the window can't be brought to front.
- `click X Y|#n [right|double|middle]` (`rclick`, `dclick`) → prints what was hit: `-> btn "保存" in "Roblox Studio"`.
- `clickt "text" [n] [right|double]` → find + click. Ties and partial matches (e.g. "Clear" in "cleared") are listed, not clicked; add n.
- `type "text" [enter] [-k]` → paste (clipboard restored); `-k` sends key events where paste is blocked.
- `key ctrl+s` / `key "tab tab enter"` / `key w:800` (hold ms). `keys "{ESC}"` = old SendKeys syntax.
- `move X Y`, `drag X1 Y1 X2 Y2`, `scroll X Y N [h]` (N<0 = down), `wait ms`, `help`.

## Safety
- Keys/typing are refused if the foreground is Claude Code's own window, or if it changed since the last focus/click/type (someone else used the PC). Re-`focus`; use `-f` only when sure.
- OCR ignores text inside Claude Code's window.
- Ask the user before irreversible actions (buy, send, delete, publish, passwords).

## Notes
- OCR languages: Japanese + English (en-US). ASCII-only searches use English automatically; use `ocr -en` to read an English screen. (On another PC without the English pack: `Add-WindowsCapability -Online -Name Language.OCR~~~en-US~0.0.1.0` as admin.)
- `desk.ps1` must stay UTF-8 **with BOM** (PowerShell 5.1). `DeskNative.cs` is C# 5 and recompiles automatically when changed (cache: `%LOCALAPPDATA%\claude-desk`). Don't edit and run in the same parallel batch.
- The first run compiles (~5 s). Full-monitor OCR can take seconds; narrow it with `focus` + `shot win` or a region.
