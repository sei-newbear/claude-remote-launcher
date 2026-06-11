# claude-launcher

Claude Code をバックグラウンドで起動し、FIFO 経由で駆動・モバイルから操作するツール。

`claude -p`（ヘッドレス/print モード）を使わず、サブスク枠（interactive）のまま外から操作できる。

## なぜこれが要るか

2026-06-15 以降、`claude -p` は従量課金（automation credit pool）に移行した。  
一方 `claude --remote-control` を使った interactive セッションはサブスク枠のまま。

このツールは interactive セッションをバックグラウンドで立ち上げて、外からプロンプトを注入する仕組み。

**なぜ naive な FIFO では動かないか:**  
FIFO の write 端を誰も保持していないと EOF が発生して claude が即終了する。  
`sleep infinity` を write 端のホルダーとして常駐させることでこれを回避している。

## 仕組み

```
sleep infinity > fifo  ← write 端ホルダー (EOF 防止)
        ↓ (FIFO)
script -qfc 'claude --remote-control <name>'  ← 擬似 TTY を与える
        ↑
  echo "prompt" > fifo  ← 外からプロンプト注入
```

- `script`（util-linux）で擬似 TTY を与える: TTY がないと claude は print モードで起動してしまう
- stdin を FIFO にして外部からキー入力を送る
- `--remote-control <name>` で claude.ai / モバイルアプリからも接続できる
- `setsid` でプロセスグループを独立させ、ターミナルを閉じても生き続ける

## 必要なもの

- `claude` CLI（Claude Code, v2.1.51+, Pro/Max/Team/Enterprise）
- `script`（util-linux、Linux 標準）
- `setsid`（util-linux、Linux 標準）
- `bash` 4.0+

## インストール

```bash
git clone https://github.com/sei-newbear/claude-launcher
```

スクリプトを PATH の通った場所に置くか、フルパスで呼ぶ:

```bash
# PATH に追加する場合
export PATH="$PATH:/path/to/claude-launcher/.claude/skills/claude-launcher/scripts"
```

## 使い方

```bash
SCRIPT=".claude/skills/claude-launcher/scripts/claude-launcher.sh"

# 起動
$SCRIPT launch my-session ~/myproject

# 応答確認 (Remote Control active が出たらモバイルから接続可)
$SCRIPT log my-session

# プロンプト送信
$SCRIPT send my-session "テストを全部実行して結果を教えて"

# 起動中セッション一覧
$SCRIPT list

# 停止
$SCRIPT stop my-session
```

セッション名は英数字・ハイフン・アンダースコアのみ使用可（例: `my-project`, `work_20260611`）。

### 状態ディレクトリ

デフォルトはスクリプトと同じリポジトリ内の `.claude/skills/claude-launcher/run/`（gitignore 済み）。  
`CLAUDE_LAUNCHER_STATE` 環境変数で変更できる。

```bash
CLAUDE_LAUNCHER_STATE=/tmp/my-sessions $SCRIPT launch my-session
```

## Claude Code skill として使う

このリポジトリを `claude` で開くと `claude-launcher` skill が有効になり、  
Claude Code 自身がセッションの起動・操作をアシストしてくれる。

## 注意

- `send` 後は応答/処理開始を確認してから次を送る。FIFO 送信は稀に submit されないことがあり、連投すると入力が混線する
- 構造化された応答が欲しい場合は `~/.claude/projects/` 以下の transcript（JSONL）を直接読む
- `stop` はプロセスが実際に消えてから返る（タイムアウト後に SIGKILL）

## License

MIT
