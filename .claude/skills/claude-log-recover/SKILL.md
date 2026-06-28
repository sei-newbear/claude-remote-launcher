---
description: Recover a readable conversation transcript from a Claude Code TUI screen log (script(1)/typescript) when the JSONL transcript is missing or unusable. Use when a background/launched claude session crashed or was stopped and you need its conversation back from the .log, or when any Claude Code `script` log must be decoded into clean text.
---

# claude-log-recover — Claude Code の画面ログから会話を復元する

## いつ使うか

- claude-launcher で起動したセッションが落ち、会話を `.log` から救出したいとき
- そのセッションが **子プロセス起動で JSONL を書いていない**（`~/.claude/projects/...` に transcript が無い）とき
- その他、Claude Code の `script(1)` ログ（typescript）をクリーンなテキストに変換したいとき

JSONL が普通に残っているなら、まずそちら（`~/.claude/projects/<proj>/<id>.jsonl`）を読む方が正確。この skill は **JSONL が無い／壊れている場合の最終手段**。

## なぜ単純なコード除去では駄目か

Claude Code は **再描画TUI**（alt-screen に入り、毎フレーム cursor-home で同じ行を上書き）。`script` の `.log` はそのバイト列なので、`sed` で ANSI を剥がすだけだと:

- 同じ行が何十回も重複する
- カーソル移動・スピナー断片が文字間に割り込み、日本語が「混線」して読めない（例: `owi…` `Fw40` のような断片）

正しい手順は **端末をエミュレートして各フレームを復元 → 連結 → 重複除去**。

## 依存

- 各スクリプト先頭に **PEP 723** の inline metadata で依存を宣言済み。`uv run` が自動解決するので**手動インストール不要**。
- `replay2.py` → `pyte==0.8.2`(端末エミュレータ) / `dedup_frames.py` → 依存なし(標準ライブラリのみ)。
- **サプライチェーン対策**: バージョンは `==` で固定し、推移的依存(`wcwidth`)とハッシュは `scripts/replay2.py.lock` に固定済み。`--locked` で実行するとロックと一致しない限り失敗する。
- 環境は **`uv` 前提**(動作確認済みの経路)。
- pyte を更新したいときは `uv lock --script scripts/replay2.py` で lock を作り直し、動作確認の上でバージョンを上げる。

## 手順

`uv run` で2段に流すだけ（`scripts/` はこの skill ディレクトリ）:

```bash
# 1. 端末再生 → 全フレームのクリーンなスナップショット行を出力 (lock 厳守で pyte を取得)
uv run --locked scripts/replay2.py <入力.log> frames_raw.txt

# 2. UI ノイズ除去 ＋ 順序保存の重複除去 → 読める会話 (依存なし)
uv run scripts/dedup_frames.py frames_raw.txt restored.txt
```

`restored.txt` が成果物。`## USER:` ではなく入力欄マーク `❯` がユーザー発言の目印。

## 仕組み (scripts/)

- **replay2.py** — cursor-home (`ESC[H`) でフレーム分割し、1つの pyte Screen に累積 feed。各フレームで `screen.display` を撮る。pyte が各文字を正しいセルに置くので**文字混線が消える**のが肝。
- **dedup_frames.py** — クリーンなフレーム行から、ステータスバー/スピナー/プログレスバー/起動ロゴ等の UI クロームを正規表現で除去し、正規化キー（空白・装飾記号を落とす）で重複を畳む。char-drop 変種が出たら**長い方を採用**。

## 調整ポイント

- `replay2.py` の `COLS, ROWS`（既定 80×24）— 元の端末サイズに合わせる。CUP の最大 row を `grep -aoP '\x1b\[[0-9]+;[0-9]+H'` で調べて決める。
- `dedup_frames.py` の `NOISE`— Claude Code のバージョンで UI 文言が変わると残骸が出る。残ったノイズのパターンを足す。
- `WINDOW`（既定 40000）— これより離れた同一行は「会話の再掲」として残す。長文末尾で短い行（「か？」等）が稀に重複するのは既知の限界（内容欠落はしない）。

## 注意

- これは**減点法の復元**。長いアシスタント応答の末尾でまれに行が重複する。完全な逐語再現が要るなら JSONL を探すのが先。
- 元 `.log` は消さずに残す（復元は何度でもやり直せるよう、入力は read-only 扱い）。
- 子プロセスで JSONL が出ない問題そのものの回避策は launcher 側のスクリプト（`env -u CLAUDE_CODE_CHILD_SESSION -u CLAUDE_CODE_SESSION_ID`）にある。この skill は「それでも落ちた後」の救出担当。
