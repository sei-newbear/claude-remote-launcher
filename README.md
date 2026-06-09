# claude-launcher

claude を「起動・駆動する」ための個人ツール置き場(xp-harness とは別。XP の進め方の規律ではなく個人生産性ツールなので分離)。

- `.claude/skills/claude-launcher/scripts/claude-launcher.sh` — サブスク枠の claude をバックグラウンド起動 / FIFO 駆動 / モバイル(Remote Control)接続する
- `.claude/skills/claude-launcher/` — この dir を `claude` で開いたとき、上記スクリプトの使い方を案内する skill

用途: 出先でモバイルから触れる claude を立てる / claude を外部からプログラム的に駆動する(`claude -p` の従量化を避けつつ)。
