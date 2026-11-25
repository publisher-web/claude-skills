// desk.ps1 から使う部品（Win32 の入力・画面の取り込み・画像処理・UI Automation）。
// PowerShell 5.1 の Add-Type（C# 5）でコンパイルされるので、C# 6 以降の書き方（$"" や ?. など）は使わない。
// このファイルを変えると、次に desk.ps1 を動かしたときに自動でコンパイルし直される。
// UI Automation は .NET 版（System.Windows.Automation）より速く取りこぼしも少ない COM 版を使う
// （Interop.UIAutomationClient.dll は desk.ps1 が UIAutomationCore.dll から一度だけ作る）。
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Globalization;
using System.IO;
using System.IO.Compression;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using Interop.UIAutomationClient;

namespace Desk {

public class Mon { public int Index; public bool Primary; public Rectangle Bounds; public Rectangle Work; public int Scale; }
public class Win { public IntPtr Hwnd; public string Title; public int Pid; public string Proc; public Rectangle Rect; public bool Min; public bool Max; }
public class El { public string Type; public string Name; public string Value; public string State; public Rectangle Rect; public long Root; }

public static class N {
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
  [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
  struct MONITORINFOEX { public int cbSize; public RECT rcMonitor; public RECT rcWork; public uint dwFlags; [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string szDevice; }
  [StructLayout(LayoutKind.Sequential)] struct MOUSEINPUT { public int dx, dy; public uint mouseData, dwFlags, time; public IntPtr extra; }
  [StructLayout(LayoutKind.Sequential)] struct KEYBDINPUT { public ushort wVk, wScan; public uint dwFlags, time; public IntPtr extra; }
  [StructLayout(LayoutKind.Explicit)] struct INPUTUNION { [FieldOffset(0)] public MOUSEINPUT mi; [FieldOffset(0)] public KEYBDINPUT ki; }
  [StructLayout(LayoutKind.Sequential)] struct INPUT { public uint type; public INPUTUNION u; }
  [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
  struct PROCESSENTRY32 { public uint dwSize, cntUsage, th32ProcessID; public IntPtr th32DefaultHeapID; public uint th32ModuleID, cntThreads, th32ParentProcessID; public int pcPriClassBase; public uint dwFlags; [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] public string szExeFile; }

  delegate bool EnumWinProc(IntPtr h, IntPtr l);
  delegate bool EnumMonProc(IntPtr m, IntPtr dc, ref RECT r, IntPtr d);

  [DllImport("user32.dll")] static extern bool SetProcessDpiAwarenessContext(IntPtr v);
  [DllImport("user32.dll")] static extern IntPtr SetThreadDpiAwarenessContext(IntPtr v);
  [DllImport("user32.dll")] static extern bool SetProcessDPIAware();
  [DllImport("user32.dll")] static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] static extern uint SendInput(uint n, INPUT[] inputs, int size);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] static extern bool BringWindowToTop(IntPtr h);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int n);
  [DllImport("user32.dll")] static extern bool IsIconic(IntPtr h);
  [DllImport("user32.dll")] static extern bool IsZoomed(IntPtr h);
  [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] static extern bool AttachThreadInput(uint a, uint b, bool attach);
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
  [DllImport("kernel32.dll")] static extern IntPtr GetConsoleWindow();
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] static extern int GetWindowTextLength(IntPtr h);
  [DllImport("user32.dll")] static extern bool EnumWindows(EnumWinProc f, IntPtr l);
  [DllImport("user32.dll")] static extern int GetWindowLong(IntPtr h, int i);
  [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("dwmapi.dll")] static extern int DwmGetWindowAttribute(IntPtr h, int a, out RECT r, int size);
  [DllImport("dwmapi.dll")] static extern int DwmGetWindowAttribute(IntPtr h, int a, out int v, int size);
  [DllImport("user32.dll")] static extern IntPtr WindowFromPoint(POINT p);
  [DllImport("user32.dll")] static extern IntPtr GetAncestor(IntPtr h, uint f);
  [DllImport("user32.dll")] static extern bool PrintWindow(IntPtr h, IntPtr dc, uint f);
  [DllImport("user32.dll")] static extern uint MapVirtualKey(uint c, uint t);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern short VkKeyScan(char c);
  [DllImport("user32.dll")] static extern void keybd_event(byte k, byte s, uint f, IntPtr e);
  [DllImport("user32.dll")] static extern bool EnumDisplayMonitors(IntPtr dc, IntPtr clip, EnumMonProc f, IntPtr d);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern bool GetMonitorInfo(IntPtr m, ref MONITORINFOEX mi);
  [DllImport("shcore.dll")] static extern int GetDpiForMonitor(IntPtr m, int t, out uint x, out uint y);
  [DllImport("user32.dll")] static extern IntPtr GetDC(IntPtr h);
  [DllImport("user32.dll")] static extern int ReleaseDC(IntPtr h, IntPtr dc);
  [DllImport("gdi32.dll")] static extern bool BitBlt(IntPtr d, int x, int y, int w, int h, IntPtr s, int sx, int sy, uint rop);
  [DllImport("kernel32.dll")] static extern IntPtr CreateToolhelp32Snapshot(uint f, uint pid);
  [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern bool Process32First(IntPtr h, ref PROCESSENTRY32 e);
  [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern bool Process32Next(IntPtr h, ref PROCESSENTRY32 e);
  [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);

  // ---- 準備：拡大率（125%など）がモニターごとに違っても、全部「実際のピクセル」でそろえる
  static readonly IntPtr PerMonitorV2 = new IntPtr(-4);
  public static void Init() {
    try { if (!SetProcessDpiAwarenessContext(PerMonitorV2)) SetProcessDPIAware(); } catch { try { SetProcessDPIAware(); } catch { } }
    ThreadDpi();
  }
  static void ThreadDpi() { try { SetThreadDpiAwarenessContext(PerMonitorV2); } catch { } }
  static Rectangle R(RECT r) { return Rectangle.FromLTRB(r.Left, r.Top, r.Right, r.Bottom); }

  // ---- モニター（1 = メイン、ほかは左から順）
  public static List<Mon> Monitors() {
    var list = new List<Mon>();
    EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, (IntPtr m, IntPtr dc, ref RECT rr, IntPtr d) => {
      var mi = new MONITORINFOEX(); mi.cbSize = Marshal.SizeOf(typeof(MONITORINFOEX));
      GetMonitorInfo(m, ref mi);
      uint dx = 96, dy = 96; try { GetDpiForMonitor(m, 0, out dx, out dy); } catch { }
      var mon = new Mon(); mon.Primary = (mi.dwFlags & 1) != 0; mon.Bounds = R(mi.rcMonitor); mon.Work = R(mi.rcWork);
      mon.Scale = (int)Math.Round(dx * 100.0 / 96); list.Add(mon); return true;
    }, IntPtr.Zero);
    list.Sort((a, b) => a.Primary != b.Primary ? (a.Primary ? -1 : 1) : a.Bounds.X != b.Bounds.X ? a.Bounds.X.CompareTo(b.Bounds.X) : a.Bounds.Y.CompareTo(b.Bounds.Y));
    for (int i = 0; i < list.Count; i++) list[i].Index = i + 1;
    return list;
  }
  public static Rectangle Virtual() {
    Rectangle u = Rectangle.Empty;
    foreach (var m in Monitors()) u = u.IsEmpty ? m.Bounds : Rectangle.Union(u, m.Bounds);
    return u;
  }
  public static Mon MonitorOf(Rectangle r) {
    Mon best = null; long bestArea = -1;
    foreach (var m in Monitors()) {
      var i = Rectangle.Intersect(m.Bounds, r); long a = (long)i.Width * i.Height;
      if (a > bestArea) { bestArea = a; best = m; }
    }
    return best;
  }

  // ---- ウィンドウ（手前にあるものから順）
  public static List<Win> Windows() {
    var list = new List<Win>(); var names = ProcNames();
    EnumWindows((h, l) => {
      if (!IsWindowVisible(h)) return true;
      int len = GetWindowTextLength(h); if (len == 0) return true;
      int cloaked = 0; DwmGetWindowAttribute(h, 14, out cloaked, 4); if (cloaked != 0) return true;
      int ex = GetWindowLong(h, -20); if ((ex & 0x80) != 0 && (ex & 0x40000) == 0) return true;
      var sb = new StringBuilder(len + 1); GetWindowText(h, sb, sb.Capacity);
      string title = sb.ToString(); if (title == "Program Manager") return true;
      uint pid; GetWindowThreadProcessId(h, out pid);
      string pn; if (!names.TryGetValue(pid, out pn)) pn = "?";
      var w = new Win(); w.Hwnd = h; w.Title = title; w.Pid = (int)pid; w.Proc = pn; w.Rect = WinRect(h); w.Min = IsIconic(h); w.Max = IsZoomed(h);
      list.Add(w); return true;
    }, IntPtr.Zero);
    return list;
  }
  // 見えている枠（Windows 10/11 の透明な縁を含めない）
  public static Rectangle WinRect(IntPtr h) {
    RECT r; if (DwmGetWindowAttribute(h, 9, out r, Marshal.SizeOf(typeof(RECT))) != 0) GetWindowRect(h, out r);
    return R(r);
  }
  public static int PidOf(IntPtr h) { uint p; GetWindowThreadProcessId(h, out p); return (int)p; }
  public static string TitleOf(IntPtr h) { int n = GetWindowTextLength(h); var sb = new StringBuilder(n + 1); GetWindowText(h, sb, sb.Capacity); return sb.ToString(); }
  public static IntPtr RootAt(int x, int y) { var p = new POINT(); p.X = x; p.Y = y; return GetAncestor(WindowFromPoint(p), 2); }

  // プロセスの一覧（番号 → 名前・親の番号）。Process.GetProcessById より桁違いに速い
  static Dictionary<uint, string> procNames; static Dictionary<uint, uint> procParents;
  static void Snapshot() {
    procNames = new Dictionary<uint, string>(); procParents = new Dictionary<uint, uint>();
    IntPtr snap = CreateToolhelp32Snapshot(2, 0);
    try {
      var e = new PROCESSENTRY32(); e.dwSize = (uint)Marshal.SizeOf(typeof(PROCESSENTRY32));
      if (Process32First(snap, ref e)) do {
        string n = e.szExeFile; if (n.EndsWith(".exe", StringComparison.OrdinalIgnoreCase)) n = n.Substring(0, n.Length - 4);
        procNames[e.th32ProcessID] = n; procParents[e.th32ProcessID] = e.th32ParentProcessID;
      } while (Process32Next(snap, ref e));
    } finally { CloseHandle(snap); }
  }
  static Dictionary<uint, string> ProcNames() { if (procNames == null) Snapshot(); return procNames; }
  // 窓の見えている割合（0〜1。他の窓に隠れていない部分）。clip の中だけで数える
  public static double Visible(IntPtr h, Rectangle clip) {
    var r = Rectangle.Intersect(WinRect(h), clip); if (r.Width <= 0 || r.Height <= 0) return 0;
    int hit = 0, n = 0;
    for (int i = 0; i < 8; i++) for (int j = 0; j < 8; j++) { n++; if (RootAt(r.X + r.Width * (2 * i + 1) / 16, r.Y + r.Height * (2 * j + 1) / 16) == h) hit++; }
    return (double)hit / n;
  }
  // Claude Code 自身が動いている窓（ターミナル・VS Code・Claude アプリ）のプロセス。ここへキー入力しないために使う
  public static int[] HostPids(int start) {
    if (procNames == null) Snapshot();
    var parent = procParents; var names = procNames;
    var winPids = new HashSet<int>();
    EnumWindows((h, l) => { if (IsWindowVisible(h) && GetWindowTextLength(h) > 0) winPids.Add(PidOf(h)); return true; }, IntPtr.Zero);
    var res = new List<int>(); uint cur = (uint)start;
    for (int i = 0; i < 40; i++) {
      uint pp; if (!parent.TryGetValue(cur, out pp) || pp == 0 || pp == cur) break;
      cur = pp; string nm; names.TryGetValue(cur, out nm);
      if (nm != null && nm.Equals("explorer", StringComparison.OrdinalIgnoreCase)) break;
      if (winPids.Contains((int)cur)) { res.Add((int)cur); break; }
    }
    IntPtr cw = GetConsoleWindow();
    if (cw != IntPtr.Zero && IsWindowVisible(cw)) { int p = PidOf(cw); if (!res.Contains(p)) res.Add(p); }
    return res.ToArray();
  }

  // ---- ウィンドウを前面へ（だめなら Alt キーの方法 → スレッドをつなぐ方法の順で試す）
  public static bool Focus(IntPtr h) {
    if (IsIconic(h)) ShowWindow(h, 9);
    if (WaitFg(h, 0)) return true;
    SetForegroundWindow(h);
    if (WaitFg(h, 150)) return true;
    keybd_event(0x12, 0, 0, IntPtr.Zero); keybd_event(0x12, 0, 2, IntPtr.Zero);
    SetForegroundWindow(h);
    if (WaitFg(h, 200)) return true;
    uint me = GetCurrentThreadId(); uint dummy; uint fgT = GetWindowThreadProcessId(GetForegroundWindow(), out dummy);
    bool at = fgT != me && AttachThreadInput(me, fgT, true);
    BringWindowToTop(h); SetForegroundWindow(h);
    if (at) AttachThreadInput(me, fgT, false);
    return WaitFg(h, 400);
  }
  static bool WaitFg(IntPtr h, int ms) {
    for (int t = 0; ; t += 25) {
      IntPtr f = GetForegroundWindow();
      if (f == h || GetAncestor(f, 3) == h) return true;
      if (t >= ms) return false;
      Thread.Sleep(25);
    }
  }

  // ---- 画面の取り込み（CAPTUREBLT で半透明のメニューやツールチップも写す）
  public static Bitmap Capture(Rectangle r) {
    var b = new Bitmap(Math.Max(1, r.Width), Math.Max(1, r.Height), PixelFormat.Format24bppRgb);
    using (var g = Graphics.FromImage(b)) {
      IntPtr dst = g.GetHdc(); IntPtr src = GetDC(IntPtr.Zero);
      BitBlt(dst, 0, 0, r.Width, r.Height, src, r.X, r.Y, 0x00CC0020 | 0x40000000);
      ReleaseDC(IntPtr.Zero, src); g.ReleaseHdc(dst);
    }
    return b;
  }
  // PrintWindow で窓の中身だけを撮る（普通の取り込みで真っ黒・抜けになる窓用）
  public static Bitmap CaptureWindow(IntPtr h) {
    RECT wr; GetWindowRect(h, out wr); Rectangle full = R(wr); Rectangle vis = WinRect(h);
    using (var b = new Bitmap(Math.Max(1, full.Width), Math.Max(1, full.Height), PixelFormat.Format32bppArgb)) {
      using (var g = Graphics.FromImage(b)) { IntPtr dc = g.GetHdc(); PrintWindow(h, dc, 2); g.ReleaseHdc(dc); }
      var crop = new Rectangle(vis.X - full.X, vis.Y - full.Y, vis.Width, vis.Height);
      crop.Intersect(new Rectangle(0, 0, b.Width, b.Height));
      return b.Clone(crop, PixelFormat.Format24bppRgb);
    }
  }
  // 拡大・縮小（縮小は面積平均で文字がつぶれにくい、拡大は双線形）。GDI+ の高品質縮小より10倍以上速い
  public static Bitmap Resize(Bitmap src, int w, int h) {
    w = Math.Max(1, w); h = Math.Max(1, h);
    int W = src.Width, H = src.Height;
    if (w == W && h == H) return src.Clone(new Rectangle(0, 0, W, H), PixelFormat.Format24bppRgb);
    byte[] s = Bytes(src); int ss = s.Length / H;
    int[] xs, xc, ys, yc; float[] xw, yw; int xm, ym;
    Contribs(W, w, out xs, out xc, out xw, out xm); Contribs(H, h, out ys, out yc, out yw, out ym);
    var tmp = new float[w * H * 3];
    System.Threading.Tasks.Parallel.For(0, H, y => {   // 行ごとに CPU のコアで分けて計算する
      int row = y * ss, trow = y * w * 3;
      for (int x = 0; x < w; x++) {
        float b = 0, g = 0, r = 0; int st = xs[x], n = xc[x], wi = x * xm;
        for (int k = 0; k < n; k++) { int p = row + (st + k) * 3; float wt = xw[wi + k]; b += s[p] * wt; g += s[p + 1] * wt; r += s[p + 2] * wt; }
        int t = trow + x * 3; tmp[t] = b; tmp[t + 1] = g; tmp[t + 2] = r;
      }
    });
    var dst = new Bitmap(w, h, PixelFormat.Format24bppRgb);
    var dd = dst.LockBits(new Rectangle(0, 0, w, h), ImageLockMode.WriteOnly, PixelFormat.Format24bppRgb);
    int ds = dd.Stride; var o = new byte[ds * h];
    System.Threading.Tasks.Parallel.For(0, h, y => {
      int st = ys[y], n = yc[y], wi = y * ym, orow = y * ds;
      for (int x = 0; x < w; x++) {
        float b = 0, g = 0, r = 0;
        for (int k = 0; k < n; k++) { int t = ((st + k) * w + x) * 3; float wt = yw[wi + k]; b += tmp[t] * wt; g += tmp[t + 1] * wt; r += tmp[t + 2] * wt; }
        int p = orow + x * 3; o[p] = Clamp(b); o[p + 1] = Clamp(g); o[p + 2] = Clamp(r);
      }
    });
    Marshal.Copy(o, 0, dd.Scan0, o.Length); dst.UnlockBits(dd);
    return dst;
  }
  static byte Clamp(float v) { return v <= 0 ? (byte)0 : v >= 255 ? (byte)255 : (byte)(v + 0.5f); }
  static void Contribs(int n, int m, out int[] start, out int[] count, out float[] wts, out int maxc) {
    start = new int[m]; count = new int[m]; double scale = (double)n / m;
    maxc = scale > 1 ? (int)Math.Ceiling(scale) + 1 : 2; wts = new float[m * maxc];
    for (int i = 0; i < m; i++) {
      if (scale > 1) {
        double a = i * scale, b = Math.Min(n, (i + 1) * scale);
        int j0 = (int)Math.Floor(a), j1 = Math.Min(n - 1, (int)Math.Ceiling(b) - 1), c = 0;
        start[i] = j0;
        for (int j = j0; j <= j1 && c < maxc; j++) { double ov = Math.Min(b, j + 1) - Math.Max(a, j); wts[i * maxc + c] = (float)(Math.Max(0, ov) / (b - a)); c++; }
        count[i] = c;
      } else {
        double c0 = (i + 0.5) * scale - 0.5; int j0 = (int)Math.Floor(c0); double f = c0 - j0;
        if (j0 < 0) { j0 = 0; f = 0; }
        if (j0 >= n - 1) { j0 = n - 1; f = 0; }
        start[i] = j0; wts[i * maxc] = (float)(1 - f);
        if (f > 0) { wts[i * maxc + 1] = (float)f; count[i] = 2; } else count[i] = 1;
      }
    }
  }
  // 速い PNG 保存（GDI+ の PNG は遅いので、Sub フィルター＋最速の圧縮で自前で書く）
  public static void SavePng(Bitmap bmp, string path) {
    int w = bmp.Width, h = bmp.Height; byte[] s = Bytes(bmp); int ss = s.Length / h, rl = w * 3 + 1;
    var raw = new byte[rl * h];
    System.Threading.Tasks.Parallel.For(0, h, y => {
      int o = y * rl, r = y * ss; raw[o] = 1;
      for (int x = 0; x < w; x++) {
        int p = r + x * 3, q = o + 1 + x * 3;
        if (x == 0) { raw[q] = s[p + 2]; raw[q + 1] = s[p + 1]; raw[q + 2] = s[p]; }
        else { raw[q] = (byte)(s[p + 2] - s[p - 1]); raw[q + 1] = (byte)(s[p + 1] - s[p - 2]); raw[q + 2] = (byte)(s[p] - s[p - 3]); }
      }
    });
    byte[] z;
    using (var ms = new MemoryStream()) {
      ms.WriteByte(0x78); ms.WriteByte(0x01);
      using (var df = new DeflateStream(ms, CompressionLevel.Fastest, true)) df.Write(raw, 0, raw.Length);
      uint a = 1, b2 = 0; foreach (byte v in raw) { a = (a + v) % 65521; b2 = (b2 + a) % 65521; }
      uint ad = (b2 << 16) | a; ms.WriteByte((byte)(ad >> 24)); ms.WriteByte((byte)(ad >> 16)); ms.WriteByte((byte)(ad >> 8)); ms.WriteByte((byte)ad);
      z = ms.ToArray();
    }
    var ihdr = new byte[13]; BE(ihdr, 0, (uint)w); BE(ihdr, 4, (uint)h); ihdr[8] = 8; ihdr[9] = 2;
    using (var fs = File.Create(path)) {
      fs.Write(new byte[] { 137, 80, 78, 71, 13, 10, 26, 10 }, 0, 8);
      Chunk(fs, "IHDR", ihdr); Chunk(fs, "IDAT", z); Chunk(fs, "IEND", new byte[0]);
    }
  }
  static void BE(byte[] b, int o, uint v) { b[o] = (byte)(v >> 24); b[o + 1] = (byte)(v >> 16); b[o + 2] = (byte)(v >> 8); b[o + 3] = (byte)v; }
  static uint[] crcTable;
  static void Chunk(Stream fs, string type, byte[] data) {
    if (crcTable == null) {
      crcTable = new uint[256];
      for (uint n = 0; n < 256; n++) { uint c = n; for (int k = 0; k < 8; k++) c = (c & 1) != 0 ? 0xEDB88320u ^ (c >> 1) : c >> 1; crcTable[n] = c; }
    }
    var len = new byte[4]; BE(len, 0, (uint)data.Length); fs.Write(len, 0, 4);
    var t = Encoding.ASCII.GetBytes(type); fs.Write(t, 0, 4); fs.Write(data, 0, data.Length);
    uint crc = 0xFFFFFFFF;
    foreach (byte v in t) crc = crcTable[(crc ^ v) & 0xFF] ^ (crc >> 8);
    foreach (byte v in data) crc = crcTable[(crc ^ v) & 0xFF] ^ (crc >> 8);
    var cb = new byte[4]; BE(cb, 0, crc ^ 0xFFFFFFFF); fs.Write(cb, 0, 4);
  }
  // OCR 用：BGRA の並び（Windows の OCR にそのまま渡せる）
  public static byte[] Bgra(Bitmap b) {
    var d = b.LockBits(new Rectangle(0, 0, b.Width, b.Height), ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
    var buf = new byte[d.Stride * b.Height]; Marshal.Copy(d.Scan0, buf, 0, buf.Length); b.UnlockBits(d); return buf;
  }
  public static void Fill(Bitmap b, Rectangle r) { using (var g = Graphics.FromImage(b)) g.FillRectangle(Brushes.Black, r); }
  public static string Color(int x, int y) {
    using (var b = Capture(new Rectangle(x, y, 1, 1))) { var c = b.GetPixel(0, 0); return "#" + c.R.ToString("X2") + c.G.ToString("X2") + c.B.ToString("X2"); }
  }

  // ---- 2枚の画像の違い。"0"（変化なし）か "変化した割合%|x,y,w,h|..."（大きい順に最大4つ）
  public static string Diff(Bitmap a, Bitmap b, int cell, int thr) {
    int w = a.Width, h = a.Height;
    if (w != b.Width || h != b.Height) return "size";
    byte[] pa = Bytes(a), pb = Bytes(b); int stride = pa.Length / h;
    int cw = (w + cell - 1) / cell, ch = (h + cell - 1) / cell;
    var g = new bool[cw * ch]; long n = 0;
    for (int y = 0; y < h; y++) {
      int row = y * stride, gy = (y / cell) * cw;
      for (int x = 0; x < w; x++) {
        int i = row + x * 3;
        int d = Math.Abs(pa[i] - pb[i]) + Math.Abs(pa[i + 1] - pb[i + 1]) + Math.Abs(pa[i + 2] - pb[i + 2]);
        if (d > thr) { n++; g[gy + x / cell] = true; }
      }
    }
    if (n == 0) return "0";
    var seen = new bool[g.Length]; var boxes = new List<int[]>();
    for (int i = 0; i < g.Length; i++) {
      if (!g[i] || seen[i]) continue;
      int x0 = int.MaxValue, y0 = int.MaxValue, x1 = -1, y1 = -1;
      var q = new Queue<int>(); q.Enqueue(i); seen[i] = true;
      while (q.Count > 0) {
        int c = q.Dequeue(), cx = c % cw, cy = c / cw;
        x0 = Math.Min(x0, cx); y0 = Math.Min(y0, cy); x1 = Math.Max(x1, cx); y1 = Math.Max(y1, cy);
        for (int dy = -2; dy <= 2; dy++) for (int dx = -2; dx <= 2; dx++) {
          int nx = cx + dx, ny = cy + dy; if (nx < 0 || ny < 0 || nx >= cw || ny >= ch) continue;
          int j = ny * cw + nx; if (g[j] && !seen[j]) { seen[j] = true; q.Enqueue(j); }
        }
      }
      boxes.Add(new int[] { x0 * cell, y0 * cell, Math.Min(w, (x1 + 1) * cell) - x0 * cell, Math.Min(h, (y1 + 1) * cell) - y0 * cell });
    }
    boxes.Sort((p, q2) => ((long)q2[2] * q2[3]).CompareTo((long)p[2] * p[3]));
    var sb = new StringBuilder((100.0 * n / ((long)w * h)).ToString("0.0", CultureInfo.InvariantCulture));
    for (int k = 0; k < Math.Min(4, boxes.Count); k++) sb.Append("|" + boxes[k][0] + "," + boxes[k][1] + "," + boxes[k][2] + "," + boxes[k][3]);
    if (boxes.Count > 4) sb.Append("|+" + (boxes.Count - 4));
    return sb.ToString();
  }
  static byte[] Bytes(Bitmap b) {
    var d = b.LockBits(new Rectangle(0, 0, b.Width, b.Height), ImageLockMode.ReadOnly, PixelFormat.Format24bppRgb);
    var buf = new byte[d.Stride * b.Height]; Marshal.Copy(d.Scan0, buf, 0, buf.Length); b.UnlockBits(d); return buf;
  }

  // ---- 目盛り（画像の px = (フレーム座標 - o) * k。ラベルはフレーム座標）
  public static void Grid(Bitmap img, double ox, double oy, double k) {
    double[] steps = { 5, 10, 20, 25, 50, 100, 200, 250, 500, 1000, 2000 };
    double step = 2000; foreach (double s in steps) if (s * k >= 50) { step = s; break; }
    using (var g = Graphics.FromImage(img)) using (var pen = new Pen(System.Drawing.Color.FromArgb(120, 255, 0, 200)))
    using (var f = new Font("Segoe UI", 10f, FontStyle.Bold, GraphicsUnit.Pixel))
    using (var bg = new SolidBrush(System.Drawing.Color.FromArgb(170, 0, 0, 0))) using (var fg = new SolidBrush(System.Drawing.Color.Yellow)) {
      for (double v = Math.Ceiling(ox / step) * step; (v - ox) * k < img.Width; v += step) {
        float x = (float)((v - ox) * k); g.DrawLine(pen, x, 0, x, img.Height); Label(g, f, bg, fg, ((int)v).ToString(), x + 2, 1);
      }
      for (double v = Math.Ceiling(oy / step) * step; (v - oy) * k < img.Height; v += step) {
        float y = (float)((v - oy) * k); g.DrawLine(pen, 0, y, img.Width, y); Label(g, f, bg, fg, ((int)v).ToString(), 1, y + 1);
      }
    }
  }
  static void Label(Graphics g, Font f, Brush bg, Brush fg, string s, float x, float y) {
    var sz = g.MeasureString(s, f); g.FillRectangle(bg, x, y, sz.Width, sz.Height - 1); g.DrawString(s, f, fg, x, y);
  }
  // ---- 番号つきの枠（r は画像上の x,y,w,h を並べたもの）
  public static void Marks(Bitmap img, int[] r) {
    var cols = new[] { System.Drawing.Color.FromArgb(230, 0, 90), System.Drawing.Color.FromArgb(0, 110, 230), System.Drawing.Color.FromArgb(0, 150, 60), System.Drawing.Color.FromArgb(190, 90, 0) };
    using (var g = Graphics.FromImage(img)) using (var f = new Font("Segoe UI", 11f, FontStyle.Bold, GraphicsUnit.Pixel)) {
      for (int i = 0; i * 4 + 3 < r.Length; i++) {
        var c = cols[i % cols.Length];
        using (var pen = new Pen(c, 1)) using (var br = new SolidBrush(c)) {
          g.DrawRectangle(pen, r[i * 4], r[i * 4 + 1], r[i * 4 + 2], r[i * 4 + 3]);
          string s = (i + 1).ToString(); var sz = g.MeasureString(s, f);
          float lx = r[i * 4], ly = r[i * 4 + 1] - sz.Height + 3; if (ly < 0) ly = r[i * 4 + 1];
          g.FillRectangle(br, lx, ly, sz.Width - 3, sz.Height - 3); g.DrawString(s, f, Brushes.White, lx - 1, ly - 2);
        }
      }
    }
  }

  // ---- マウス
  static INPUT MouseIn(uint flags, int dx, int dy, int data) {
    var i = new INPUT(); i.type = 0; i.u.mi.dx = dx; i.u.mi.dy = dy; i.u.mi.mouseData = unchecked((uint)data); i.u.mi.dwFlags = flags; return i;
  }
  static void Send(params INPUT[] ins) { SendInput((uint)ins.Length, ins, Marshal.SizeOf(typeof(INPUT))); }
  static Rectangle virt = Rectangle.Empty;
  // 本物のマウス移動として送り（ゲームなども反応する）、最後に SetCursorPos で1pxもずれないように合わせる
  public static void MoveTo(int x, int y) {
    if (virt.IsEmpty) virt = Virtual();
    int nx = (int)Math.Round((x - virt.X) * 65535.0 / Math.Max(1, virt.Width - 1));
    int ny = (int)Math.Round((y - virt.Y) * 65535.0 / Math.Max(1, virt.Height - 1));
    Send(MouseIn(0x0001 | 0x8000 | 0x4000, nx, ny, 0));
    SetCursorPos(x, y);
  }
  public static void Click(int x, int y, string mode) {
    uint down = 0x2, up = 0x4; int n = 1;
    if (mode == "right") { down = 0x8; up = 0x10; } else if (mode == "middle") { down = 0x20; up = 0x40; } else if (mode == "double") n = 2;
    MoveTo(x, y); Thread.Sleep(50);
    for (int k = 0; k < n; k++) { Send(MouseIn(down, 0, 0, 0)); Thread.Sleep(30); Send(MouseIn(up, 0, 0, 0)); if (k + 1 < n) Thread.Sleep(70); }
  }
  public static void Drag(int x1, int y1, int x2, int y2) {
    MoveTo(x1, y1); Thread.Sleep(60); Send(MouseIn(0x2, 0, 0, 0)); Thread.Sleep(120);
    for (int s = 1; s <= 15; s++) { MoveTo(x1 + (x2 - x1) * s / 15, y1 + (y2 - y1) * s / 15); Thread.Sleep(16); }
    Thread.Sleep(120); Send(MouseIn(0x4, 0, 0, 0));
  }
  public static void Scroll(int x, int y, int notches, bool horizontal) {
    MoveTo(x, y); Thread.Sleep(40);
    int sign = Math.Sign(notches);
    for (int k = 0; k < Math.Abs(notches); k++) { Send(MouseIn(horizontal ? 0x1000u : 0x0800u, 0, 0, 120 * sign)); Thread.Sleep(35); }
  }

  // ---- キーボード（"ctrl+s"、"tab tab enter"、"w:800" = Wを0.8秒押し続ける）
  static Dictionary<string, int> keyNames;
  static void InitKeys() {
    if (keyNames != null) return;
    var d = new Dictionary<string, int>();
    d["ctrl"] = 0x11; d["control"] = 0x11; d["shift"] = 0x10; d["alt"] = 0x12; d["win"] = 0x5B;
    d["enter"] = 0x0D; d["return"] = 0x0D; d["esc"] = 0x1B; d["escape"] = 0x1B; d["tab"] = 0x09; d["space"] = 0x20;
    d["backspace"] = 0x08; d["bs"] = 0x08; d["delete"] = 0x2E; d["del"] = 0x2E; d["insert"] = 0x2D; d["ins"] = 0x2D;
    d["home"] = 0x24; d["end"] = 0x23; d["pageup"] = 0x21; d["pgup"] = 0x21; d["pagedown"] = 0x22; d["pgdn"] = 0x22;
    d["up"] = 0x26; d["down"] = 0x28; d["left"] = 0x25; d["right"] = 0x27; d["capslock"] = 0x14;
    d["printscreen"] = 0x2C; d["prtsc"] = 0x2C; d["apps"] = 0x5D; d["menu"] = 0x5D;
    d["kanji"] = 0x19; d["henkan"] = 0x1C; d["muhenkan"] = 0x1D;
    for (int i = 1; i <= 24; i++) d["f" + i] = 0x6F + i;
    keyNames = d;
  }
  static int Resolve(string p, List<int> mods) {
    int vk; string l = p.ToLowerInvariant();
    if (keyNames.TryGetValue(l, out vk)) return vk;
    if (l == "plus") p = "+"; else if (l == "minus") p = "-"; else if (l == "comma") p = ","; else if (l == "period") p = ".";
    if (p.Length == 1) {
      char c = p[0];
      if (c >= 'a' && c <= 'z') return c - 32;
      if ((c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')) return c;
      short s = VkKeyScan(c);
      if (s != -1) {
        int sh = (s >> 8) & 0xFF;
        if ((sh & 1) != 0) mods.Add(0x10); if ((sh & 2) != 0) mods.Add(0x11); if ((sh & 4) != 0) mods.Add(0x12);
        return s & 0xFF;
      }
    }
    throw new ArgumentException("unknown key: " + p);
  }
  public static void Keys(string spec) {
    InitKeys();
    foreach (string tok in spec.Split(new[] { ' ', '\t' }, StringSplitOptions.RemoveEmptyEntries)) {
      string t = tok; int hold = 0; int c = t.LastIndexOf(':');
      if (c > 0 && c < t.Length - 1 && int.TryParse(t.Substring(c + 1), out hold)) t = t.Substring(0, c); else hold = 0;
      bool plusKey = t == "+" || t.EndsWith("++");
      var parts = new List<string>(t.Split('+')); parts.RemoveAll(string.IsNullOrEmpty);
      var mods = new List<int>(); int key;
      if (plusKey) { foreach (var p in parts) mods.Add(Resolve(p, mods)); key = Resolve("+", mods); }
      else {
        if (parts.Count == 0) throw new ArgumentException("empty key");
        for (int i = 0; i < parts.Count - 1; i++) mods.Add(Resolve(parts[i], mods));
        key = Resolve(parts[parts.Count - 1], mods);
      }
      foreach (int m in mods) KeyEv(m, false);
      if (mods.Count > 0) Thread.Sleep(15);
      KeyEv(key, false); Thread.Sleep(hold > 0 ? hold : 30); KeyEv(key, true);
      for (int i = mods.Count - 1; i >= 0; i--) KeyEv(mods[i], true);
      Thread.Sleep(40);
    }
  }
  static readonly int[] extended = { 0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27, 0x28, 0x2C, 0x2D, 0x2E, 0x5B, 0x5C, 0x5D, 0x6F, 0x90 };
  static void KeyEv(int vk, bool up) {
    var i = new INPUT(); i.type = 1; i.u.ki.wVk = (ushort)vk; i.u.ki.wScan = (ushort)MapVirtualKey((uint)vk, 0);
    uint f = up ? 2u : 0u; if (Array.IndexOf(extended, vk) >= 0) f |= 1; i.u.ki.dwFlags = f; Send(i);
  }
  // 文字をそのまま打つ（貼り付けできない場所用。日本語もIMEを通さずに入る）
  public static void TypeText(string s) {
    int n = 0;
    foreach (char ch in s) {
      if (ch == '\r') continue;
      if (ch == '\n') { KeyEv(0x0D, false); KeyEv(0x0D, true); }
      else if (ch == '\t') { KeyEv(0x09, false); KeyEv(0x09, true); }
      else { var a = new INPUT(); a.type = 1; a.u.ki.wScan = ch; a.u.ki.dwFlags = 4; var b = a; b.u.ki.dwFlags = 4 | 2; Send(a, b); }
      if (++n % 16 == 0) Thread.Sleep(10);
    }
  }

  // ---- UI Automation（ボタンなどの部品を文字で取り出す。時間がかかりすぎたら、そこまでの結果を返す）
  // 番号は UIA の決まった値（UIA_..._PropertyId / UIA_..._ControlTypeId）
  const int P_Rect = 30001, P_Type = 30003, P_Name = 30005, P_Enabled = 30010, P_Help = 30013, P_Offscreen = 30022,
    P_Value = 30045, P_Selected = 30079, P_Toggle = 30086;
  static readonly int[] interactiveTypes = { 50000, 50002, 50003, 50004, 50005, 50007, 50011, 50013, 50015, 50016, 50031, 50019, 50024, 50029, 50035 };
  // 窓ごとに別のスレッドで同時に調べる。1つ目（一番手前）の窓は時間切れまで待ち、ほかの窓はそのあと少しだけ待つ
  // （エクスプローラーなど遅い窓があっても、目当ての窓の分はすぐ返す）
  public static List<El> Elements(long[] roots, bool all, int timeoutMs, Rectangle clip) {
    var res = new List<El>(); var threads = new List<Thread>();
    foreach (long hv in roots) {
      IntPtr h = new IntPtr(hv);
      var th = new Thread(() => { ThreadDpi(); try { CollectRoot(h, all, clip, res); } catch { } });
      th.IsBackground = true; th.Start(); threads.Add(th);
    }
    var sw = Stopwatch.StartNew();
    if (threads.Count > 0) threads[0].Join(timeoutMs);
    int deadline = Math.Min(timeoutMs, (int)sw.ElapsedMilliseconds + 400);
    for (int i = 1; i < threads.Count; i++) { int left = deadline - (int)sw.ElapsedMilliseconds; if (left > 0) threads[i].Join(left); }
    lock (res) return new List<El>(res);
  }
  static void CollectRoot(IntPtr h, bool all, Rectangle clip, List<El> res) {
    var u = new CUIAutomation8();
    var root = u.ElementFromHandle(h);
    var cr = u.CreateCacheRequest(); cr.AutomationElementMode = AutomationElementMode.AutomationElementMode_None;
    foreach (int p in new[] { P_Rect, P_Type, P_Name, P_Enabled, P_Help, P_Value, P_Selected, P_Toggle }) cr.AddProperty(p);
    IUIAutomationCondition c;
    if (all) c = u.CreateNotCondition(u.CreatePropertyCondition(P_Name, ""));
    else {
      var cs = new IUIAutomationCondition[interactiveTypes.Length];
      for (int i = 0; i < cs.Length; i++) cs[i] = u.CreatePropertyCondition(P_Type, interactiveTypes[i]);
      c = u.CreateOrConditionFromArray(cs);
    }
    c = u.CreateAndCondition(u.CreatePropertyCondition(P_Offscreen, false), c);
    var arr = root.FindAllBuildCache(TreeScope.TreeScope_Descendants, c, cr);
    for (int i = 0; i < arr.Length; i++) {
      var e = arr.GetElement(i);
      var br = e.GetCachedPropertyValue(P_Rect) as double[];
      if (br == null || br.Length < 4 || br[2] < 2 || br[3] < 2) continue;
      var r = new Rectangle((int)br[0], (int)br[1], (int)br[2], (int)br[3]);
      int cx = r.X + r.Width / 2, cy = r.Y + r.Height / 2;
      if (!clip.Contains(cx, cy) || RootAt(cx, cy) != h) continue; // 画面外・他の窓に隠れているものは除く
      var el = new El(); el.Rect = r; el.Root = h.ToInt64();
      object ct = e.GetCachedPropertyValue(P_Type); el.Type = TypeName(ct is int ? (int)ct : 0);
      el.Name = Clean(e.GetCachedPropertyValue(P_Name) as string, 50);
      if (el.Name.Length == 0) el.Name = Clean(e.GetCachedPropertyValue(P_Help) as string, 50);
      string vs = e.GetCachedPropertyValue(P_Value) as string;
      if (!string.IsNullOrEmpty(vs) && vs != el.Name) el.Value = Clean(vs, 40);
      var st = new List<string>();
      object t = e.GetCachedPropertyValueEx(P_Toggle, 1);   // 1 = 対応していなければ「なし」を返してもらう
      if (t is int) st.Add((int)t == 1 ? "on" : (int)t == 0 ? "off" : "mixed");
      object s = e.GetCachedPropertyValueEx(P_Selected, 1);
      if (s is bool && (bool)s) st.Add("sel");
      object en = e.GetCachedPropertyValue(P_Enabled);
      if (en is bool && !(bool)en) st.Add("disabled");
      el.State = string.Join(",", st.ToArray());
      lock (res) res.Add(el);
    }
  }
  // クリックする場所にある部品の名前（クリック前の確認用）
  public static string HitTest(int x, int y, int timeoutMs) {
    string res = null;
    var th = new Thread(() => {
      ThreadDpi();
      try {
        var u = new CUIAutomation8(); var pt = new tagPOINT(); pt.x = x; pt.y = y;
        var e = u.ElementFromPoint(pt);
        string type = TypeName(e.CurrentControlType), name = Clean(e.CurrentName, 40);
        res = name.Length > 0 ? type + " \"" + name + "\"" : type;
        // 名前のない部品（入力欄など）は、名前のある親を添える
        var walker = u.ControlViewWalker;
        for (int up = 0; name.Length == 0 && up < 3; up++) {
          e = walker.GetParentElement(e); if (e == null) break;
          name = Clean(e.CurrentName, 40); if (name.Length > 0) res += " (in " + TypeName(e.CurrentControlType) + " \"" + name + "\")";
        }
      } catch { }
    });
    th.IsBackground = true; th.Start(); th.Join(timeoutMs);
    return res;
  }
  // 2つの文字列の違いの数（置き換え・抜け・余分の文字の数。レーベンシュタイン距離）
  public static int Distance(string a, string b) {
    var prev = new int[b.Length + 1]; var cur = new int[b.Length + 1];
    for (int j = 0; j <= b.Length; j++) prev[j] = j;
    for (int i = 1; i <= a.Length; i++) {
      cur[0] = i;
      for (int j = 1; j <= b.Length; j++) cur[j] = Math.Min(Math.Min(prev[j] + 1, cur[j - 1] + 1), prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1));
      var t = prev; prev = cur; cur = t;
    }
    return prev[b.Length];
  }
  static string TypeName(int id) {
    switch (id) {
      case 50000: return "btn"; case 50002: return "chk"; case 50003: return "combo"; case 50004: return "edit";
      case 50005: return "link"; case 50006: return "img"; case 50007: return "item"; case 50008: return "list";
      case 50009: return "menubar"; case 50010: return "menubar"; case 50011: return "menu"; case 50012: return "progress";
      case 50013: return "radio"; case 50014: return "scrollbar"; case 50015: return "slider"; case 50016: return "spin";
      case 50018: return "tabs"; case 50019: return "tab"; case 50020: return "text"; case 50021: return "toolbar";
      case 50022: return "tooltip"; case 50023: return "treeview"; case 50024: return "tree"; case 50026: return "group";
      case 50029: return "cell"; case 50030: return "doc"; case 50031: return "split"; case 50032: return "window";
      case 50033: return "pane"; case 50035: return "header"; case 50037: return "titlebar";
      default: return "el";
    }
  }
  static string Clean(string s, int max) {
    if (string.IsNullOrEmpty(s)) return "";
    s = Regex.Replace(s.Replace("﻿", "").Replace("​", ""), @"\s+", " ").Trim().Replace("\"", "'");   // 見えない文字は消す
    return s.Length > max ? s.Substring(0, max - 1) + "…" : s;
  }
}
}
