# claude-skills

[Claude Code](https://claude.com/claude-code) 用のスキル集です。

## desktop-control — Windows の画面を見て操作する

Claude Code が Windows のデスクトップアプリを操作できるようになります。
窓の一覧・切り替え、ボタンなどの部品一覧、文字で探してクリック、文字入力、キー操作、スクリーンショット、画面の文字読み取り（OCR）。

「画面を見て」「〇〇をクリックして」「このアプリを操作して」と頼むと使われます。

### 必要なもの

- Windows 10 / 11（標準の Windows PowerShell 5.1 と .NET Framework だけで動きます。追加インストール不要）
- Claude Code

### インストール

**方法 1: プラグインとして（おすすめ）** — Claude Code の中で:

```
/plugin marketplace add publisher-web/claude-skills
/plugin install desktop-control@publisher-web
```

**方法 2: スキルフォルダに直接入れる（`dsk` コマンドも PATH に入ります）** — PowerShell で:

```powershell
irm https://raw.githubusercontent.com/publisher-web/claude-skills/main/install.ps1 | iex
```

インストール後、Claude Code を再起動してください。

### 仕組み

| 役目 | 使っているもの |
|---|---|
| 画面を撮る | GDI の BitBlt（隠れた窓・黒く写る窓は PrintWindow） |
| ボタンや入力欄を名前で探す | Windows の UI Automation（スクリーンリーダーと同じ仕組み） |
| 画像の文字を読む | Windows 標準の OCR（Windows.Media.Ocr、日本語・英語） |
| クリック・キー入力 | Win32 の SendInput |

画像は高くつくので、まず文字（UI Automation / OCR）で画面を把握し、スクショは必要なときだけ撮るよう Claude に指示しています。
初回だけ C# 部品をコンパイルします（数秒、`%LOCALAPPDATA%\claude-desk` にキャッシュ）。

### 安全のため

- Claude Code 自身の窓にはキー入力しません。ほかの人が PC を触って前面の窓が変わったら、入力を止めます。
- 購入・送信・削除・公開・パスワード入力などの取り消せない操作の前には、ユーザーに確認するよう指示しています。
- それでも実際にマウスとキーボードを動かす道具です。操作中は様子を見てください。

## License

MIT
