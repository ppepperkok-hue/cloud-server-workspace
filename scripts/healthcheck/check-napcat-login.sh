#!/usr/bin/env bash
# check-napcat-login.sh — alert when a NapCat QQ account falls offline.
#
# WHY THIS EXISTS
#   napcat2 (QQ <QQ_ACCOUNT_B>) gets kicked offline by Tencent's server side
#   (see state/KNOWN-ISSUES.md #20). Its message flow then dies silently: the
#   user only finds out because "nobody replies to me". There was no monitoring
#   at all. This script closes that gap.
#
# DESIGN: report a flaky channel over a stable one
#   - Detector: napcat2's OWN WebUI status API. That HTTP server keeps answering
#     while the QQ account is logged out, so it reports *login state* rather than
#     process liveness. Chosen over grepping docker logs because logs rotate, are
#     prose, and cannot tell "reconnecting" from "kicked".
#   - Sender: napcat1 (the account that never drops), via its WebUI Debug API
#     (OneBot action passthrough). No config change, no container restart and no
#     new listening port — it only uses an HTTP server that is already running.
#   - If the sender is unavailable the alert is NOT recorded as delivered: the
#     next run retries and the failure is logged loudly. Never silent.
#
# Prerequisites: bash, curl, python3, flock. Read-only w.r.t. containers.
#
# Exit codes:
#   0 = target online, or the alert/recovery was handled
#   1 = misconfiguration (missing ADMIN_QQ)
#   2 = usage error
#   3 = target down AND the alert could not be delivered
#
# Usage:
#   check-napcat-login.sh                 # normal cron run
#   check-napcat-login.sh --status        # print current state, send nothing
#   check-napcat-login.sh --simulate up|down|unreachable
#                                         # inject a fake probe result (testing)
#   check-napcat-login.sh --dry-run       # never send, print what would be sent
#   check-napcat-login.sh --reset         # forget state (sends nothing)
#
# Config comes from the environment file (default /etc/napcat-alert.env), never
# from this script: ADMIN_QQ is personal data and must not live in the repo.

set -uo pipefail

# ------------------------------------------------------------------ lock ----
# Serialise runs: a slow probe must not overlap the next cron tick.
# This MUST happen before the argument parser consumes $@ — re-execing with an
# already-shifted "$@" silently dropped every flag (caught by the test suite,
# where --simulate fell back to probing production state).
LOCK_FILE="${NAPCAT_ALERT_LOCK_FILE:-/var/lock/napcat-alert.lock}"
# Hard ceiling on one run. `timeout` MUST wrap the *body* (i.e. sit between flock
# and bash): on expiry timeout kills the body, flock notices and exits, and the
# lock is released. Without it a single wedged run holds the exclusive lock
# forever while every later tick dies instantly and silently on `flock -n` —
# that is exactly how alerting stayed dead for 10 days (2026-09-29 15:20:46 →
# 2026-10-09 19:31) without a single log line. See state/KNOWN-ISSUES.md #22.
RUN_TIMEOUT="${NAPCAT_ALERT_RUN_TIMEOUT:-180}"
if [ -z "${NAPCAT_ALERT_LOCKED:-}" ] && command -v flock >/dev/null 2>&1; then
    export NAPCAT_ALERT_LOCKED=1
    if command -v timeout >/dev/null 2>&1; then
        exec flock -n "$LOCK_FILE" timeout --kill-after=10 "$RUN_TIMEOUT" bash "$0" "$@"
    fi
    exec flock -n "$LOCK_FILE" bash "$0" "$@"
fi

# ---------------------------------------------------------------- config ----
# Precedence: explicitly exported variables BEAT the config file. Without this
# the file silently swallowed the caller's overrides (e.g. CONFIRM_FAILURES=1
# during a drill), because sourcing it after inheritance overwrote them.
ENV_FILE="${NAPCAT_ALERT_ENV:-/etc/napcat-alert.env}"
ENV_KEYS=(ADMIN_QQ SENDER_CONF SENDER_PORT TARGET_CONF TARGET_PORT TARGET_LABEL
          STATE_DIR SILENCE_MINUTES CONFIRM_FAILURES WEBUI_HELP HEARTBEAT_HOUR)

declare -A _PRESET=()
for _k in "${ENV_KEYS[@]}"; do
    if [[ -v $_k ]]; then _PRESET[$_k]="${!_k}"; fi
done
if [ -r "$ENV_FILE" ]; then
    # shellcheck disable=SC1090
    . "$ENV_FILE"
fi
for _k in "${!_PRESET[@]}"; do printf -v "$_k" '%s' "${_PRESET[$_k]}"; done
unset _k _PRESET

ADMIN_QQ="${ADMIN_QQ:-}"
SENDER_CONF="${SENDER_CONF:-/opt/astrbot/napcat1/config/webui.json}"
SENDER_PORT="${SENDER_PORT:-6099}"
TARGET_CONF="${TARGET_CONF:-/opt/astrbot/napcat2/config/webui.json}"
TARGET_PORT="${TARGET_PORT:-6100}"
TARGET_LABEL="${TARGET_LABEL:-<QQ_ACCOUNT_B>}"
STATE_DIR="${STATE_DIR:-/var/lib/napcat-alert}"
STATE_FILE="$STATE_DIR/state.json"
SILENCE_MINUTES="${SILENCE_MINUTES:-30}"
CONFIRM_FAILURES="${CONFIRM_FAILURES:-2}"
WEBUI_HELP="${WEBUI_HELP:-http://127.0.0.1:6100/webui/}"
# Dead-man's switch (docs/operations/05-monitoring.md §5: the monitor must itself
# be monitored). Empty = off. Set to an hour 0-23 to get one "still alive"
# message per day at/after that hour — proving BOTH the monitor and the sender
# still work. Off by default because a daily message is noise unless you want it.
HEARTBEAT_HOUR="${HEARTBEAT_HOUR:-}"

SIMULATE=""
DRY_RUN=0
MODE="run"

# ------------------------------------------------------------------ args ----
while [ $# -gt 0 ]; do
    case "$1" in
        --simulate) SIMULATE="${2:-}"; shift 2 ;;
        --dry-run)  DRY_RUN=1; shift ;;
        --status)   MODE=status; shift ;;
        --reset)    MODE=reset; shift ;;
        -h|--help)  sed -n '2,40p' "$0"; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

log() {
    printf '%s %s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" "$2"
}

# ------------------------------------------------------------ state file ----
# The credential cache lives here so we do not log in on every run (NapCat's
# WebUI enforces loginRate). The state file is mode 600.
state_get() {
    python3 -c '
import json, sys, pathlib
p = pathlib.Path(sys.argv[1]); key = sys.argv[2]
try:
    d = json.loads(p.read_text(encoding="utf-8"))
except Exception:
    d = {}
v = d.get(key, "")
print("" if v is None else v)
' "$STATE_FILE" "$1" 2>/dev/null || true
}

state_set() {
    python3 -c '
import json, os, pathlib, sys, tempfile
p = pathlib.Path(sys.argv[1]); pairs = sys.argv[2:]
try:
    d = json.loads(p.read_text(encoding="utf-8"))
except Exception:
    d = {}
for i in range(0, len(pairs) - 1, 2):
    d[pairs[i]] = pairs[i + 1]
p.parent.mkdir(parents=True, exist_ok=True)
fd, tmp = tempfile.mkstemp(dir=str(p.parent))
with os.fdopen(fd, "w", encoding="utf-8") as fh:
    json.dump(d, fh, ensure_ascii=False, indent=2)
os.chmod(tmp, 0o600)
os.replace(tmp, p)
' "$STATE_FILE" "$@"
}

state_wipe() {
    python3 -c '
import json, pathlib, sys
p = pathlib.Path(sys.argv[1])
p.parent.mkdir(parents=True, exist_ok=True)
p.write_text(json.dumps({"state": "unknown"}, indent=2), encoding="utf-8")
p.chmod(0o600)
' "$STATE_FILE"
}

if [ "$MODE" = "reset" ]; then
    state_wipe
    log INFO "state reset (no message sent)"
    exit 0
fi

if [ "$MODE" = "status" ]; then
    echo "state file: $STATE_FILE"
    if [ -f "$STATE_FILE" ]; then cat "$STATE_FILE"; else echo "(none)"; fi
    exit 0
fi

# ------------------------------------------------------------- webui auth ----
# NapCat WebUI login: POST /api/auth/login with {"hash": sha256(token + ".napcat")}
webui_login() {
    local conf="$1" port="$2" token hash
    token=$(python3 -c '
import json, sys
print(json.load(open(sys.argv[1], encoding="utf-8-sig")).get("token", ""))
' "$conf" 2>/dev/null)
    [ -n "$token" ] || return 1
    hash=$(python3 -c '
import hashlib, sys
print(hashlib.sha256((sys.argv[1] + ".napcat").encode()).hexdigest())
' "$token")
    curl -s --max-time 8 -X POST -H 'Content-Type: application/json' \
        -d "{\"hash\":\"$hash\"}" "http://127.0.0.1:$port/api/auth/login" \
        | python3 -c '
import json, sys
try:
    print((json.load(sys.stdin).get("data") or {}).get("Credential", ""))
except Exception:
    print("")
' 2>/dev/null
}

# Reuse a cached credential while it still authenticates; log in only when it
# stops working. Keeps login attempts rare against the WebUI's login rate limit.
cred_for() {
    local port="$1" conf="$2" cache_key="$3" cred
    cred=$(state_get "$cache_key")
    if [ -n "$cred" ]; then
        if curl -s --max-time 8 -X POST -H "Authorization: Bearer $cred" \
                "http://127.0.0.1:$port/api/QQLogin/CheckLoginStatus" | grep -q '"code":0'; then
            printf '%s' "$cred"
            return 0
        fi
    fi
    cred=$(webui_login "$conf" "$port")
    [ -n "$cred" ] || return 1
    state_set "$cache_key" "$cred"
    printf '%s' "$cred"
}

# --------------------------------------------------------------- probing ----
# Prints "<up|down> <reason>". "up" means the QQ account is logged in and ready.
probe_target() {
    local cred status

    case "$SIMULATE" in
        unreachable) printf 'down webui-unreachable'; return ;;
        down)        printf 'down simulated-down';   return ;;
        up)          printf 'up simulated-up';       return ;;
    esac

    cred=$(cred_for "$TARGET_PORT" "$TARGET_CONF" cred_target) || {
        printf 'down webui-auth-failed'
        return
    }

    status=$(curl -s --max-time 8 -X POST -H "Authorization: Bearer $cred" \
        "http://127.0.0.1:$TARGET_PORT/api/QQLogin/CheckLoginStatus")
    printf '%s' "$status" | python3 -c '
import json, sys
try:
    d = json.loads(sys.stdin.read())
except Exception:
    print("down webui-bad-response"); raise SystemExit
if d.get("code") != 0:
    print("down webui-unauthorized"); raise SystemExit
data = d.get("data") or {}
if not data:
    print("down webui-no-data"); raise SystemExit
# Conservative on purpose: isOffline is part of the decision, not just the
# explanation. A payload that says "offline" while the other flags look ready is
# contradictory, and reporting it as healthy is exactly the silent miss this
# monitor exists to prevent. If this ever misfires, the log line will say so.
ok = (bool(data.get("isLogin")) and bool(data.get("coreReady"))
      and data.get("loginPhase") == "ready" and not data.get("isOffline"))
if ok:
    print("up ok"); raise SystemExit
bits = []
if not data.get("isLogin"):   bits.append("isLogin=false")
if not data.get("coreReady"): bits.append("coreReady=false")
phase = data.get("loginPhase")
if phase and phase != "ready": bits.append("loginPhase=%s" % phase)
if data.get("isOffline"):     bits.append("isOffline=true")
print("down " + (", ".join(bits) or "unknown"))
' 2>/dev/null || printf 'down webui-parse-failed'
}

# ---------------------------------------------------------------- sending ----
# Sends via napcat1's WebUI Debug API (OneBot action passthrough).
# Returns 0 only when the OneBot layer reports retcode 0.
send_qq() {
    local text="$1" cred body resp retcode
    if [ "$DRY_RUN" = "1" ]; then
        log INFO "DRY-RUN would send: $text"
        return 0
    fi
    cred=$(cred_for "$SENDER_PORT" "$SENDER_CONF" cred_sender) || {
        log ERROR "sender login failed (napcat1 WebUI :$SENDER_PORT) - alert NOT delivered"
        return 1
    }
    curl -s --max-time 8 -X POST -H "Authorization: Bearer $cred" \
        -H 'Content-Type: application/json' -d '{}' \
        "http://127.0.0.1:$SENDER_PORT/api/Debug/create" >/dev/null

    body=$(python3 -c '
import json, sys
uid, text = int(sys.argv[1]), sys.argv[2]
print(json.dumps({"action": "send_private_msg",
                  "params": {"user_id": uid,
                             "message": [{"type": "text", "data": {"text": text}}]}},
                 ensure_ascii=False))
' "$ADMIN_QQ" "$text")

    resp=$(curl -s --max-time 15 -X POST -H "Authorization: Bearer $cred" \
        -H 'Content-Type: application/json' -d "$body" \
        "http://127.0.0.1:$SENDER_PORT/api/Debug/call")
    retcode=$(printf '%s' "$resp" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print("parse-failed"); raise SystemExit
print((d.get("data") or {}).get("retcode", "no-retcode"))
' 2>/dev/null)

    if [ "$retcode" = "0" ]; then
        log INFO "message delivered via napcat1 (retcode=0)"
        return 0
    fi
    log ERROR "send failed: retcode=$retcode resp=$(printf '%s' "$resp" | head -c 200)"
    return 1
}

# ------------------------------------------------------------------ main ----
[ -n "$ADMIN_QQ" ] || { log ERROR "ADMIN_QQ is not set (see $ENV_FILE)"; exit 1; }

mkdir -p "$STATE_DIR" 2>/dev/null
[ -f "$STATE_FILE" ] || state_wipe

NOW=$(date +%s)
PROBE=$(probe_target)
VERDICT="${PROBE%% *}"
REASON="${PROBE#* }"

PREV_STATE=$(state_get state);        [ -n "$PREV_STATE" ] || PREV_STATE="unknown"
FAILS=$(state_get failures);          case "$FAILS" in ''|*[!0-9]*) FAILS=0 ;; esac
LAST_ALERT=$(state_get last_alert_epoch); case "$LAST_ALERT" in ''|*[!0-9]*) LAST_ALERT=0 ;; esac
FIRST_FAIL=$(state_get first_failure_epoch); case "$FIRST_FAIL" in ''|*[!0-9]*) FIRST_FAIL=0 ;; esac
ALERTED=$(state_get alerted);         case "$ALERTED" in ''|*[!0-9]*) ALERTED=0 ;; esac

# ---- up path ---------------------------------------------------------------
if [ "$VERDICT" = "up" ]; then
    if [ "$PREV_STATE" = "down" ] && [ "$ALERTED" = "1" ]; then
        down_mins=$(( (NOW - FIRST_FAIL) / 60 ))
        MSG="【已恢复】$TARGET_LABEL 的 QQ 重新登录成功
掉线持续：约 ${down_mins} 分钟
影响解除：该号的收发消息与「换班提醒」推送已恢复正常。"
        if send_qq "$MSG"; then
            log INFO "recovery reported (downtime ~${down_mins}min)"
            state_set state up failures 0 first_failure_epoch 0 alerted 0 \
                last_recovery_epoch "$NOW" last_reason ""
        else
            log ERROR "recovery detected but the notification failed - will retry next run"
        fi
    else
        if [ "$PREV_STATE" = "down" ]; then
            log INFO "back online before any alert was sent (flap) - staying silent"
        else
            log INFO "ok: $TARGET_LABEL online ($REASON)"
        fi
        state_set state up failures 0 first_failure_epoch 0 alerted 0 last_reason ""
    fi

    # ---- optional daily heartbeat (dead-man's switch) ----------------------
    if [ -n "$HEARTBEAT_HOUR" ]; then
        hh=$(date +%H); hh=$((10#$hh))
        today=$(date +%F)
        if [ "$hh" -ge "$HEARTBEAT_HOUR" ] && [ "$(state_get last_heartbeat_day)" != "$today" ]; then
            HB="【监控心跳】napcat 掉线监控运行正常（$today）。
$TARGET_LABEL 在线；告警通道（napcat1）可用。
没有消息就是好消息——这条只是证明监控还活着。"
            if send_qq "$HB"; then
                log INFO "daily heartbeat sent"
                state_set last_heartbeat_day "$today"
            else
                log ERROR "heartbeat could not be delivered - the monitor itself may be broken"
            fi
        fi
    fi
    exit 0
fi

# ---- down path -------------------------------------------------------------
FAILS=$(( FAILS + 1 ))
[ "$FIRST_FAIL" -eq 0 ] && FIRST_FAIL=$NOW
state_set state down failures "$FAILS" first_failure_epoch "$FIRST_FAIL" last_reason "$REASON"

if [ "$FAILS" -lt "$CONFIRM_FAILURES" ]; then
    log INFO "down but not confirmed yet ($FAILS/$CONFIRM_FAILURES): $REASON"
    exit 0
fi

if [ "$LAST_ALERT" -gt 0 ] && [ $(( NOW - LAST_ALERT )) -lt $(( SILENCE_MINUTES * 60 )) ]; then
    log INFO "down, already alerted $(( (NOW - LAST_ALERT) / 60 )) min ago, staying silent: $REASON"
    exit 0
fi

FIRST_TS=$(date -d "@$FIRST_FAIL" '+%Y-%m-%d %H:%M' 2>/dev/null || date '+%Y-%m-%d %H:%M')
RETRY_NOTE=""
if [ "$LAST_ALERT" -gt 0 ]; then
    RETRY_NOTE='
（仍未恢复：这是同一故障的再次提醒）'
fi

MSG="【掉线告警】$TARGET_LABEL 的 QQ 掉线了
首次发现：$FIRST_TS
现象：$REASON

影响：该号的收发消息与「换班提醒」的推送会失败。
不影响：换班时刻判断与发送记录、公招计算、已加载的数据——它们不依赖这个号。

要做的：
1) 先确认手机上没有再登录这个号（同号互踢会被反复踢下线，这是最常见的成因）
2) 恢复：用 NapCat WebUI 扫一次码 —— $WEBUI_HELP（需经 SSH 隧道访问，见 scripts/utils/napcat-webui-tunnel.ps1）
3) 不要反复重启容器：每次重启都是一次新的登录尝试，可能加重风控
${RETRY_NOTE}
（同一故障 $SILENCE_MINUTES 分钟内不会重复提醒；恢复后会再报一次）"

if send_qq "$MSG"; then
    state_set last_alert_epoch "$NOW" alerted 1
    exit 0
fi

log ERROR "TARGET IS DOWN AND THE ALERT COULD NOT BE DELIVERED - sender (napcat1) may also be down"
exit 3
