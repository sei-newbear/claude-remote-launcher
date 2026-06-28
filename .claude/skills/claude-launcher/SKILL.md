---
description: Launch and drive a background, mobile-accessible Claude Code session on this machine. Use when the user wants to start an extra claude session that keeps running in the background, send it prompts programmatically, or reach it from a phone via Remote Control — without the metered headless print mode.
---

# claude-launcher — サブスク枠でバックグラウンド claude を起動・駆動する

## なぜこの skill があるか

`claude -p`(ヘッドレス/print)は 2026-06-15 から従量課金になる。一方 interactive セッションはサブスク枠(5h / 7d のレート上限)のまま。この skill は interactive な claude を擬似端末でバックグラウンド起動し、外から駆動 / モバイルから操作するための入口。

## 仕組み (なぜこの工夫が要るか)

- 対話 claude は TTY が無いと print 相当になり落ちる → `script`(util-linux)で擬似端末(pty)を与える
- 外からキー入力を送るため stdin を FIFO にする → `echo > fifo` でプロンプト送信
- `--remote-control <name>` でリレー登録 → claude.ai / モバイルから同じセッションを操作できる
- 消費するのは interactive 枠 = サブスク内。`-p` は使わない

## 使い方

スクリプト `.claude/skills/claude-launcher/scripts/claude-launcher.sh` を呼ぶ:

- 起動: `.claude/skills/claude-launcher/scripts/claude-launcher.sh launch <名前> [作業dir] [--continue | --resume <id>]`
  - `--continue` で直前の会話を自動再開 / `--resume <id>` で session ID 指定で再開
- 再開: `.claude/skills/claude-launcher/scripts/claude-launcher.sh resume <名前>`(保存済み session ID で同じ dir で再開。UUID 不要)
- 送信: `.claude/skills/claude-launcher/scripts/claude-launcher.sh send <名前> "プロンプト"`
- 応答確認: `.claude/skills/claude-launcher/scripts/claude-launcher.sh log <名前>`(画面ログを制御コード除去して表示)
- 一覧: `.claude/skills/claude-launcher/scripts/claude-launcher.sh list`
- 停止+片付け: `.claude/skills/claude-launcher/scripts/claude-launcher.sh stop <名前>`

起動後 `log` に `Remote Control active` が出たら、claude.ai のモバイル/web から `<名前>` セッションに接続できる。

新規起動時に session ID(UUID)を発行して `<名前>.session` に保存するので、`stop` 後でも `resume <名前>` で文脈ごと再開できる(同じ JSONL に追記される)。`list` の行頭マーク: `●` 起動中(プロセス生存・dir 表示) / `⚠` stale(`.pipe` 残骸だがプロセス無し → `stop` で掃除) / `○` 停止済みで再開可能(`resume <名前>`)。

## 注意

- 必ず `--remote-control`(interactive)。`-p` を付けると従量側に乗る
- 応答取得は TUI 画面ログのデコード。構造化された結果が要るなら transcript(`~/.claude/projects/...`)を直接読む
- `send` で**改行を含む複数行**を渡すと TUI が貼り付け(paste)と判定し、`[Pasted text +N lines]` のまま **submit されず入力欄に溜まる**。送るプロンプトは1行にまとめる
- `send` 後は応答/処理開始を確認してから次を送る(連投すると入力が混線する)
- `stop` はプロセスグループごと kill + タイムアウト監視で、実際に終了してから返す(残れば SIGKILL)。複数同時起動時は名前で区別する
- 起動直後に `log` が `/rc connecting…` のまま固まる場合がある。コードのバグではなくリレー側の一時障害なので、URL を直接開く / 数分待って `stop`→`launch` で復帰することが多い
- **操作前に必ず `log` で画面状態を読む**。`/cost` 等のパネルが開いていると、裏でセッションが作業中でも気づけない。パネルや状態を見ずに送ると事故る
- **稼働中セッションに `/clear` を絶対送らない**(会話文脈が消える)。`/cost` 等のパネルを閉じたいときは `/clear` ではなく **Esc**
- `send` は末尾に必ず Enter を付ける作りなので、Esc など**生キーは送れない**。生キーは FIFO に直接書く: `printf '\033' > run/<名前>.pipe`(Esc) / `printf '\033[B' > ...`(↓) など

## 落ちたセッションの会話復元

セッションが落ちても、`run/<名前>.log`(`script` の pty 記録)に全会話が残る。**JSONL が無くてもここから復元できる**(子プロセス起動で JSONL が出ていない場合の唯一の手段)。手順は別 skill **`claude-log-recover`** を参照(単純な ANSI 除去だと文字が混線して読めない。pyte で端末再生する必要がある)。
