#!/usr/bin/env bash
set -uo pipefail

SCRIPT_NAME=$(basename "$0")
VERSION="4.2.0"

DEFAULT_ADDR="127.0.0.1:8080"
DEFAULT_RC_ADDR="127.0.0.1:5573"
DEFAULT_READ_AHEAD="128M"
DEFAULT_DIR_CACHE_TIME="9999h"
DEFAULT_VFS_CACHE_MODE="full"
DEFAULT_RAM_CACHE_ROOT="/dev/shm"
RAM_PERCENT=80
POLL_INTERVAL=1
IDLE_POLLS_REQUIRED=2

TMP_CACHE_DIR=""
RCLONE_LOG_FILE=""
rclone_pid=""
cleanup_done=0
shutdown_requested=0
force_stop_requested=0
idle_polls=0
TTY_STATE=""
last_render=""
startup_ready=0

cleanup() {
  local rc=$?

  if [[ -n "$TTY_STATE" ]]; then
    stty "$TTY_STATE" 2>/dev/null || true
  fi

  printf '\r\033[2K' 2>/dev/null || true

  if (( cleanup_done == 0 )); then
    cleanup_done=1
    if [[ -n "$TMP_CACHE_DIR" && -d "$TMP_CACHE_DIR" ]]; then
      rm -rf -- "$TMP_CACHE_DIR"
    fi
  fi

  exit "$rc"
}
trap cleanup EXIT HUP TERM

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Error: required command not found: $1" >&2
    exit 1
  }
}

human_mib() {
  local mib=$1
  local gib=$((mib / 1024))
  if (( gib > 0 )); then
    printf "%d GiB" "$gib"
  else
    printf "%d MiB" "$mib"
  fi
}

choose_remote() {
  mapfile -t REMOTES < <(rclone listremotes 2>/dev/null | sed 's/:$//' | sed '/^$/d')

  if (( ${#REMOTES[@]} == 0 )); then
    echo "No configured rclone remotes found. Configure one first with: rclone config" >&2
    exit 1
  fi

  echo "Configured rclone remotes:"
  local i=1
  for remote in "${REMOTES[@]}"; do
    printf '  %2d) %s\n' "$i" "$remote"
    ((i++))
  done
  echo

  while true; do
    read -r -p "Select remote number: " selection
    [[ "$selection" =~ ^[0-9]+$ ]] || {
      echo "Please enter a numeric choice." >&2
      continue
    }
    if (( selection >= 1 && selection <= ${#REMOTES[@]} )); then
      SELECTED_REMOTE="${REMOTES[selection-1]}:"
      break
    fi
    echo "Choice out of range." >&2
  done
}

pick_ram_cache_root() {
  local candidates=("$DEFAULT_RAM_CACHE_ROOT" "/run/user/$(id -u)" "/tmp")
  local chosen=""

  for path in "${candidates[@]}"; do
    [[ -d "$path" ]] || continue
    local fstype
    fstype=$(stat -f -c %T "$path" 2>/dev/null || true)
    if [[ "$fstype" == "tmpfs" ]]; then
      chosen="$path"
      break
    fi
  done

  if [[ -z "$chosen" ]]; then
    echo "Warning: no tmpfs path detected in /dev/shm or /run/user/$(id -u); falling back to /tmp." >&2
    chosen="/tmp"
  fi

  RAM_CACHE_ROOT="$chosen"
}

mem_available_mib() {
  awk '/MemAvailable:/ {printf "%d", $2/1024}' /proc/meminfo
}

compute_cache_size() {
  local avail_mib target_mib
  avail_mib=$(mem_available_mib)

  if [[ -z "$avail_mib" || "$avail_mib" -le 0 ]]; then
    echo "Unable to determine available RAM from /proc/meminfo." >&2
    exit 1
  fi

  target_mib=$(( avail_mib * RAM_PERCENT / 100 ))
  if (( target_mib < 256 )); then
    target_mib=256
  fi

  CACHE_MAX_SIZE="${target_mib}M"
  CACHE_MAX_SIZE_MIB="$target_mib"
  AVAIL_MIB="$avail_mib"
}

rc_core_stats() {
  rclone rc --rc-addr "$DEFAULT_RC_ADDR" core/stats 2>/dev/null || true
}

rc_vfs_stats() {
  rclone rc --rc-addr "$DEFAULT_RC_ADDR" vfs/stats 2>/dev/null || true
}

request_cache_forget() {
  local response

  response=$(rclone rc --rc-addr "$DEFAULT_RC_ADDR" vfs/forget 2>&1) || {
    printf '\r\033[2KCache clear failed: %s\n' "$response" >&2
    return 1
  }

  printf '\r\033[2KDirectory cache cleared; paths reload from the remote on next access.\n'
}

request_cache_refresh() {
  local response

  response=$(rclone rc \
    --rc-addr "$DEFAULT_RC_ADDR" \
    vfs/refresh \
    recursive=true \
    _async=true \
    2>&1) || {
      printf '\r\033[2KRecursive cache refresh request failed: %s\n' "$response" >&2
      return 1
    }

  if jq -e '.jobid != null' >/dev/null 2>&1 <<<"$response"; then
    printf '\r\033[2KRecursive directory-cache refresh requested in the background.\n'
  else
    printf '\r\033[2KRecursive directory-cache refresh requested.\n'
  fi
}

get_status() {
  local core vfs active_transfers queued in_progress
  core=$(rc_core_stats)
  vfs=$(rc_vfs_stats)

  if [[ -z "$core" || -z "$vfs" ]]; then
    echo "starting starting starting"
    return 0
  fi

  active_transfers=$(jq -r '
    if has("transferring") and (.transferring | type == "array") then (.transferring | length)
    elif ((.transfers // 0) > 0) and ((.transfers // 0) < (.totalTransfers // 0)) then 1
    else 0 end
  ' <<<"$core" 2>/dev/null || echo unknown)

  queued=$(jq -r '.diskCache.uploadsQueued // 0' <<<"$vfs" 2>/dev/null || echo unknown)
  in_progress=$(jq -r '.diskCache.uploadsInProgress // 0' <<<"$vfs" 2>/dev/null || echo unknown)

  echo "$active_transfers $queued $in_progress"
}

render_status_line() {
  local status="$1"
  local message="$2"
  local a q p line
  read -r a q p <<<"$status"

  if [[ "$a" == "starting" || "$q" == "starting" || "$p" == "starting" ]]; then
    line="Status: starting VFS and RC stats..."
  else
    line="Status: active_transfers=$a uploadsQueued=$q uploadsInProgress=$p"
  fi

  if [[ -n "$message" ]]; then
    line+=" | $message"
  fi

  if [[ "$line" != "$last_render" ]]; then
    printf '\r\033[2K%s' "$line"
    last_render="$line"
  fi
}

is_idle_status() {
  local a q p
  read -r a q p <<<"$1"
  [[ "$a" == "0" && "$q" == "0" && "$p" == "0" ]]
}

stop_rclone() {
  if kill -0 "$rclone_pid" 2>/dev/null; then
    kill -TERM -- "-$rclone_pid" 2>/dev/null || kill -TERM "$rclone_pid" 2>/dev/null || true
  fi
}

force_stop_rclone() {
  if kill -0 "$rclone_pid" 2>/dev/null; then
    kill -KILL -- "-$rclone_pid" 2>/dev/null || kill -KILL "$rclone_pid" 2>/dev/null || true
  fi
}

enable_custom_keys() {
  TTY_STATE=$(stty -g)
  stty intr undef quit '^\\' min 0 time 0
}

launch_rclone() {
  RCLONE_LOG_FILE="$TMP_CACHE_DIR/rclone-serve.log"
  setsid rclone serve webdav "$REMOTE_SPEC" \
    --addr "$DEFAULT_ADDR" \
    --rc \
    --rc-addr "$DEFAULT_RC_ADDR" \
    --vfs-cache-mode "$DEFAULT_VFS_CACHE_MODE" \
    --cache-dir "$TMP_CACHE_DIR" \
    --vfs-cache-max-size "$CACHE_MAX_SIZE" \
    --links \
    --vfs-read-ahead "$DEFAULT_READ_AHEAD" \
    --dir-cache-time "$DEFAULT_DIR_CACHE_TIME" \
    >"$RCLONE_LOG_FILE" 2>&1 &
  rclone_pid=$!
}

wait_for_startup_ready() {
  local tries=0
  local status
  while kill -0 "$rclone_pid" 2>/dev/null; do
    status=$(get_status)
    render_status_line "$status" "starting"
    if [[ "$status" != "starting starting starting" ]]; then
      startup_ready=1
      printf '\r\033[2KServer ready.\n'
      return 0
    fi
    ((tries++)) || true
    if (( tries >= 30 )); then
      printf '\r\033[2KServer is still starting; continuing to wait in background.\n'
      return 0
    fi
    sleep 0.5
  done
  return 1
}

main_loop() {
  local key status message="running"

  while kill -0 "$rclone_pid" 2>/dev/null; do
    IFS= read -rsn1 -t 0.05 key || true
    case "${key:-}" in
      f)
        if (( shutdown_requested == 0 )); then
          request_cache_forget && message="directory cache cleared; reloads on next access"
        else
          printf '\r\033[2KIgnoring cache command while graceful shutdown is in progress.\n'
        fi
        ;;
      r)
        if (( shutdown_requested == 0 )); then
          request_cache_refresh && message="recursive directory-cache refresh requested"
        else
          printf '\r\033[2KIgnoring cache command while graceful shutdown is in progress.\n'
        fi
        ;;
      q)
        if (( shutdown_requested == 0 )); then
          shutdown_requested=1
          idle_polls=0
          message="graceful shutdown requested; waiting for transfers and VFS write-back to drain"
        fi
        ;;
      $'\x1c')
        force_stop_requested=1
        printf '\r\033[2KForce stop requested.\n'
        ;;
    esac

    if (( force_stop_requested == 1 )); then
      force_stop_rclone
      break
    fi

    status=$(get_status)

    if [[ "$status" == "starting starting starting" ]]; then
      render_status_line "$status" "starting"
      sleep "$POLL_INTERVAL"
      continue
    fi

    if (( shutdown_requested == 1 )); then
      if is_idle_status "$status"; then
        ((idle_polls++))
        message="idle poll ${idle_polls}/${IDLE_POLLS_REQUIRED}"
      else
        idle_polls=0
        message="graceful shutdown requested; waiting for transfers and VFS write-back to drain"
      fi

      if (( idle_polls >= IDLE_POLLS_REQUIRED )); then
        printf '\r\033[2KTransfers drained and VFS queue is empty. Stopping rclone gracefully...\n'
        stop_rclone
        break
      fi
    fi

    render_status_line "$status" "$message"
    sleep "$POLL_INTERVAL"
  done

  wait "$rclone_pid" 2>/dev/null || true
  printf '\r\033[2KDone.\n'
}

main() {
  require_cmd rclone
  require_cmd jq
  require_cmd setsid
  require_cmd sed
  require_cmd stat
  require_cmd mktemp
  require_cmd awk
  require_cmd stty

  choose_remote
  read -r -p "Path within remote (empty = root): " REMOTE_PATH

  pick_ram_cache_root
  compute_cache_size

  TMP_CACHE_DIR=$(mktemp -d "$RAM_CACHE_ROOT/rclone-webdav-cache.XXXXXX")

  REMOTE_SPEC="$SELECTED_REMOTE"
  if [[ -n "$REMOTE_PATH" ]]; then
    REMOTE_PATH="${REMOTE_PATH#/}"
    REMOTE_SPEC="${SELECTED_REMOTE}${REMOTE_PATH}"
  fi

  echo
  echo "Starting local-only rclone WebDAV server"
  echo "Remote          : $REMOTE_SPEC"
  echo "Address         : $DEFAULT_ADDR"
  echo "RC address      : $DEFAULT_RC_ADDR"
  echo "Cache root      : $RAM_CACHE_ROOT"
  echo "Cache dir       : $TMP_CACHE_DIR"
  echo "MemAvailable    : $(human_mib "$AVAIL_MIB")"
  echo "Cache max size  : $(human_mib "$CACHE_MAX_SIZE_MIB") (${RAM_PERCENT}% of available RAM)"
  echo "VFS cache mode  : $DEFAULT_VFS_CACHE_MODE"
  echo "Read-ahead      : $DEFAULT_READ_AHEAD"
  echo "Dir cache time  : $DEFAULT_DIR_CACHE_TIME"
  echo
  echo "Reachable only from this machine at: http://$DEFAULT_ADDR/"
  echo "Controls:"
  echo "  f       -> clear directory cache; reload paths on next access"
  echo "  r       -> recursively refresh directory cache now (background job)"
  echo "  q       -> graceful drain then stop"
  echo "  Ctrl+\\  -> force stop immediately"
  echo "  Ctrl+C  -> disabled while this launcher runs"
  echo "Autopolling RC status every ${POLL_INTERVAL}s."
  echo "rclone internal log: $TMP_CACHE_DIR/rclone-serve.log"
  echo

  enable_custom_keys
  launch_rclone
  wait_for_startup_ready
  main_loop
}

main "$@"
