#!/usr/bin/env python3
# /// script
# requires-python = ">=3.9"
# dependencies = ["pyte==0.8.2"]
# ///
"""
再描画TUI(alt-screen, 毎フレームcursor-homeで上書き)の typescript を復元する。
方針:
  1. cursor-home (ESC[H / ESC[1;1H) を境にフレーム分割
  2. 1つの pyte Screen に累積で feed し、各フレームで画面をクリーンに snapshot
     → pyte が各文字を正しいセルに置くので regex 方式の文字混線が消える
  3. 全フレームの行を連結し、順序保存の近似重複除去で会話を再構成

依存は上の PEP 723 ブロック (pyte==0.8.2)。推移的依存とハッシュは replay2.py.lock に固定。
使い方: uv run --locked replay2.py <入力.log> <出力frames.txt>
"""
import sys, re
import pyte

COLS, ROWS = 80, 24

def main(src, dst):
    raw = open(src, "rb").read()
    text = raw.decode("utf-8", errors="replace")
    text = re.sub(r"Script (started|done) on .*?(\r?\n|$)", "", text)

    screen = pyte.Screen(COLS, ROWS)
    stream = pyte.Stream(screen)

    # cursor-home で分割（区切り自体は次フレーム先頭に残す）
    HOME = re.compile(r"(\x1b\[(?:1;1)?H)")
    parts = HOME.split(text)

    frames = []
    buf = ""
    for piece in parts:
        if HOME.fullmatch(piece):
            if buf:
                stream.feed(buf)
                buf = ""
            stream.feed(piece)
            frames.append(list(screen.display))
        else:
            buf += piece
    if buf:
        stream.feed(buf)
        frames.append(list(screen.display))

    # 全フレームの行を順に集める
    all_lines = []
    for fr in frames:
        for line in fr:
            all_lines.append(line.rstrip())

    open(dst, "w").write("\n".join(all_lines))
    print(f"frames: {len(frames)}, raw snapshot lines: {len(all_lines)} → {dst}")

if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
