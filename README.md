# claude-remote-launcher

Claude Code から別の Claude Code セッションをバックグラウンドで起動する skill。起動したセッションはスマホや web からどこでも操作できる。

## 使い方

このリポジトリを Claude Code で開くだけで skill が有効になる。あとは Claude に話しかけるだけ。

**起動**
> 「~/myproject でセッションを立てて」

Claude がセッションを起動してセッション名を返す。

**接続**

[claude.ai](https://claude.ai) またはモバイルアプリからセッション名で接続する。
外出先のスマホからでも、ブラウザからでも操作できる。

**停止**
> 「セッションを止めて」

Claude がプロセスを終了して後片付けする。

## おまけ: コマンド送信

web やモバイルアプリ経由ではできない操作も、Claude 経由でバックグラウンドセッションに直接送れる。

> 「my-session に `/add-dir ~/otherproject` を送って」

`/add-dir` などのスラッシュコマンドや任意のプロンプトをバックグラウンドセッションに注入できる。

## セットアップ

**必要なもの:** `claude` CLI（Pro/Max/Team/Enterprise, v2.1.51+）、`script`、`setsid`（どちらも Linux 標準）

```bash
git clone https://github.com/sei-newbear/claude-remote-launcher
cd claude-remote-launcher
claude  # このディレクトリで Claude Code を起動するだけで skill が有効になる
```

## 仕組み

Claude Code は TTY がないとヘッドレスモードになってしまう。このツールは `script` コマンドで擬似 TTY を与えつつ、stdin を FIFO にすることで外部からプロンプトを注入できるようにしている。`--remote-control` でセッションを Anthropic のリレーに登録することで、ポート開放や VPN なしに web・モバイルからアクセスできる。

**補足:** interactive モードで動くためサブスク枠を消費し、従量課金の automation pool は使わない。

## ライセンス

MIT
