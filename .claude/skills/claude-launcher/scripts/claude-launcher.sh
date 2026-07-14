#!/usr/bin/env bash
# claude-launcher.sh — サブスク(interactive)枠の claude をバックグラウンド起動し、
# FIFO 経由で駆動 / モバイル(Remote Control)から操作する。
# claude -p (2026-06-15 から従量課金) を使わず interactive 枠で回すための仕組み。
#
# v2: UUID primary key
#   - ファイルは <uuid>.pipe/.log/.pids/.dir で管理
#   - セッション名は Claude Code の JSONL (custom-title) から読む (ランチャー側に持たない)
#   - --remote-control には launch 時の <name> を使う (Remote Control の初期表示名)
#   - 旧式 (<name>.pipe 等) は後方互換として継続サポート
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE="${CLAUDE_LAUNCHER_STATE:-$SCRIPT_DIR/../run}"
mkdir -p "$STATE"

UUID_RE='^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'

usage() {
  cat <<USAGE
Usage:
  claude-launcher.sh launch <name> [dir] [--continue | --resume <uuid>]  起動 (dir 既定=\$PWD)
                                           --continue: 直前の会話を自動再開 / --resume: UUID で再開
  claude-launcher.sh resume <uuid>         停止済みセッションを uuid で再開
  claude-launcher.sh send   <uuid> <text>  起動中セッションにプロンプト送信 (Enter 付き)
  claude-launcher.sh log    <uuid>         セッションの画面ログ (制御コード除去) を表示
  claude-launcher.sh list                  セッション一覧
  claude-launcher.sh stop   <uuid>         /exit で graceful 終了を試み、タイムアウトなら kill
  (<uuid> は 8 文字以上の前方一致短縮形も可。旧式セッション名も引き続き使用可)
USAGE
}

require() { command -v "$1" >/dev/null || { echo "ERROR: '$1' が必要" >&2; exit 1; }; }

gen_uuid() {
  if command -v uuidgen >/dev/null; then uuidgen | tr '[:upper:]' '[:lower:]'
  elif [ -r /proc/sys/kernel/random/uuid ]; then cat /proc/sys/kernel/random/uuid
  else python3 -c "import uuid; print(uuid.uuid4())"
  fi
}

is_uuid() { [[ "$1" =~ $UUID_RE ]]; }

validate_name() {
  [[ "$1" =~ ^[a-zA-Z0-9_-]+$ ]] || { echo "ERROR: name は英数字・ハイフン・アンダースコアのみ: '$1'" >&2; exit 1; }
}

# key (UUID / UUID前方一致 / 旧式名) → ファイルベース名として使う文字列を返す
resolve() {
  local key="$1"
  is_uuid "$key" && echo "$key" && return
  # 8文字以上の hex/hyphen → 新式ファイルから前方一致で解決
  if [[ ${#key} -ge 8 && "$key" =~ ^[0-9a-f-]+$ ]]; then
    local f b
    for f in "$STATE"/*.pipe "$STATE"/*.dir; do
      [ -e "$f" ] || continue
      b=$(basename "${f%.*}")
      is_uuid "$b" && [[ "$b" == "$key"* ]] && echo "$b" && return
    done
  fi
  echo "$key"  # 旧式名をそのまま返す
}

# UUID → セッション名 (JSONL custom-title の最新値)
get_name() {
  local uuid="$1" dir="$2"
  local pkey; pkey=$(echo "$dir" | sed 's|/|-|g')
  local jsonl="$HOME/.claude/projects/$pkey/$uuid.jsonl"
  [ -f "$jsonl" ] || { echo ""; return; }
  grep '"type":"custom-title"' "$jsonl" 2>/dev/null | tail -1 | jq -r '.customTitle // empty' 2>/dev/null || echo ""
}

# PID 取得: UUID → --session-id で検索 / 旧式名 → --remote-control で検索
claude_pid() {
  local key="$1"
  if is_uuid "$key"; then
    ps -eo pid,comm,args | awk -v u="$key" \
      '$2=="claude" && $0 ~ ("session-id " u "([[:space:]]|$)") {print $1; exit}'
  else
    ps -eo pid,comm,args | awk -v n="$key" \
      '$2=="claude" && $0 ~ ("remote-control " n "([[:space:]]|$)") {print $1; exit}'
  fi
}

# ── 新式起動 (UUID primary key) ──────────────────────────────────────────────
_launch_new() {
  local name="$1" dir="$2" uuid="$3" resume_opt="${4:-}"
  local fifo="$STATE/$uuid.pipe"
  local log="$STATE/$uuid.log"
  local pidf="$STATE/$uuid.pids"
  local dirf="$STATE/$uuid.dir"

  [ -e "$fifo" ] && { echo "ERROR: '$uuid' は既に起動中" >&2; exit 1; }

  echo "$dir" > "$dirf"
  mkfifo "$fifo"
  setsid bash -c "exec sleep infinity > '$fifo'" >/dev/null 2>&1 &
  local hpid=$!
  local sid_opt="--session-id $uuid"
  [[ "$resume_opt" == "--resume "* ]] && sid_opt=""
  setsid bash -c "cd '$dir' && env -u CLAUDE_CODE_CHILD_SESSION -u CLAUDE_CODE_SESSION_ID \
    script -qfc 'claude $resume_opt $sid_opt --name $name --remote-control $name --permission-mode auto' \
    '$log' < '$fifo'" >/dev/null 2>&1 &
  local spid=$!
  echo "$hpid $spid" > "$pidf"

  echo "launched '$name' (dir=$dir)"
  echo "  log  : $log"
  echo "  uuid : $uuid  (再開: claude-launcher.sh resume $uuid)"
  echo "  起動まで数秒。'claude-launcher.sh log $uuid' で 'Remote Control active' を確認 → モバイルから接続可"
}

# ── 旧式起動 (name primary key) ─ --continue 用および後方互換 ─────────────────
_launch_old() {
  local name="$1" dir="$2" resume_opt="${3:-}"
  local fifo="$STATE/$name.pipe"
  local log="$STATE/$name.log"
  local pidf="$STATE/$name.pids"
  local sessf="$STATE/$name.session"

  [ -e "$fifo" ] && { echo "ERROR: '$name' は既に存在。先に stop して下さい" >&2; exit 1; }

  local sid="" sid_opt=""
  if [ -z "$resume_opt" ]; then
    if [ -f "$sessf" ]; then
      local old_sid; read -r old_sid < "$sessf"
      echo "WARN: '$name' に既存 session $old_sid あり。新規起動で上書きします" >&2
    fi
    sid="$(gen_uuid)"
    [ -n "$sid" ] && sid_opt="--session-id $sid"
  elif [[ "$resume_opt" == "--resume "* ]]; then
    sid="${resume_opt#--resume }"
  fi

  mkfifo "$fifo"
  setsid bash -c "exec sleep infinity > '$fifo'" >/dev/null 2>&1 &
  local hpid=$!
  setsid bash -c "cd '$dir' && env -u CLAUDE_CODE_CHILD_SESSION -u CLAUDE_CODE_SESSION_ID \
    script -qfc 'claude $resume_opt $sid_opt --remote-control $name --permission-mode auto' \
    '$log' < '$fifo'" >/dev/null 2>&1 &
  local spid=$!
  echo "$hpid $spid" > "$pidf"
  [ -n "$sid" ] && printf '%s\n%s\n' "$sid" "$dir" > "$sessf"

  echo "launched '$name' (dir=$dir)"
  echo "  log    : $log"
  [ -n "$sid" ] && echo "  session: $sid  (再開: claude-launcher.sh resume $name)"
  [ -z "$sid"  ] && echo "  session: (--continue のため ID 未記録。再開は --resume <id> で)"
  echo "  起動まで数秒。'claude-launcher.sh log $name' で 'Remote Control active' を確認 → モバイルから接続可"
}

cmd_launch() {
  local name="$1"; shift
  validate_name "$name"
  local dir="$PWD" resume_opt=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --continue)
        [ -z "$resume_opt" ] || { echo "ERROR: --continue と --resume は併用不可" >&2; exit 1; }
        resume_opt="--continue"; shift;;
      --resume)
        [ -z "$resume_opt" ] || { echo "ERROR: --continue と --resume は併用不可" >&2; exit 1; }
        [ -n "${2:-}" ] || { echo "ERROR: --resume には UUID が必要" >&2; exit 1; }
        validate_name "$2"
        resume_opt="--resume $2"; shift 2;;
      --*) echo "ERROR: 不明なオプション: $1" >&2; exit 1;;
      *) dir="$1"; shift;;
    esac
  done
  require script; require claude; require setsid

  # --continue は UUID を事前確定できないため旧式で起動
  if [[ "$resume_opt" == "--continue" ]]; then
    _launch_old "$name" "$dir" "$resume_opt"
    return
  fi

  # UUID を確定: --resume <uuid> はそのまま使用、新規は生成
  local uuid
  if [[ "$resume_opt" == "--resume "* ]]; then
    uuid="${resume_opt#--resume }"
  else
    uuid="$(gen_uuid)"
  fi

  _launch_new "$name" "$dir" "$uuid" "$resume_opt"
}

cmd_resume() {
  local key="$1"
  local uuid; uuid=$(resolve "$key")

  if is_uuid "$uuid"; then
    local dirf="$STATE/$uuid.dir"
    [ -f "$dirf" ] || { echo "ERROR: '$uuid' の dir 情報がありません: $dirf" >&2; exit 1; }
    local dir; read -r dir < "$dirf"
    local rcname; rcname=$(basename "$dir")
    _launch_new "$rcname" "$dir" "$uuid" "--resume $uuid"
  else
    # 旧式: <name>.session から再開
    local name="$key"
    local sessf="$STATE/$name.session"
    [ -f "$sessf" ] || { echo "ERROR: '$name' の保存済み session がありません: $sessf" >&2; exit 1; }
    local sid sdir
    { read -r sid; read -r sdir; } < "$sessf"
    [ -n "$sid" ]  || { echo "ERROR: session ファイルに ID がありません: $sessf" >&2; exit 1; }
    [ -n "$sdir" ] || sdir="$PWD"
    _launch_old "$name" "$sdir" "--resume $sid"
  fi
}

cmd_send() {
  local key="$1"; shift
  local id; id=$(resolve "$key")
  local fifo="$STATE/$id.pipe"
  [ -p "$fifo" ] || { echo "ERROR: '$key' は起動していない (fifo: $fifo)" >&2; exit 1; }
  printf '\025' > "$fifo"          # Ctrl-U: 前の未送信プロンプトをクリア
  printf '%s\r' "$*" > "$fifo"     # プロンプト + Enter
  echo "sent to '$key': $*"
}

cmd_log() {
  local key="$1"
  local id; id=$(resolve "$key")
  local log="$STATE/$id.log"
  [ -f "$log" ] || { echo "ERROR: log なし: $log" >&2; exit 1; }
  sed -r "s/\x1b\[[0-9;?]*[a-zA-Z]//g; s/\x1b\][^\x07]*\x07//g; s/\r/\n/g" "$log" | grep -avE '^[[:space:]]*$' || true
}

cmd_list() {
  shopt -s nullglob
  local found=0
  declare -A seen

  _entry_new() {
    local mark="$1" uuid="$2" dir="$3" note="${4:-}"
    local log="$STATE/$uuid.log" when="" name=""
    [ -f "$log" ] && when=$(date -r "$log" "+%m/%d %H:%M" 2>/dev/null)
    [ -n "$dir" ] && name=$(get_name "$uuid" "$dir")
    local display="${name:-[${uuid:0:8}]}"
    printf '  %s %-28s' "$mark" "$display"
    [ -n "$when" ] && printf ' %s' "$when"
    [ -n "$dir"  ] && printf ' 📁 %s' "$dir"
    printf ' [%s]' "$uuid"
    [ -n "$note" ] && printf ' %s' "$note"
    printf '\n'
  }

  _entry_old() {
    local mark="$1" n="$2" sdir="$3" note="${4:-}" sid="" when=""
    local sessf="$STATE/$n.session" log="$STATE/$n.log"
    [ -f "$sessf" ] && { read -r sid < "$sessf"; [ -z "$sdir" ] && sdir=$(sed -n '2p' "$sessf"); }
    [ -f "$log"   ] && when=$(date -r "$log" "+%m/%d %H:%M" 2>/dev/null)
    printf '  %s %-28s' "$mark" "$n"
    [ -n "$when" ] && printf ' %s' "$when"
    [ -n "$sdir" ] && printf ' 📁 %s' "$sdir"
    [ -n "$sid"  ] && printf ' [%s]' "$sid"
    [ -n "$note" ] && printf ' %s' "$note"
    printf '\n'
  }

  # .pipe ファイルを走査 (新式 UUID + 旧式 name 両対応)
  for p in "$STATE"/*.pipe; do
    local b; b=$(basename "$p" .pipe)
    seen[$b]=1; found=1
    local cpid; cpid=$(claude_pid "$b")
    if is_uuid "$b"; then
      local dirf="$STATE/$b.dir" dir=""
      [ -f "$dirf" ] && read -r dir < "$dirf"
      if [ -n "$cpid" ]; then
        _entry_new "●" "$b" "$(readlink "/proc/$cpid/cwd" 2>/dev/null || echo "$dir")"
      else
        _entry_new "⚠" "$b" "$dir" "(stale: stop で掃除)"
      fi
    else
      if [ -n "$cpid" ]; then
        _entry_old "●" "$b" "$(readlink "/proc/$cpid/cwd" 2>/dev/null)"
      else
        _entry_old "⚠" "$b" "" "(stale: stop で掃除)"
      fi
    fi
  done

  # 停止済み新式: <uuid>.dir のみ (pipe なし)
  for dirf in "$STATE"/*.dir; do
    local b; b=$(basename "$dirf" .dir)
    is_uuid "$b"          || continue
    [ -n "${seen[$b]:-}" ] && continue
    local dir; read -r dir < "$dirf"
    _entry_new "○" "$b" "$dir"; found=1
  done

  # 停止済み旧式: <name>.session のみ (pipe なし)
  for sessf in "$STATE"/*.session; do
    local n; n=$(basename "$sessf" .session)
    [ -n "${seen[$n]:-}" ] && continue
    _entry_old "○" "$n" ""; found=1
  done

  [ "$found" = 0 ] && echo "  (セッションなし)" || true
}

cmd_stop() {
  local key="$1"
  local id; id=$(resolve "$key")
  local fifo="$STATE/$id.pipe"
  local pidf="$STATE/$id.pids"
  local log="$STATE/$id.log"

  # graceful: /exit 送信 → 最大 10 秒待つ
  if [ -p "$fifo" ] && [ -n "$(claude_pid "$id")" ]; then
    printf '\025' > "$fifo"
    printf '/exit\r' > "$fifo"
    for i in $(seq 1 20); do [ -z "$(claude_pid "$id")" ] && break; sleep 0.5; done
  fi
  # SIGTERM → SIGKILL フォールバック (pkill -f は自爆事故があるので使わない)
  if [ -n "$(claude_pid "$id")" ]; then
    [ -f "$pidf" ] && for p in $(cat "$pidf"); do kill -- "-$p" 2>/dev/null || true; done
    for i in $(seq 1 20); do [ -z "$(claude_pid "$id")" ] && break; sleep 0.5; done
    local left; left="$(claude_pid "$id")"
    [ -n "$left" ] && kill -9 $left 2>/dev/null || true
  fi
  # holder (sleep infinity) 等の残存プロセスを片付ける
  [ -f "$pidf" ] && for p in $(cat "$pidf"); do kill -- "-$p" 2>/dev/null || true; done
  rm -f "$fifo" "$pidf"

  echo "stopped '$key'"
  [ -f "$log" ] && echo "  log : $log"
  if is_uuid "$id"; then
    [ -f "$STATE/$id.dir" ] && echo "  uuid: $id  (再開: claude-launcher.sh resume $id)"
  else
    local sessf="$STATE/$id.session" sid=""
    [ -f "$sessf" ] && { read -r sid < "$sessf"; }
    [ -n "$sid" ] && echo "  session : $sid  (再開: claude-launcher.sh resume $id)"
  fi
}

cmd_migrate() {
  local dry=false
  [ "${1:-}" = "--dry-run" ] && dry=true
  $dry && echo "[DRY RUN] 実際のファイル操作は行いません"

  shopt -s nullglob
  local any=0

  for sessf in "$STATE"/*.session; do
    local name; name=$(basename "$sessf" .session)
    is_uuid "$name" && continue  # すでに新式

    local uuid sdir
    { read -r uuid; read -r sdir; } < "$sessf" 2>/dev/null || continue
    [ -n "$uuid" ] || { echo "  skip $name (UUID なし)"; continue; }
    is_uuid "$uuid" || { echo "  skip $name (UUID 不正: $uuid)"; continue; }

    if [ -e "$STATE/$uuid.pipe" ] || [ -f "$STATE/$uuid.dir" ]; then
      echo "  skip $name (uuid $uuid は既存)"; continue
    fi

    echo "  migrate $name → $uuid"
    any=1

    # .dir ファイル作成
    echo "    dir   : (新規) $uuid.dir = $sdir"
    $dry || echo "$sdir" > "$STATE/$uuid.dir"

    # .pipe を探す: まず <name>.pipe、なければプロセスの cmdline から逆引き
    local pipe_src=""
    if [ -p "$STATE/$name.pipe" ]; then
      pipe_src="$STATE/$name.pipe"
    else
      local pid; pid=$(ps -eo pid,args | awk -v u="$uuid" '$0 ~ ("session-id " u) {print $1; exit}')
      if [ -n "$pid" ]; then
        local rc_name
        rc_name=$(tr '\0' ' ' < /proc/$pid/cmdline 2>/dev/null \
          | grep -o 'remote-control [^ ]*' | awk '{print $2}')
        [ -n "$rc_name" ] && [ -p "$STATE/$rc_name.pipe" ] && pipe_src="$STATE/$rc_name.pipe"
      fi
    fi

    if [ -n "$pipe_src" ]; then
      echo "    pipe  : $(basename "$pipe_src") → $uuid.pipe"
      $dry || mv "$pipe_src" "$STATE/$uuid.pipe"
    else
      echo "    pipe  : (見つからず — スキップ)"
    fi

    if [ -f "$STATE/$name.log" ]; then
      echo "    log   : $name.log → $uuid.log"
      $dry || mv "$STATE/$name.log" "$STATE/$uuid.log"
    fi
    if [ -f "$STATE/$name.pids" ]; then
      echo "    pids  : $name.pids → $uuid.pids"
      $dry || mv "$STATE/$name.pids" "$STATE/$uuid.pids"
    fi

    echo "    session: $name.session → (削除、uuid.dir に統合)"
    $dry || rm -f "$sessf"
  done

  [ "$any" = 0 ] && echo "  移行対象なし (すべて新式または UUID なし)" || true
}

[ $# -ge 1 ] || { usage; exit 1; }
sub="$1"; shift || true
case "${sub:-}" in
  launch)  [ $# -ge 1 ] || { usage; exit 1; }; cmd_launch "$@";;
  resume)  [ $# -ge 1 ] || { usage; exit 1; }; cmd_resume "$@";;
  send)    [ $# -ge 2 ] || { usage; exit 1; }; cmd_send "$@";;
  log)     [ $# -ge 1 ] || { usage; exit 1; }; cmd_log "$@";;
  list)    cmd_list;;
  stop)    [ $# -ge 1 ] || { usage; exit 1; }; cmd_stop "$@";;
  migrate) cmd_migrate;;
  *) usage; exit 1;;
esac
