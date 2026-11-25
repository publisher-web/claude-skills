# desk.ps1 — Claude Code から Windows の画面を見る・操作する道具（使い方は同じフォルダの SKILL.md）
#   desk <命令> [引数...]          1つ実行
#   desk "命令 引数; 命令 引数"     ; で区切ってまとめて実行（失敗したらそこで止まる）
# 座標は「最後に撮った shot の画像」上のピクセル（= フレーム）。ui / find / ocr の答えも同じ座標で出す。
# ※ BOM付き UTF-8 で保存すること（PowerShell 5.1 が日本語のコメントを読み違えて行を壊すため）
$ErrorActionPreference = 'Stop'
if ($env:DESK_UTF8) { try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch {} }

$Tmp = Join-Path $env:TEMP 'claude-desk'
[void](New-Item -ItemType Directory -Force $Tmp)
$StateFile = Join-Path $Tmp 'state.json'
$BasePng = Join-Path $Tmp 'base.bmp'   # changed で比べる元の画像（速さ優先で BMP）
$Inv = [Globalization.CultureInfo]::InvariantCulture

# ---- C# の部品（DeskNative.cs）を読み込む。初回だけコンパイルして DLL を使い回す（.cs を変えると自動で作り直す）
Add-Type -AssemblyName System.Drawing
if (-not ('Desk.N' -as [type])) {
  $dllDir = Join-Path $env:LOCALAPPDATA 'claude-desk'
  [void](New-Item -ItemType Directory -Force $dllDir)
  # COM 版 UI Automation の型（Windows に入っている UIAutomationCore.dll の型情報から一度だけ作る）
  $interop = Join-Path $dllDir 'Interop.UIAutomationClient.dll'
  if (-not (Test-Path $interop)) {
    Add-Type -TypeDefinition @'
using System; using System.Reflection; using System.Runtime.InteropServices; using System.Runtime.InteropServices.ComTypes;
public class DeskTlb : ITypeLibImporterNotifySink {
  [DllImport("oleaut32.dll", CharSet = CharSet.Unicode)] static extern int LoadTypeLibEx(string f, int k, out ITypeLib t);
  public static void Make(string path) {
    ITypeLib tl; Marshal.ThrowExceptionForHR(LoadTypeLibEx("UIAutomationCore.dll", 2, out tl));
    var ab = new TypeLibConverter().ConvertTypeLibToAssembly(tl, path, TypeLibImporterFlags.None, new DeskTlb(), null, null, "Interop.UIAutomationClient", null);
    ab.Save(System.IO.Path.GetFileName(path));
  }
  public void ReportEvent(ImporterEventKind k, int c, string m) { }
  public Assembly ResolveRef(object t) { return null; }
}
'@
    Push-Location $dllDir; try { [DeskTlb]::Make($interop) } finally { Pop-Location }
  }
  Add-Type -Path $interop
  $cs = Get-Item (Join-Path $PSScriptRoot 'DeskNative.cs')
  $dll = Join-Path $dllDir ('DeskNative-{0:x}-{1}.dll' -f $cs.LastWriteTimeUtc.Ticks, $cs.Length)
  if (-not (Test-Path $dll)) {
    $cp = New-Object CodeDom.Compiler.CompilerParameters
    $cp.CompilerOptions = '/optimize+'; $cp.OutputAssembly = $dll; $cp.GenerateInMemory = $false
    foreach ($ref in 'System.dll', 'System.Core.dll', ([Drawing.Bitmap].Assembly.Location), $interop) { [void]$cp.ReferencedAssemblies.Add($ref) }
    Add-Type -TypeDefinition ([IO.File]::ReadAllText($cs.FullName)) -CompilerParameters $cp
    Get-ChildItem $dllDir -Filter 'DeskNative-*.dll' | Where-Object { $_.FullName -ne $dll } | ForEach-Object { try { Remove-Item $_.FullName -Force -ErrorAction Stop } catch {} }
  }
  Add-Type -Path $dll
}
[Desk.N]::Init()

# ---- 状態（フレーム・番号つきの部品・最後に操作した窓）
$State = $null
if (Test-Path $StateFile) { try { $State = Get-Content $StateFile -Raw -Encoding UTF8 | ConvertFrom-Json } catch {} }
if (-not $State) { $State = [pscustomobject]@{} }
function Set-State($name, $value) { $State | Add-Member -NotePropertyName $name -NotePropertyValue $value -Force }
function Save-State { $State | ConvertTo-Json -Depth 5 -Compress | Set-Content $StateFile -Encoding UTF8 }

function Short([string]$s, [int]$n) { if ($s.Length -le $n) { $s } else { $s.Substring(0, $n - 1) + '…' } }
function Num([double]$v) { $v.ToString('0.###', $Inv) }
function Norm([string]$s) { if (-not $s) { return '' }; $s.Normalize([Text.NormalizationForm]::FormKC).ToLowerInvariant() -replace '\s+', '' }

# ---- フレーム（撮った画像と画面の実ピクセルの対応）
# Claude の画面操作の学習に合う大きさ（16:9→1366x768、16:10→1280x800、4:3→1024x768）まで縮める
function Fit([int]$w, [int]$h, [int]$maxW) {
  if ($maxW -gt 0) { return [Math]::Min(1.0, $maxW / $w) }
  $ar = $w / $h; $best = $null
  foreach ($t in @(@(1366, 768), @(1280, 800), @(1024, 768))) {
    if (-not $best -or [Math]::Abs($t[0] / $t[1] - $ar) -lt [Math]::Abs($best[0] / $best[1] - $ar)) { $best = $t }
  }
  [Math]::Min(1.0, [Math]::Min($best[0] / $w, $best[1] / $h))
}
function New-Frame($r, [int]$maxW, [string]$label) {
  $s = Fit $r.Width $r.Height $maxW
  [pscustomobject]@{ x = $r.X; y = $r.Y; w = $r.Width; h = $r.Height
    iw = [Math]::Max(1, [int][Math]::Round($r.Width * $s)); ih = [Math]::Max(1, [int][Math]::Round($r.Height * $s)); label = $label }
}
function FrameRect($f) { New-Object Drawing.Rectangle ([int]$f.x), ([int]$f.y), ([int]$f.w), ([int]$f.h) }
function Use-Frame($f) { Set-State frame $f; if (Test-Path $BasePng) { Remove-Item $BasePng -Force } }
function Get-Frame {
  if (-not $State.frame) { $r, $label = Target 'mon'; Use-Frame (New-Frame $r 0 $label); Save-State }
  $State.frame
}
function PX($f, $fx) { [int][Math]::Floor($f.x + ([double]$fx + 0.5) * $f.w / $f.iw) }
function PY($f, $fy) { [int][Math]::Floor($f.y + ([double]$fy + 0.5) * $f.h / $f.ih) }
function FXY($f, $px, $py) { '{0},{1}' -f [int][Math]::Floor(($px - $f.x) * $f.iw / $f.w), [int][Math]::Floor(($py - $f.y) * $f.ih / $f.h) }
function Region($f, $X, $Y, $W, $H) {
  $x0 = [int][Math]::Floor($f.x + [double]$X * $f.w / $f.iw); $y0 = [int][Math]::Floor($f.y + [double]$Y * $f.h / $f.ih)
  $x1 = [int][Math]::Ceiling($f.x + ([double]$X + [double]$W) * $f.w / $f.iw); $y1 = [int][Math]::Ceiling($f.y + ([double]$Y + [double]$H) * $f.h / $f.ih)
  New-Object Drawing.Rectangle $x0, $y0, ([Math]::Max(1, $x1 - $x0)), ([Math]::Max(1, $y1 - $y0))
}
# 撮る範囲：mon（前面の窓があるモニター）/ 数字（そのモニター）/ win（前面の窓）/ all（全部のモニター）
function Target([string]$t) {
  $fg = [Desk.N]::GetForegroundWindow()
  if ($t -eq 'all') { return [Desk.N]::Virtual(), 'all' }
  if ($t -match '^\d$') {
    $m = [Desk.N]::Monitors() | Where-Object { $_.Index -eq [int]$t }
    if (-not $m) { throw "no monitor $t (see: dsk mon)" }
    return $m.Bounds, "mon$t"
  }
  if ($t -eq 'win') { return [Drawing.Rectangle]::Intersect([Desk.N]::WinRect($fg), [Desk.N]::Virtual()), ('win "' + (Short ([Desk.N]::TitleOf($fg)) 40) + '"') }
  $m = [Desk.N]::MonitorOf([Desk.N]::WinRect($fg))
  return $m.Bounds, "mon$($m.Index)"
}
# "#3"（ui / shot -marks の番号）か "X Y"（フレーム座標）→ 実ピクセル x, y, 使った引数の数, 表示用
function Get-Point($f, $a, [int]$i) {
  if ($a.Count -le $i) { throw 'need X Y (or #n)' }
  if ($a[$i] -match '^#(\d+)$') {
    $m = @($State.marks)[[int]$Matches[1] - 1]
    if (-not $m) { throw "no mark $($a[$i]) (run ui or shot -marks first)" }
    return [int]$m.px, [int]$m.py, 1, $a[$i]
  }
  if ($a.Count -lt $i + 2) { throw 'need X Y' }
  $fx = [double]$a[$i]; $fy = [double]$a[$i + 1]
  if ($fx -lt 0 -or $fy -lt 0 -or $fx -ge $f.iw -or $fy -ge $f.ih) { throw "($fx,$fy) is outside the frame $($f.iw)x$($f.ih) [$($f.label)]" }
  return (PX $f $fx), (PY $f $fy), 2, "$($a[$i]),$($a[$i + 1])"
}

# ---- Claude Code 自身の窓（ここへはキー入力しない・OCR で読まない）と、最後に操作した窓
function Get-Hosts {
  if ($null -eq $script:Hosts) {
    $h = @([Desk.N]::HostPids($PID)); if ($env:CLAUDE_PID -match '^\d+$') { $h += [Desk.N]::HostPids([int]$env:CLAUDE_PID) }
    $script:Hosts = @($h | Select-Object -Unique)
  }
  , $script:Hosts
}
# Claude Code 自身の窓のうち、ほかの窓に隠れていない部分（r の左上を 0,0 とし、s 倍した四角）
function Host-Rects([Drawing.Rectangle]$r, [double]$s = 1.0) {
  $hosts = Get-Hosts; if (-not $hosts.Count) { return }
  $above = @()
  foreach ($w in [Desk.N]::Windows()) {
    if ($w.Min) { continue }
    if ($hosts -contains $w.Pid) {
      $free = $true; foreach ($a in $above) { if ($a.IntersectsWith($w.Rect)) { $free = $false } }
      $ir = [Drawing.Rectangle]::Intersect($w.Rect, $r)
      if ($free -and $ir.Width -gt 0 -and $ir.Height -gt 0) {
        New-Object Drawing.Rectangle ([int](($ir.X - $r.X) * $s)), ([int](($ir.Y - $r.Y) * $s)), ([int][Math]::Ceiling($ir.Width * $s)), ([int][Math]::Ceiling($ir.Height * $s))
      }
    }
    $above += $w.Rect
  }
}
function Remember-Fg { Start-Sleep -Milliseconds 80; Set-State fgpid ([Desk.N]::PidOf([Desk.N]::GetForegroundWindow())); Save-State }
function Guard-Keys([bool]$force) {
  if ($force) { return }
  $h = [Desk.N]::GetForegroundWindow(); $p = [Desk.N]::PidOf($h); $t = Short ([Desk.N]::TitleOf($h)) 40
  if ((Get-Hosts) -contains $p) { throw "the foreground window is Claude Code's own (`"$t`"). focus the target first (or add -f)" }
  if ($State.fgpid -and [int]$State.fgpid -ne $p) { throw "the foreground window changed to `"$t`". focus the target again (or add -f)" }
}

# ---- UI Automation の部品
function Get-Elements($f, [bool]$all, [int]$timeout) {
  # 調べる窓：前面の窓を先頭に、フレームの中で少しでも見えている窓を3つまで（Claude Code 自身の窓は除く）
  $fr = FrameRect $f; $hosts = Get-Hosts; $fg = [Desk.N]::GetForegroundWindow()
  $cand = @([Desk.N]::Windows() | Where-Object { -not $_.Min -and $hosts -notcontains $_.Pid -and $_.Rect.IntersectsWith($fr) })
  $cand = @($cand | Where-Object { $_.Hwnd -eq $fg }) + @($cand | Where-Object { $_.Hwnd -ne $fg })
  $roots = @($cand | Where-Object { [Desk.N]::Visible($_.Hwnd, $fr) -ge 0.05 } | Select-Object -First 3 | ForEach-Object { $_.Hwnd.ToInt64() })
  if (-not $roots.Count) { return @() }
  # 並び順：前面の窓の部品が先（番号がほかの窓と混ざらないように）、同じ窓の中は上から・左から
  @([Desk.N]::Elements([long[]]$roots, $all, $timeout, $fr) | Sort-Object { [array]::IndexOf($roots, $_.Root) }, { [int][Math]::Floor(($_.Rect.Y + $_.Rect.Height / 2) / 10) }, { $_.Rect.X })
}
function Fmt-El($e, $f) {
  $s = $e.Type
  if ($e.Name) { $s += ' "' + $e.Name + '"' }
  if ($e.Value) { $s += ' ="' + $e.Value + '"' }
  if ($e.State) { $s += " [$($e.State)]" }
  $s + ' @' + (FXY $f ($e.Rect.X + $e.Rect.Width / 2) ($e.Rect.Y + $e.Rect.Height / 2))
}
function Mark-Items($els, $f) {
  $items = @(foreach ($e in $els) { [pscustomobject]@{ px = $e.Rect.X + [int]($e.Rect.Width / 2); py = $e.Rect.Y + [int]($e.Rect.Height / 2) } })
  Set-State marks $items
}

# ---- OCR（Windows 標準の文字認識。日本語・英語）
function Init-Ocr {
  if ($script:OcrReady) { return }
  Add-Type -AssemblyName System.Runtime.WindowsRuntime
  $null = [Windows.Media.Ocr.OcrEngine, Windows.Foundation, ContentType = WindowsRuntime]
  $null = [Windows.Graphics.Imaging.SoftwareBitmap, Windows.Graphics, ContentType = WindowsRuntime]
  $null = [Windows.Globalization.Language, Windows.Globalization, ContentType = WindowsRuntime]
  $script:AsTaskG = [System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
    $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' } | Select-Object -First 1
  # 入っている OCR の言語（日本語は日英どちらも読める。英語用が入っていれば英字だけの検索で使う）
  $script:OcrLangs = @{}
  foreach ($l in [Windows.Media.Ocr.OcrEngine]::AvailableRecognizerLanguages) {
    if ($l.LanguageTag -like 'ja*' -and -not $script:OcrLangs.ja) { $script:OcrLangs.ja = $l }
    if ($l.LanguageTag -like 'en*' -and -not $script:OcrLangs.en) { $script:OcrLangs.en = $l }
  }
  if (-not (New-OcrEngine 'ja')) { throw 'OCR engine is not available' }
  $script:OcrReady = $true
}
function New-OcrEngine([string]$pref) {
  $l = if ($pref -and $script:OcrLangs[$pref]) { $script:OcrLangs[$pref] } elseif ($script:OcrLangs.ja) { $script:OcrLangs.ja } else { $null }
  if ($l) { [Windows.Media.Ocr.OcrEngine]::TryCreateFromLanguage($l) } else { [Windows.Media.Ocr.OcrEngine]::TryCreateFromUserProfileLanguages() }
}
function IsWide([char]$c) { [int]$c -ge 0x2E80 }
# 画面の範囲 r（実ピクセル）を読み、近い単語どうしのかたまり（text, words, px, py）を返す
function Get-OcrSegments([Drawing.Rectangle]$r, [string]$lang = 'ja') {
  Init-Ocr
  $area = [double]$r.Width * $r.Height
  # 小さい範囲ほど大きく拡大して読む（このPCの OCR は日本語用なので、小さい英字は拡大しないと読み違えやすい）
  $k = if ($area -le 3e5) { 3.0 } elseif ($area -le 8e5) { 2.0 } elseif ($area -le 2.2e6) { 1.5 } else { 1.0 }
  $raw = [Desk.N]::Capture($r)
  # Claude Code 自身の窓が手前に出ているなら黒く塗る（読む量が減って速い・まちがって当たらない）
  foreach ($ir in (Host-Rects $r)) { [Desk.N]::Fill($raw, $ir) }
  $bmp = if ($k -ne 1) { [Desk.N]::Resize($raw, [int]($r.Width * $k), [int]($r.Height * $k)) } else { $raw }
  # 横の帯に分けて同時に読む（帯の境目の行は、重ねた部分で拾う）
  $W = $bmp.Width; $H = $bmp.Height
  $n = [Math]::Max(1, [Math]::Min(4, [int][Math]::Ceiling($H / 300.0))); $bh = [int][Math]::Ceiling($H / $n); $ov = [int](30 * $k)
  $jobs = @()
  for ($i = 0; $i -lt $n; $i++) {
    $y0 = [Math]::Max(0, $i * $bh - $ov); $y1 = [Math]::Min($H, ($i + 1) * $bh + $ov)
    $part = $bmp.Clone((New-Object Drawing.Rectangle 0, $y0, $W, ($y1 - $y0)), [Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $buf = [System.Runtime.InteropServices.WindowsRuntime.WindowsRuntimeBufferExtensions]::AsBuffer([Desk.N]::Bgra($part))
    $sbm = [Windows.Graphics.Imaging.SoftwareBitmap]::CreateCopyFromBuffer($buf, [Windows.Graphics.Imaging.BitmapPixelFormat]::Bgra8, $part.Width, $part.Height)
    $part.Dispose()
    $task = $script:AsTaskG.MakeGenericMethod([Windows.Media.Ocr.OcrResult]).Invoke($null, @((New-OcrEngine $lang).RecognizeAsync($sbm)))
    $jobs += [pscustomobject]@{ y0 = $y0; lo = $i * $bh; hi = ($i + 1) * $bh; task = $task }
  }
  if ($bmp -ne $raw) { $bmp.Dispose() }; $raw.Dispose()
  if (-not [Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]@($jobs | ForEach-Object { $_.task }), 30000)) { throw 'OCR timeout' }
  foreach ($j in $jobs) { foreach ($line in $j.task.Result.Lines) {
    $ws = @(foreach ($w in $line.Words) { $b = $w.BoundingRect
        [pscustomobject]@{ t = $w.Text; x = $r.X + $b.X / $k; y = $r.Y + ($j.y0 + $b.Y) / $k; w = $b.Width / $k; h = $b.Height / $k; cy = $j.y0 + $b.Y + $b.Height / 2 } })
    if (-not $ws.Count) { continue }
    $cy = 0; foreach ($w in $ws) { $cy += $w.cy }; $cy /= $ws.Count
    if ($cy -lt $j.lo -or $cy -ge $j.hi) { continue }   # 重ねた部分で2回読んだ行は、受け持ちの帯の分だけ使う
    $lh = 0; foreach ($w in $ws) { if ($w.h -gt $lh) { $lh = $w.h } }
    # 離れた単語は別のかたまりにする（メニューなどが1行にまとめて読まれるため）
    $seg = New-Object Collections.ArrayList
    foreach ($w in $ws) {
      if ($seg.Count) { $p = $seg[$seg.Count - 1]; if ($w.x - ($p.x + $p.w) -gt [Math]::Max(1.5 * $lh, 14)) { Emit-Seg $seg $hosts; $seg = New-Object Collections.ArrayList } }
      [void]$seg.Add($w)
    }
    Emit-Seg $seg $hosts
  } }
}
function Emit-Seg($seg, $hosts) {
  $x0 = 1e9; $y0 = 1e9; $x1 = -1e9; $y1 = -1e9; $sb = New-Object Text.StringBuilder; $last = [char]' '
  foreach ($w in $seg) {
    $x0 = [Math]::Min($x0, $w.x); $y0 = [Math]::Min($y0, $w.y); $x1 = [Math]::Max($x1, $w.x + $w.w); $y1 = [Math]::Max($y1, $w.y + $w.h)
    if ($sb.Length -and -not ((IsWide $last) -and (IsWide $w.t[0]))) { [void]$sb.Append(' ') }
    [void]$sb.Append($w.t); $last = $w.t[$w.t.Length - 1]
  }
  $cx = [int](($x0 + $x1) / 2); $cy = [int](($y0 + $y1) / 2)
  if ($hosts.Count -and $hosts -contains [Desk.N]::PidOf([Desk.N]::RootAt($cx, $cy))) { return }   # Claude Code 自身の画面の文字は無視
  [pscustomobject]@{ text = $sb.ToString(); words = @($seg); px = $cx; py = $cy }
}
# かたまりの中で文字を探す（単語をつないだ文字列で探し、当たった単語の範囲の中心を返す）
function Match-Segment($s, [string]$nq) {
  $buf = New-Object Text.StringBuilder; $map = New-Object Collections.Generic.List[int]; $starts = @{}; $ends = @{}
  for ($i = 0; $i -lt $s.words.Count; $i++) {
    $nw = Norm $s.words[$i].t; $starts[$buf.Length] = 1; [void]$buf.Append($nw)
    for ($k = 0; $k -lt $nw.Length; $k++) { $map.Add($i) }
    $ends[$buf.Length] = 1
  }
  $str = $buf.ToString(); $idx = $str.IndexOf($nq, [StringComparison]::Ordinal)
  # そのままでは無いとき：かたまり全体（ボタンの文字など）がほぼ同じなら当たりにする（4文字につき1文字の読み違いまで）。
  # 長い文の一部へのあいまい一致は、別の場所を押す原因になるので使わない
  if ($idx -lt 0 -and $nq.Length -ge 4 -and [Math]::Abs($str.Length - $nq.Length) -le [Math]::Floor($nq.Length / 4) -and
      [Desk.N]::Distance($str, $nq) -le [Math]::Floor($nq.Length / 4)) {
    [pscustomobject]@{ tier = 2; px = $s.px; py = $s.py; d = '[ocr~] "' + (Short $s.text 50) + '"' }
  }
  while ($idx -ge 0) {
    $x0 = 1e9; $y0 = 1e9; $x1 = -1e9; $y1 = -1e9
    foreach ($w in $s.words[$map[$idx]..$map[$idx + $nq.Length - 1]]) {
      $x0 = [Math]::Min($x0, $w.x); $y0 = [Math]::Min($y0, $w.y); $x1 = [Math]::Max($x1, $w.x + $w.w); $y1 = [Math]::Max($y1, $w.y + $w.h)
    }
    $tier = if ($nq.Length -eq $str.Length) { 0 } elseif ($starts.ContainsKey($idx) -and $ends.ContainsKey($idx + $nq.Length)) { 1 } else { 3 }
    [pscustomobject]@{ tier = $tier; px = [int](($x0 + $x1) / 2); py = [int](($y0 + $y1) / 2); d = '[ocr] "' + (Short $s.text 50) + '"' }
    $idx = $str.IndexOf($nq, $idx + 1, [StringComparison]::Ordinal)
  }
}
# 文字で探す：UI Automation の名前 → 見つからない／完全一致がなければ OCR。良い順（同じなら上から・左から）に並べる
function Find-Text([string]$q, [string]$src) {
  $f = Get-Frame; $nq = Norm $q; if (-not $nq) { throw 'empty text' }
  $area = [double]$f.w * $f.h; $c = New-Object Collections.ArrayList
  if ($src -ne 'ocr') {
    foreach ($e in (Get-Elements $f $true 3000)) {
      $n = Norm $e.Name; if (-not $n) { continue }
      if ([double]$e.Rect.Width * $e.Rect.Height -gt $area / 4) { continue }   # ページ全体などの大きな入れ物は除く
      $tier = if ($n -eq $nq) { 0 } elseif ($n.StartsWith($nq, [StringComparison]::Ordinal)) { 1 } elseif ($n.Contains($nq) -and $n.Length -le $nq.Length * 3 + 10) { 3 } else { -1 }
      if ($tier -ge 0) {
        [void]$c.Add([pscustomobject]@{ tier = $tier; px = $e.Rect.X + [int]($e.Rect.Width / 2); py = $e.Rect.Y + [int]($e.Rect.Height / 2); d = "[ui] $($e.Type) `"$($e.Name)`""; rect = $e.Rect })
      }
    }
  }
  $best = 9; foreach ($m in $c) { if ($m.tier -lt $best) { $best = $m.tier } }
  # 部品の名前で十分よく当たったら OCR はしない（OCR は遅い）。当たらないときだけ画面の文字を読む
  if ($src -eq 'ocr' -or ($src -ne 'ui' -and $best -gt 1)) {
    # まず前面の窓の範囲だけ読む（狭いほど速く正確）。そこに無ければフレーム全体を読む
    $fr = FrameRect $f; $regions = @()
    $fgw = [Desk.N]::GetForegroundWindow()
    if ((Get-Hosts) -notcontains [Desk.N]::PidOf($fgw)) {
      $wr = [Drawing.Rectangle]::Intersect([Desk.N]::WinRect($fgw), $fr)
      if ($wr.Width -gt 0 -and $wr.Height -gt 0 -and [double]$wr.Width * $wr.Height -lt 0.8 * $area) { $regions += $wr }
    }
    $regions += $fr
    foreach ($rg in $regions) {
      $before = $c.Count
      foreach ($s in (Get-OcrSegments $rg $(if ($q -match '^[ -~]+$') { 'en' } else { 'ja' }))) {
        foreach ($m in (Match-Segment $s $nq)) {
          $dup = $false; foreach ($o in $c) { if (($o.rect -and $o.rect.Contains([int]$m.px, [int]$m.py)) -or ([Math]::Abs($o.px - $m.px) -lt 8 -and [Math]::Abs($o.py - $m.py) -lt 8)) { $dup = $true } }   # 同じ部品の文字なら部品の方を残す
          if (-not $dup) { [void]$c.Add($m) }
        }
      }
      if ($c.Count -gt $before) { break }
    }
  }
  @($c | Sort-Object tier, { [int][Math]::Floor($_.py / 10) }, px)
}
function List-Matches($c, $f) {
  $i = 0
  foreach ($m in ($c | Select-Object -First 15)) { $i++; "$i $($m.d) @$(FXY $f $m.px $m.py)" }
  if ($c.Count -gt 15) { "(+$($c.Count - 15) more)" }
}

# ---- 命令
function Cmd-Shot($a) {
  $t = 'mon'; $maxW = 0; $grid = $false; $marks = $false; $pw = $false; $out = Join-Path $Tmp 'shot.png'
  for ($i = 0; $i -lt $a.Count; $i++) {
    $o = $a[$i]
    if ($o -eq '-w') { $maxW = [int]$a[++$i] }
    elseif ($o -eq '-grid') { $grid = $true }
    elseif ($o -eq '-marks') { $marks = $true }
    elseif ($o -eq '-pw') { $pw = $true }
    elseif ($o -match '^(mon|win|all|\d)$') { $t = $o }
    elseif ($o -match '\.png$') { $out = $o }
    else { throw "shot: unknown option '$o'" }
  }
  $fg = [Desk.N]::GetForegroundWindow()
  if ($pw) { $r = [Desk.N]::WinRect($fg); $label = 'win "' + (Short ([Desk.N]::TitleOf($fg)) 40) + '"' } else { $r, $label = Target $t }
  $f = New-Frame $r $maxW $label
  $raw = if ($pw) { [Desk.N]::CaptureWindow($fg) } else { [Desk.N]::Capture($r) }
  $img = [Desk.N]::Resize($raw, $f.iw, $f.ih); $raw.Dispose()
  Use-Frame $f
  $img.Save($BasePng, [Drawing.Imaging.ImageFormat]::Bmp)
  $legend = @()
  if ($marks) {
    $els = @(Get-Elements $f $false 4000 | Select-Object -First 80)
    $rects = New-Object Collections.Generic.List[int]; $n = 0
    foreach ($e in $els) {
      $n++; $legend += "#$n " + (Fmt-El $e $f)
      $rects.Add([int](($e.Rect.X - $f.x) * $f.iw / $f.w)); $rects.Add([int](($e.Rect.Y - $f.y) * $f.ih / $f.h))
      $rects.Add([int]($e.Rect.Width * $f.iw / $f.w)); $rects.Add([int]($e.Rect.Height * $f.ih / $f.h))
    }
    [Desk.N]::Marks($img, $rects.ToArray()); Mark-Items $els $f
  }
  if ($grid) { [Desk.N]::Grid($img, 0, 0, 1.0) }
  [Desk.N]::SavePng($img, $out); $img.Dispose(); Save-State
  "$out $($f.iw)x$($f.ih) $label | fg: $(Short ([Desk.N]::TitleOf($fg)) 50)"
  $legend
}
function Cmd-Zoom($a, [bool]$sameScale) {
  if ($a.Count -lt 4) { throw 'usage: zoom X Y W H [2] [-grid]' }
  $f = Get-Frame; $X = [double]$a[0]; $Y = [double]$a[1]; $W = [double]$a[2]; $H = [double]$a[3]
  $mult = 1.0; $grid = $false
  foreach ($o in ($a | Select-Object -Skip 4)) { if ($o -eq '-grid') { $grid = $true } elseif ($o -match '^x?(\d+(\.\d+)?)$') { $mult = [double]$Matches[1] } }
  $r = Region $f $X $Y $W $H
  $k = if ($sameScale) { $f.iw / $f.w } else { $mult }   # 画像の px ÷ 実ピクセル（1 = 画面そのままの細かさ）
  $k = [Math]::Min($k, [Math]::Min(1366.0 / $r.Width, 900.0 / $r.Height))
  $ow = [Math]::Max(1, [int][Math]::Round($r.Width * $k)); $oh = [Math]::Max(1, [int][Math]::Round($r.Height * $k))
  $raw = [Desk.N]::Capture($r); $img = [Desk.N]::Resize($raw, $ow, $oh); $raw.Dispose()
  if ($grid) { [Desk.N]::Grid($img, $X, $Y, $ow / $W) }
  $out = Join-Path $Tmp 'zoom.png'; [Desk.N]::SavePng($img, $out); $img.Dispose()
  "$out ${ow}x${oh} | frame x = $(Num $X) + px*$(Num ($W / $ow)), y = $(Num $Y) + py*$(Num ($H / $oh))"
}
function Do-Click($px, $py, [string]$mode, [string]$what) {
  $hit = [Desk.N]::HitTest($px, $py, 700)
  $win = Short ([Desk.N]::TitleOf([Desk.N]::RootAt($px, $py))) 40
  [Desk.N]::Click($px, $py, $mode)
  Remember-Fg
  "click $what$(if ($mode) { " $mode" }) -> $(if ($hit) { $hit } else { '?' }) in `"$win`""
}
function Cmd-Click($a, [string]$mode) {
  $f = Get-Frame
  $px, $py, $used, $lbl = Get-Point $f $a 0
  if ($a.Count -gt $used) { $mode = $a[$used] }
  if ($mode -and $mode -notin 'right', 'double', 'middle') { throw "unknown click mode '$mode'" }
  Do-Click $px $py $mode $lbl
}
function Cmd-ClickText($a, [string]$mode) {
  $a = @($a | Where-Object { $_ -notin '-ui', '-ocr' }) + @($a | Where-Object { $_ -in '-ui', '-ocr' })   # 文字を先頭に
  if (-not $a.Count -or $a[0] -like '-*') { throw 'usage: clickt "text" [n] [right|double] [-ui|-ocr]' }
  $q = $a[0]; $n = 0; $src = ''
  foreach ($o in ($a | Select-Object -Skip 1)) {
    if ($o -match '^\d+$') { $n = [int]$o } elseif ($o -in 'right', 'double', 'middle') { $mode = $o }
    elseif ($o -in '-ui', '-ocr') { $src = $o.Substring(1) } else { throw "clickt: unknown option '$o'" }
  }
  $f = Get-Frame; $c = @(Find-Text $q $src)
  if (-not $c.Count) { throw "not found: `"$q`" in $($f.label)" }
  if ($n -gt 0) { if ($n -gt $c.Count) { throw "only $($c.Count) matches" }; $pick = $c[$n - 1] }
  else {
    $top = @($c | Where-Object { $_.tier -eq $c[0].tier })
    if ($top.Count -gt 1) { List-Matches $c $f; throw "$($top.Count) equally good matches. pick one: clickt `"$q`" <n>" }
    # 単語の途中に当たっただけ（"Clear" → "cleared" など）なら、押す前に確かめてもらう
    if ($c[0].tier -ge 3) { List-Matches $c $f; throw "only partial matches (inside longer text). if one is right: clickt `"$q`" <n>" }
    $pick = $c[0]
  }
  Do-Click $pick.px $pick.py $mode "$(FXY $f $pick.px $pick.py) $($pick.d)"
}
function Cmd-Ui($a) {
  $all = $false; $max = 60; $filter = $null
  for ($i = 0; $i -lt $a.Count; $i++) { if ($a[$i] -eq '-n') { $max = [int]$a[++$i] } elseif ($a[$i] -eq '-all') { $all = $true } else { $filter = $a[$i] } }
  $f = Get-Frame
  $els = @(Get-Elements $f $all 4000)
  if ($filter) { $nf = Norm $filter; $els = @($els | Where-Object { (Norm "$($_.Type) $($_.Name) $($_.Value)").Contains($nf) }) }
  Mark-Items $els $f; Save-State
  "ui $($f.label): $($els.Count)"
  $i = 0; foreach ($e in ($els | Select-Object -First $max)) { $i++; "#$i " + (Fmt-El $e $f) }
  if ($els.Count -gt $max) { "(+$($els.Count - $max) more: dsk ui <filter> / -n N)" }
}
function Cmd-Find($a) {
  $src = if ($a -contains '-ocr') { 'ocr' } elseif ($a -contains '-ui') { 'ui' } else { '' }
  $q = @($a | Where-Object { $_ -notin '-ui', '-ocr' })[0]
  if (-not $q) { throw 'usage: find "text" [-ui|-ocr]' }
  $f = Get-Frame; $c = @(Find-Text $q $src)
  if (-not $c.Count) { "not found: `"$q`" in $($f.label)"; return }
  List-Matches $c $f
}
function Cmd-Ocr($a) {
  $lang = if ($a -contains '-en') { 'en' } else { 'ja' }; $a = @($a | Where-Object { $_ -ne '-en' })
  $f = Get-Frame
  $r = if ($a.Count -ge 4) { Region $f $a[0] $a[1] $a[2] $a[3] } else { FrameRect $f }
  $segs = @(Get-OcrSegments $r $lang | Sort-Object { [int][Math]::Floor($_.py / 10) }, px)
  "ocr $($f.label): $($segs.Count)"
  foreach ($s in $segs) { "$($s.text) @$(FXY $f $s.px $s.py)" }
}
function Cmd-WaitFor($a) {
  $gone = $a -contains '-gone'; $a = @($a | Where-Object { $_ -ne '-gone' })
  if (-not $a.Count) { throw 'usage: waitfor "text" [sec] [-gone]' }
  $q = $a[0]; $sec = 10.0
  foreach ($o in ($a | Select-Object -Skip 1)) { if ($o -match '^\d+(\.\d+)?$') { $sec = [double]$o } }
  $f = Get-Frame; $sw = [Diagnostics.Stopwatch]::StartNew()
  while ($true) {
    $c = @(Find-Text $q '')
    $t = Num ([Math]::Round($sw.Elapsed.TotalSeconds, 1))
    if ($gone -and -not $c.Count) { "gone after ${t}s"; return }
    if (-not $gone -and $c.Count) { "found after ${t}s"; List-Matches $c $f; return }
    if ($sw.Elapsed.TotalSeconds -ge $sec) { throw "timeout ${sec}s: `"$q`"$(if ($gone) { ' is still there' } else { ' not found' })" }
    Start-Sleep -Milliseconds 300
  }
}
function Cmd-Changed($a) {
  $f = Get-Frame
  if (-not (Test-Path $BasePng)) { throw 'no baseline for this frame (run shot first)' }
  $ms = if ($a.Count) { [int]$a[0] } else { 0 }
  $tmpImg = [Drawing.Image]::FromFile($BasePng); $base = New-Object Drawing.Bitmap $tmpImg; $tmpImg.Dispose()
  if ($base.Width -ne $f.iw -or $base.Height -ne $f.ih) { $base.Dispose(); throw 'baseline is from another frame (run shot)' }
  $fr = FrameRect $f; $sw = [Diagnostics.Stopwatch]::StartNew()
  $mask = @(Host-Rects $fr ($f.iw / $f.w))   # Claude Code 自身の窓（動き続ける）の変化は数えない
  foreach ($m in $mask) { [Desk.N]::Fill($base, $m) }
  while ($true) {
    $raw = [Desk.N]::Capture($fr); $cur = [Desk.N]::Resize($raw, $f.iw, $f.ih); $raw.Dispose()
    foreach ($m in $mask) { [Desk.N]::Fill($cur, $m) }
    $d = [Desk.N]::Diff($base, $cur, 16, 48)
    if ($d -ne '0' -or $sw.ElapsedMilliseconds -ge $ms) { break }
    $cur.Dispose(); Start-Sleep -Milliseconds 100
  }
  $base.Dispose(); $cur.Save($BasePng, [Drawing.Imaging.ImageFormat]::Bmp); $cur.Dispose()
  if ($d -eq '0') { return 'no change' }
  $p = $d -split '\|'
  $boxes = foreach ($b in ($p | Select-Object -Skip 1)) { if ($b -like '+*') { "$b more" } else { $x, $y, $w, $h = $b -split ','; "$x,$y ${w}x$h" } }
  "changed $($p[0])%: " + ($boxes -join '; ')
}
function Cmd-Focus($a) {
  if (-not $a.Count) { throw 'usage: focus "title or process" [max]' }
  $q = $a[0]; $hosts = Get-Hosts; $ws = @([Desk.N]::Windows())
  $m = @($ws | Where-Object { $_.Proc -eq $q })
  if (-not $m.Count) { $m = @($ws | Where-Object { $_.Title.IndexOf($q, [StringComparison]::OrdinalIgnoreCase) -ge 0 }) }
  $m = @($m | Where-Object { $hosts -notcontains $_.Pid }) + @($m | Where-Object { $hosts -contains $_.Pid })   # Claude Code 自身の窓は最後に回す
  if (-not $m.Count) { throw "no window matches `"$q`" (see: dsk wins)" }
  $w = $m[0]
  $ok = [Desk.N]::Focus($w.Hwnd)
  if ($a -contains 'max') { [void][Desk.N]::ShowWindow($w.Hwnd, 3); Start-Sleep -Milliseconds 250 }
  if (-not $ok) { throw "FOCUS FAILED: `"$($w.Title)`"" }
  Set-State fgpid $w.Pid
  $r = [Desk.N]::WinRect($w.Hwnd); $mon = [Desk.N]::MonitorOf($r); $note = ''
  # 窓が今のフレームの外にあるなら、その窓のモニターをフレームにする（ui / find がその窓を見るように）
  if (-not $State.frame -or -not (FrameRect $State.frame).Contains([int]($r.X + $r.Width / 2), [int]($r.Y + $r.Height / 2))) {
    Use-Frame (New-Frame $mon.Bounds 0 "mon$($mon.Index)"); $note = " (frame -> mon$($mon.Index))"
  }
  Save-State
  "focused `"$(Short $w.Title 50)`" [$($w.Proc)] mon$($mon.Index) $($r.Width)x$($r.Height)$(if ($m.Count -gt 1) { " (+$($m.Count - 1) more matches)" })$note"
}
function Cmd-Wins($a) {
  $q = if ($a.Count) { [string]$a[0] } else { '' }; $hosts = Get-Hosts; $fg = [Desk.N]::GetForegroundWindow()
  foreach ($w in [Desk.N]::Windows()) {
    if ($q -and $w.Title.IndexOf($q, [StringComparison]::OrdinalIgnoreCase) -lt 0 -and $w.Proc -ne $q) { continue }
    $st = if ($w.Min) { 'min' } else { "mon$(([Desk.N]::MonitorOf($w.Rect)).Index) $($w.Rect.Width)x$($w.Rect.Height)$(if ($w.Max) { ' max' })" }
    "$(if ($w.Hwnd -eq $fg) { '*' } else { ' ' })$($w.Proc) | $(Short $w.Title 60) | $st$(if ($hosts -contains $w.Pid) { ' (Claude Code)' })"
  }
}
function Cmd-Mon {
  foreach ($m in [Desk.N]::Monitors()) { "mon$($m.Index)$(if ($m.Primary) { '*' }) $($m.Bounds.Width)x$($m.Bounds.Height) @$($m.Bounds.X),$($m.Bounds.Y) $($m.Scale)%" }
  if ($State.frame) { "frame: $($State.frame.label) $($State.frame.iw)x$($State.frame.ih)" }
}
function Paste([string]$text) {
  Add-Type -AssemblyName System.Windows.Forms
  $sta = [Threading.Thread]::CurrentThread.GetApartmentState() -eq 'STA'
  $keep = $null   # 貼り付けのあと、ユーザーのクリップボードを元に戻す
  try {
    if ($sta) {
      if ([Windows.Forms.Clipboard]::ContainsText()) { $keep = 'text', [Windows.Forms.Clipboard]::GetText() }
      elseif ([Windows.Forms.Clipboard]::ContainsImage()) { $keep = 'image', [Windows.Forms.Clipboard]::GetImage() }
      elseif ([Windows.Forms.Clipboard]::ContainsFileDropList()) { $keep = 'files', [Windows.Forms.Clipboard]::GetFileDropList() }
    } else { $t = Get-Clipboard -Raw; if ($t) { $keep = 'text', $t } }
  } catch {}
  if ($sta) { [Windows.Forms.Clipboard]::SetDataObject($text, $true, 10, 50) } else { Set-Clipboard -Value $text }
  [Desk.N]::Keys('ctrl+v'); Start-Sleep -Milliseconds 300
  if ($keep) {
    try {
      switch ($keep[0]) {
        'text' { if ($sta) { [Windows.Forms.Clipboard]::SetDataObject($keep[1], $true, 10, 50) } else { Set-Clipboard -Value $keep[1] } }
        'image' { [Windows.Forms.Clipboard]::SetImage($keep[1]) }
        'files' { [Windows.Forms.Clipboard]::SetFileDropList($keep[1]) }
      }
    } catch {}
  }
}
function Cmd-Type($a) {
  if (-not $a.Count) { throw 'usage: type "text" [enter] [-k] [-f]' }
  $text = [string]$a[0]; $o = @($a | Select-Object -Skip 1)
  Guard-Keys ($o -contains '-f')
  if ($o -contains '-k') { [Desk.N]::TypeText($text) } else { Paste $text }
  if ($o -contains 'enter') { Start-Sleep -Milliseconds 50; [Desk.N]::Keys('enter') }
  Remember-Fg
  "typed $($text.Length) chars$(if ($o -contains 'enter') { ' + enter' })"
}
function Cmd-Key($a) {
  $spec = (@($a | Where-Object { $_ -ne '-f' }) -join ' ').Trim()
  if (-not $spec) { throw 'usage: key ctrl+s | "tab tab enter" | w:800' }
  Guard-Keys ($a -contains '-f'); [Desk.N]::Keys($spec); Remember-Fg; "key $spec"
}
function Show-Help {
  @'
dsk <cmd> | dsk "cmd a; cmd b"   (X Y = pixels of the last shot image; details: SKILL.md)
 look : shot [mon|win|all|N] [-w W] [-grid] [-marks] [-pw] | zoom X Y W H [2] [-grid] | changed [ms] | color X Y
 text : wins [q] | mon | ui [filter] [-all] [-n N] | find "t" [-ui|-ocr] | ocr [X Y W H] | waitfor "t" [sec] [-gone]
 act  : focus "title|proc" [max] | click X Y|#n [right|double|middle] | clickt "t" [n] [right|double]
        move X Y | drag X1 Y1 X2 Y2 | scroll X Y N [h] | key ctrl+s|"tab enter"|w:800 | type "text" [enter] [-k] | wait ms
'@
}

function Run-Cmd([string[]]$c) {
  $rest = @(if ($c.Count -gt 1) { $c[1..($c.Count - 1)] })
  switch ($c[0].ToLowerInvariant()) {
    'shot' { Cmd-Shot $rest }
    'shotpw' { Cmd-Shot (@('-pw') + $rest) }
    'zoom' { Cmd-Zoom $rest $false }
    'crop' { Cmd-Zoom $rest $true }
    'click' { Cmd-Click $rest '' }
    'rclick' { Cmd-Click $rest 'right' }
    'dclick' { Cmd-Click $rest 'double' }
    'clickt' { Cmd-ClickText $rest '' }
    'move' { $f = Get-Frame; $px, $py, $u, $l = Get-Point $f $rest 0; [Desk.N]::MoveTo($px, $py); "move $l" }
    'drag' {
      $f = Get-Frame; $p1 = Get-Point $f $rest 0; $p2 = Get-Point $f $rest $p1[2]
      [Desk.N]::Drag($p1[0], $p1[1], $p2[0], $p2[1]); Remember-Fg; "drag $($p1[3]) -> $($p2[3])"
    }
    'scroll' {
      $f = Get-Frame; $px, $py, $u, $l = Get-Point $f $rest 0
      $n = if ($rest.Count -gt $u -and $rest[$u] -match '^-?\d+$') { [int]$rest[$u] } else { -3 }
      [Desk.N]::Scroll($px, $py, $n, ($rest -contains 'h')); "scroll $l $n"
    }
    'key' { Cmd-Key $rest }
    'keys' { Guard-Keys ($rest -contains '-f'); Add-Type -AssemblyName System.Windows.Forms; [Windows.Forms.SendKeys]::SendWait($rest[0]); Remember-Fg; "sent $($rest[0])" }
    'type' { Cmd-Type $rest }
    'focus' { Cmd-Focus $rest }
    'wins' { Cmd-Wins $rest }
    'mon' { Cmd-Mon }
    'ui' { Cmd-Ui $rest }
    'find' { Cmd-Find $rest }
    'ocr' { Cmd-Ocr $rest }
    'waitfor' { Cmd-WaitFor $rest }
    'changed' { Cmd-Changed $rest }
    'color' { $f = Get-Frame; $px, $py, $u, $l = Get-Point $f $rest 0; "$l $([Desk.N]::Color($px, $py))" }
    'wait' { Start-Sleep -Milliseconds ([int]$rest[0]) }
    'help' { Show-Help }
    default { throw "unknown command '$($c[0])' (dsk help)" }
  }
}
# "a b 'c d'; e f" → @(@(a, b, 'c d'), @(e, f))
function Split-Script([string]$s) {
  $list = New-Object Collections.Generic.List[object]; $cur = New-Object Collections.Generic.List[string]
  $tok = New-Object Text.StringBuilder; $inTok = $false; $q = [char]0
  foreach ($ch in $s.ToCharArray()) {
    if ($q -ne [char]0) { if ($ch -eq $q) { $q = [char]0 } else { [void]$tok.Append($ch) }; continue }
    if ($ch -eq [char]'"' -or $ch -eq [char]"'") { $q = $ch; $inTok = $true; continue }
    $sep = $ch -eq [char]';' -or $ch -eq [char]"`n"
    if ($sep -or [char]::IsWhiteSpace($ch)) {
      if ($inTok) { $cur.Add($tok.ToString()); [void]$tok.Clear(); $inTok = $false }
      if ($sep -and $cur.Count) { $list.Add([string[]]$cur.ToArray()); $cur.Clear() }
      continue
    }
    [void]$tok.Append($ch); $inTok = $true
  }
  if ($inTok) { $cur.Add($tok.ToString()) }
  if ($cur.Count) { $list.Add([string[]]$cur.ToArray()) }
  , $list
}

if ($args.Count -eq 0) { Show-Help; return }
if ($args.Count -eq 1) { $cmds = Split-Script ([string]$args[0]) } else { $cmds = New-Object Collections.Generic.List[object]; $cmds.Add([string[]]$args) }
$failed = $false
foreach ($c in $cmds) {
  try { Run-Cmd $c }
  catch {
    $e = $_.Exception; while ($e.InnerException) { $e = $e.InnerException }
    "ERR $($c[0]): $($e.Message)"; $failed = $true; break
  }
}
if ($failed) { exit 1 }
