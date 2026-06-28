#!/usr/bin/env bash
# claude-launcher.sh — サブスク(interactive)枠の claude をバックグラウンド起動し、
# FIFO 経由で駆動 / モバイル(Remote Control)から操作する。
# claude -p (2026-06-15 から従量課金) を使わず interactive 枠で回すための仕組み。
#
# 仕組み:
#   - 対話 claude は TTY が無いと print 相当で落ちる → `script`(util-linux)で擬似TTY(pty)を与える
#   - 外からキー入力するため stdin を FIFO に → `echo > fifo` でプロンプト送信
#   - `--remote-control <name>` でリレー登録 → claude.ai / モバイルから同セッションを操作可能
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE="${CLAUDE_LAUNCHER_STATE:-$SCRIPT_DIR/../run}"
mkdir -p "$STATE"

usage() {
  cat <<USAGE
Usage:
  claude-launcher.sh launch <name> [dir] [--continue | --resume <id>]  起動 (dir 既定=\$PWD)
                                           --continue: 直前の会話を自動再開 / --resume: session ID で再開
  claude-launcher.sh resume <name>         保存済み session ID で <name> を同じ dir で再開 (UUID 不要)
  claude-launcher.sh send   <name> <text>  起動中セッションにプロンプト送信 (Enter 付き)
  claude-launcher.sh log    <name>         セッションの画面ログ (制御コード除去) を表示
  claude-launcher.sh list                  起動中セッション一覧 (保存済み session ID も表示)
  claude-launcher.sh stop   <name>         /exit で graceful 終了を試み、タイムアウトなら kill。log/session は残す
USAGE
}

require() { command -v "$1" >/dev/null || { echo "ERROR: '$1' が必要" >&2; exit 1; }; }

gen_uuid() {
  if command -v uuidgen >/dev/null; then uuidgen
  elif [ -r /proc/sys/kernel/random/uuid ]; then cat /proc/sys/kernel/random/uuid
  else echo ""; fi
}

validate_name() {
  [[ "$1" =~ ^[a-zA-Z0-9_-]+$ ]] || { echo "ERROR: name は英数字・ハイフン・アンダースコアのみ使えます: '$1'" >&2; exit 1; }
}

cmd_launch() {
  local name="$1"; shift
  validate_name "$name"
  local dir="$PWD" resume_opt=""
  # dir (位置引数) と再開フラグ (--continue / --resume <id>) をパース
  while [ $# -gt 0 ]; do
    case "$1" in
      --continue)
        [ -z "$resume_opt" ] || { echo "ERROR: --continue と --resume は併用不可" >&2; exit 1; }
        resume_opt="--continue"; shift;;
      --resume)
        [ -z "$resume_opt" ] || { echo "ERROR: --continue と --resume は併用不可" >&2; exit 1; }
        [ -n "${2:-}" ] || { echo "ERROR: --resume には session ID が必要" >&2; exit 1; }
        validate_name "$2"   # シェル文字列に埋め込むのでインジェクション防止に検証
        resume_opt="--resume $2"; shift 2;;
      --*) echo "ERROR: 不明なオプション: $1" >&2; exit 1;;
      *) dir="$1"; shift;;
    esac
  done
  require script; require claude; require setsid
  local fifo="$STATE/$name.pipe"
  local log="$STATE/$name.log"
  local pidf="$STATE/$name.pids"
  local sessf="$STATE/$name.session"
  [ -e "$fifo" ] && { echo "ERROR: '$name' は既に存在。先に stop して下さい" >&2; exit 1; }
  # session ID を確定させる。新規起動は UUID を自前生成して --session-id で固定 → 後で再開できる。
  # --resume <id> は既存 ID をそのまま記録。--continue は直近会話なので ID を事前確定できない。
  local sid="" sid_opt=""
  if [ -z "$resume_opt" ]; then
    if [ -f "$sessf" ]; then
      local old_sid; read -r old_sid < "$sessf"
      echo "WARN: '$name' に既存 session $old_sid あり。新規起動で上書きします (再開なら: resume $name)" >&2
    fi
    sid="$(gen_uuid)"
    [ -n "$sid" ] && sid_opt="--session-id $sid"
  elif [[ "$resume_opt" == "--resume "* ]]; then
    sid="${resume_opt#--resume }"
  fi
  mkfifo "$fifo"
  # 書き込み側を開けっ放しにして EOF を防ぐ holder (setsid で独立セッション=グループリーダー)
  setsid bash -c "exec sleep infinity > '$fifo'" >/dev/null 2>&1 &
  local hpid=$!
  # pty を与えて claude を detached 起動。stdin は FIFO、画面は log に記録
  # 注意1: env -u は必須。親が claude セッション内だと CLAUDE_CODE_CHILD_SESSION /
  #   CLAUDE_CODE_SESSION_ID を継ぎ、子が「親の子セッション」扱いされて standalone な
  #   JSONL transcript を書かない → resume も効かなくなる。この2変数だけ外す(他は維持)。
  # 注意2: env の直後に exec を付けないこと。exec はシェルビルトインで env からは
  #   コマンドとして見えず env: 'exec': No such file or directory で即死する。env 自身が exec する。
  setsid bash -c "cd '$dir' && env -u CLAUDE_CODE_CHILD_SESSION -u CLAUDE_CODE_SESSION_ID script -qfc 'claude $resume_opt $sid_opt --remote-control $name --permission-mode auto' '$log' < '$fifo'" >/dev/null 2>&1 &
  local spid=$!
  echo "$hpid $spid" > "$pidf"
  # session ID と dir を保存 → 'resume <name>' / '--resume <id>' で復元できる (1行目=ID, 2行目=dir)
  [ -n "$sid" ] && printf '%s\n%s\n' "$sid" "$dir" > "$sessf"
  echo "launched '$name' (dir=$dir)"
  echo "  log : $log"
  [ -n "$sid" ] && echo "  session : $sid  (再開: claude-launcher.sh resume $name)"
  [ -z "$sid" ] && echo "  session : (--continue のため ID 未記録。再開は --resume <id> で)"
  echo "  起動まで数秒。'claude-launcher.sh log $name' で 'Remote Control active' を確認 → モバイルから接続可"
}

cmd_resume() {
  local name="$1"
  validate_name "$name"
  local sessf="$STATE/$name.session"
  [ -f "$sessf" ] || { echo "ERROR: '$name' の保存済み session がありません: $sessf" >&2; exit 1; }
  local sid sdir
  { read -r sid; read -r sdir; } < "$sessf"
  [ -n "$sid" ] || { echo "ERROR: session ファイルに ID がありません: $sessf" >&2; exit 1; }
  [ -n "$sdir" ] || sdir="$PWD"
  cmd_launch "$name" "$sdir" --resume "$sid"
}

cmd_send() {
  local name="$1"; shift
  validate_name "$name"
  local fifo="$STATE/$name.pipe"
  [ -p "$fifo" ] || { echo "ERROR: '$name' は起動していない" >&2; exit 1; }
  printf '\025' > "$fifo"          # 入力ボックスをクリア (Ctrl-U): 前の未送信プロンプトとの混線を防ぐ
  printf '%s\r' "$*" > "$fifo"     # プロンプト + Enter
  echo "sent to '$name': $*"
}

cmd_log() {
  local name="$1"
  validate_name "$name"
  local log="$STATE/$name.log"
  [ -f "$log" ] || { echo "ERROR: log なし: $log" >&2; exit 1; }
  sed -r "s/\x1b\[[0-9;?]*[a-zA-Z]//g; s/\x1b\][^\x07]*\x07//g; s/\r/\n/g" "$log" | grep -avE '^[[:space:]]*$' || true
}

cmd_list() {
  shopt -s nullglob
  local found=0 p n sessf cpid
  declare -A seen
  claude_pid() { ps -eo pid,comm,args | awk -v n="$1" '$2=="claude" && $0 ~ ("remote-control " n "([[:space:]]|$)") {print $1; exit}'; }
  # 1 行表示 ($1=mark, $2=name, $3=dir(任意), $4=note(任意))
  print_entry() {
    local mark="$1" n="$2" sdir="$3" note="${4:-}" sid="" when=""
    local sessf="$STATE/$n.session" log="$STATE/$n.log"
    [ -f "$sessf" ] && { read -r sid < "$sessf"; [ -z "$sdir" ] && sdir=$(sed -n '2p' "$sessf"); }
    [ -f "$log" ] && when=$(date -r "$log" "+%m/%d %H:%M" 2>/dev/null)
    printf '  %s %-28s' "$mark" "$n"
    [ -n "$when" ] && printf ' %s' "$when"
    [ -n "$sdir" ] && printf ' 📁 %s' "$sdir"
    [ -n "$sid" ]  && printf ' [%s]' "$sid"
    [ -n "$note" ] && printf ' %s' "$note"
    printf '\n'
  }
  # .pipe あり → 実際に claude プロセスが生きているかで判定
  for p in "$STATE"/*.pipe; do
    n=$(basename "$p" .pipe); seen[$n]=1; found=1
    cpid=$(claude_pid "$n")
    if [ -n "$cpid" ]; then
      print_entry "●" "$n" "$(readlink "/proc/$cpid/cwd" 2>/dev/null)"   # 起動中: cwd を表示
    else
      print_entry "⚠" "$n" "" "(stale: stop で掃除)"                     # .pipe 残骸 (プロセス無)
    fi
  done
  # .session のみ → 停止済みで再開可能 → resume <name> で復元
  for sessf in "$STATE"/*.session; do
    n=$(basename "$sessf" .session)
    [ -n "${seen[$n]:-}" ] && continue
    print_entry "○" "$n" ""; found=1
  done
  [ "$found" = 0 ] && echo "  (セッションなし)" || true
}

cmd_stop() {
  local name="$1"
  validate_name "$name"
  local fifo="$STATE/$name.pipe"
  local pidf="$STATE/$name.pids"
  local log="$STATE/$name.log"
  alive_pids() { ps -eo pid,comm,args | awk -v n="$name" '$2=="claude" && $0 ~ ("remote-control " n "([[:space:]]|$)") {print $1}'; }
  # まず /exit を送って graceful shutdown を試みる (最大 10 秒待つ)
  if [ -p "$fifo" ] && [ -n "$(alive_pids)" ]; then
    printf '\025' > "$fifo"
    printf '/exit\r' > "$fifo"
    for i in $(seq 1 20); do [ -z "$(alive_pids)" ] && break; sleep 0.5; done
  fi
  # まだ生きていれば SIGTERM → SIGKILL にフォールバック (pkill -f は自爆事故があるので使わない)
  if [ -n "$(alive_pids)" ]; then
    if [ -f "$pidf" ]; then
      local p
      for p in $(cat "$pidf"); do kill -- "-$p" 2>/dev/null || true; done
    fi
    for i in $(seq 1 20); do [ -z "$(alive_pids)" ] && break; sleep 0.5; done
    local left; left="$(alive_pids)"
    [ -n "$left" ] && kill -9 $left 2>/dev/null || true
  fi
  # holder (sleep infinity) 等の残存プロセスを片付ける
  if [ -f "$pidf" ]; then
    local p
    for p in $(cat "$pidf"); do kill -- "-$p" 2>/dev/null || true; done
  fi
  # .session は残す (再開ポイント)。pipe/pids だけ片付ける。
  rm -f "$fifo" "$pidf"
  echo "stopped '$name'"
  [ -f "$log" ] && echo "  log : $log"
  local sessf="$STATE/$name.session" sid=""
  [ -f "$sessf" ] && { read -r sid < "$sessf"; }
  [ -n "$sid" ] && echo "  session : $sid  (再開: claude-launcher.sh resume $name)"
}

[ $# -ge 1 ] || { usage; exit 1; }
sub="$1"; shift || true
case "${sub:-}" in
  launch) [ $# -ge 1 ] || { usage; exit 1; }; cmd_launch "$@";;
  resume) [ $# -ge 1 ] || { usage; exit 1; }; cmd_resume "$@";;
  send)   [ $# -ge 2 ] || { usage; exit 1; }; cmd_send "$@";;
  log)    [ $# -ge 1 ] || { usage; exit 1; }; cmd_log "$@";;
  list)   cmd_list;;
  stop)   [ $# -ge 1 ] || { usage; exit 1; }; cmd_stop "$@";;
  *) usage; exit 1;;
esac
