#!/usr/bin/env python3
# /// script
# requires-python = ">=3.9"
# dependencies = []
# ///
"""
pyte で再生したクリーンなフレーム行列 (frames_raw.txt) から
UI ノイズを除去し、順序保存の重複除去で会話を再構成する。
フレームはクリーンなので char-drop 変種がほぼ無く、正規化キーの exact 一致で畳める。

依存なし (標準ライブラリのみ)。replay2.py の出力を入力にする。
使い方: uv run dedup_frames.py <frames.txt> <出力restored.txt>
"""
import sys, re

# UI クローム（固定文字列・パターン）
NOISE = re.compile("|".join([
    r"^[─━]{3,}",                                  # 区切り線
    r"claude-remote-la[a-z]*ucher\s*─*$",          # セッション名付き区切り
    r"^\s*❯\s*$",                                  # 空の入力ボックス
    r"(Opus|Sonnet|Haiku|Fable) [0-9].*📁",        # ステータスバー
    r"[░█▰]{3,}.*%",                               # プログレスバー
    r"^\s*5h .*🔄.*7d ",                            # 利用量バー
    r"⏵⏵ auto mode on",
    r"^\s*✻\s*Working…|^\s*[✶✻✽✢·*]\s+\w+…",       # スピナー
    r"\(\d+m?\s*\d*s? ·.*thinking\)|· thinking\)",
    r"⎿\s*Tip: Use /btw",
    r"^\s*current work\s*$",
    r"/rc active|/rc connecting",
    r"⏱\s|⏱️",
    r"^\s*\$[0-9]+\.[0-9]+\s",
    # 起動ロゴ / バナー
    r"▐▛███▜▌|▝▜█████▛▘|▘▘ ▝▝|Claude Code v[0-9]",
    r"● high · /effort|Checking for updates|Try \"how do I log",
    r"new task\? /clear to save",
    # サブエージェントの毎秒ティック（時間だけ更新される行）。ツール詳細行は残す
    r"^\s*[◯●○]\s+\S.*\s+\d+s\s*$",
    r"^\s*\(ctrl\+b to run in background\)\s*$",
    r"^\s*Running…\s*$",
]))

def is_noise(line):
    s = line.strip()
    if not s:
        return True
    return bool(NOISE.search(s))

def normkey(line):
    # 行頭の装飾記号と全空白を落として比較キーに
    s = re.sub(r"\s+", "", line)
    s = s.lstrip("●✻✶✽✢·*-⎿ ")
    return s

def main(src, dst):
    lines = open(src).read().split("\n")

    # ノイズ除去
    lines = [l.rstrip() for l in lines if not is_noise(l)]

    # 順序保存・正規化キーでの重複除去（keep-longest）
    seen = {}          # normkey -> index in out
    out = []
    WINDOW = 40000     # この行数より離れた同一行は別出現として残す（会話の再掲）
    for line in lines:
        key = normkey(line)
        if not key:
            continue
        if len(key) <= 2:
            # 短すぎる行は直前と同じならスキップ
            if out and out[-1] == line:
                continue
            out.append(line); continue
        if key in seen and len(out) - seen[key] < WINDOW:
            idx = seen[key]
            # より長い（完全な）変種を採用
            if len(line) > len(out[idx]):
                out[idx] = line
            seen[key] = seen[key]  # 位置は維持
            continue
        seen[key] = len(out)
        out.append(line)

    # 連続空行圧縮
    final = []
    blank = 0
    for l in out:
        if l.strip() == "":
            blank += 1
            if blank <= 1:
                final.append("")
        else:
            blank = 0
            final.append(l)

    open(dst, "w").write("\n".join(final))
    print(f"in {len(lines)} → out {len(final)} lines, {sum(len(x) for x in final):,} chars → {dst}")

if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
