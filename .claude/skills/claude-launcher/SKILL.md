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

- 起動: `.claude/skills/claude-launcher/scripts/claude-launcher.sh launch <名前> [作業dir]`
- 送信: `.claude/skills/claude-launcher/scripts/claude-launcher.sh send <名前> "プロンプト"`
- 応答確認: `.claude/skills/claude-launcher/scripts/claude-launcher.sh log <名前>`(画面ログを制御コード除去して表示)
- 一覧: `.claude/skills/claude-launcher/scripts/claude-launcher.sh list`
- 停止+片付け: `.claude/skills/claude-launcher/scripts/claude-launcher.sh stop <名前>`

起動後 `log` に `Remote Control active` が出たら、claude.ai のモバイル/web から `<名前>` セッションに接続できる。

## 注意

- 必ず `--remote-control`(interactive)。`-p` を付けると従量側に乗る
- 応答取得は TUI 画面ログのデコード。構造化された結果が要るなら transcript(`~/.claude/projects/...`)を直接読む
- `send` 後は応答/処理開始を確認してから次を送る(FIFO 送信は稀に submit されず未送信になる。連投すると入力が混線する)
- `stop` はプロセスグループごと kill + タイムアウト監視で、実際に終了してから返す(残れば SIGKILL)。複数同時起動時は名前で区別する
