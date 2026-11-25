#!/system/bin/sh
# 前台感知的动态调度：游戏进前台拉 fast，退出游戏回 balance，灭屏切 powersave。
#
# v1.11.0 起不再每 2 秒执行两次 dumpsys。前台识别走 top-app cpuset 的
# /proc/<pid>/cmdline，只在包名/亮灭屏变化时写一次模式并调用自研 cpu_policy.sh。
# 只有 top-app 节点不可读时，才降级为低频 dumpsys（最多 20 秒一次）。
# 手动模式仍可在下一次前台变化前保持，不会被立即覆盖。

MODDIR=$(cd "$(dirname "$0")/.." && pwd)
RUNTIME=/data/adb/nanhe_ovo
USER_PATH=/sdcard/Android/yc/uperf
RULES=$USER_PATH/perapp_powermode.txt
GAME_LIST=$MODDIR/game.list
PIDFILE=$RUNTIME/game_watch.pid
LOGFILE=$RUNTIME/game_watch.log
MODE_FILE=$USER_PATH/cur_powermode.txt
CPU_POLICY=$MODDIR/script/cpu_policy.sh

. "$MODDIR/script/libthread.sh"

gw_log() {
    [ -d "$RUNTIME" ] || return 0
    printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)" "$*" >> "$LOGFILE" 2>/dev/null || :
    if [ "$(wc -l < "$LOGFILE" 2>/dev/null | tr -d ' ')" -gt 240 ] 2>/dev/null; then
        tail -n 200 "$LOGFILE" > "$LOGFILE.tmp" 2>/dev/null && cat "$LOGFILE.tmp" > "$LOGFILE" 2>/dev/null
        rm -f "$LOGFILE.tmp"
    fi
}

read_mode() {
    MODE=$(cat "$MODE_FILE" 2>/dev/null)
    case "$MODE" in powersave|balance|performance|fast|crazy) ;; *) MODE=balance;; esac
    printf '%s' "$MODE"
}

is_game() {
    [ -f "$GAME_LIST" ] || return 1
    awk -F'\t' -v p="$1" '!/^#/ && $1 == p { found = 1; exit } END { exit(found ? 0 : 1) }' "$GAME_LIST" 2>/dev/null
}

# top-app 的线程列表：cgroup v1 / cgroup v2 两种路径，取到一个就返回。
top_app_pids() {
    for F in /dev/cpuset/top-app/tasks /dev/cpuset/top-app/cgroup.procs \
             /sys/fs/cgroup/top-app/cgroup.procs /sys/fs/cgroup/top-app/tasks; do
        [ -r "$F" ] || continue
        awk '$1 ~ /^[0-9]+$/ { print $1 }' "$F" 2>/dev/null | sort -u
        return 0
    done
    return 1
}

# 进程名 → 包名：Android 的子进程通常写成 pkg:remote，只取冒号前部分。
proc_pkg() {
    [ -r "/proc/$1/cmdline" ] || return 1
    CMD=$(tr '\0' '\n' < "/proc/$1/cmdline" 2>/dev/null | sed -n '1p')
    [ -n "$CMD" ] || return 1
    printf '%s' "${CMD%%:*}"
}

# 返回当前 top-app 中的游戏包名；没有游戏返回空。
# 这样非游戏前台会主动回 balance，而不是把 launcher / 设置页当成后台。
foreground_game() {
    PIDS=$(top_app_pids) || return 1
    for PID in $PIDS; do
        [ "$PID" = "$$" ] && continue
        PKG=$(proc_pkg "$PID") || continue
        if is_game "$PKG"; then
            printf '%s' "$PKG"
            return 0
        fi
    done
    printf '%s' ''
    return 0
}

# 只在 top-app 不可读时使用的低频兜底。调用频率由主循环限制。
foreground_pkg_fallback() {
    dumpsys activity activities 2>/dev/null | awk '
        /mResumedActivity|topResumedActivity|ResumedActivity:/ {
            for (i = 1; i <= NF; i++) {
                if ($i ~ /^[A-Za-z0-9_.]+\/[A-Za-z0-9_.$]+$/) {
                    split($i, a, "/"); print a[1]; exit
                }
            }
        }'
}

screen_awake() {
    for F in /sys/class/backlight/*/brightness /sys/class/leds/lcd-backlight/brightness; do
        [ -r "$F" ] || continue
        V=$(cat "$F" 2>/dev/null)
        case "$V" in ''|*[!0-9]*) continue;; 0) printf asleep; return 0;; *) printf awake; return 0;; esac
    done
    # 少数机型没有 backlight 节点；保留低频 dumpsys power 作为兜底。
    ST=$(dumpsys power 2>/dev/null | awk -F= '/mWakefulness=/{gsub(/[ \t]/,"",$2); print $2; exit}')
    case "$ST" in Dozing|Asleep) printf asleep;; *) printf awake;; esac
}

# 取“前台游戏”和屏幕状态，每 4 秒一次；只有变化才应用。
sample_state() {
    PKG=$(foreground_game) || PKG=
    if [ -z "$PKG" ] && [ "${TOP_APP_OK:-1}" = 0 ]; then
        NOW=$(date +%s 2>/dev/null)
        case "$NOW" in ''|*[!0-9]*) NOW=0;; esac
        if [ $((NOW - LAST_DUMP)) -ge 20 ] 2>/dev/null; then
            PKG=$(foreground_pkg_fallback)
            LAST_DUMP=$NOW
        fi
    fi
    SCREEN=$(screen_awake)
    case "$SCREEN" in asleep|awake) ;; *) SCREEN=awake;; esac
}

# per-app 规则优先；没有显式规则的游戏回退 fast。
rule_mode() {
    [ -f "$RULES" ] || { printf '%s' ''; return; }
    awk -v p="$1" '
        /^[ \t]*#/ || NF == 0 { next }
        $1 == p { print $2; exit }
    ' "$RULES" 2>/dev/null
}

write_mode() {
    MODE=$1
    case "$MODE" in powersave|balance|performance|fast|crazy) ;; *) return 1;; esac
    [ -d "$USER_PATH" ] || return 1
    [ ! -L "$MODE_FILE" ] || return 1
    printf '%s\n' "$MODE" > "$RUNTIME/.mode.tmp" 2>/dev/null || return 1
    cat "$RUNTIME/.mode.tmp" > "$MODE_FILE" 2>/dev/null || { rm -f "$RUNTIME/.mode.tmp"; return 1; }
    rm -f "$RUNTIME/.mode.tmp"
}

apply_mode() {
    MODE=$1
    OLD=$(read_mode)
    [ "$OLD" = "$MODE" ] && return 0
    write_mode "$MODE" || { gw_log "写入模式失败：$MODE"; return 1; }
    # 自研策略优先：先限制每簇上限，再处理 GPU / DDR / 线程。
    if [ -f "$CPU_POLICY" ]; then
        sh "$CPU_POLICY" apply "$MODE" >/dev/null 2>&1 ||
            gw_log "CPU 策略应用失败：$MODE"
    else
        gw_log "缺少 cpu_policy.sh，CPU 上限未应用：$MODE"
    fi
    [ -x "$MODDIR/script/gpu_profile.sh" ] && sh "$MODDIR/script/gpu_profile.sh" "$MODE" >/dev/null 2>&1
    [ -f "$MODDIR/script/ddr_profile.sh" ] && sh "$MODDIR/script/ddr_profile.sh" "$MODE" >/dev/null 2>&1
    if [ ! -f "$THREAD_DISABLED" ]; then
        thread_gen_conf "$MODE" >/dev/null 2>&1 || gw_log "线程规则生成失败：$MODE"
        thread_start >/dev/null 2>&1 || :
    fi
    [ -f "$MODDIR/script/thermal_guard.sh" ] && sh "$MODDIR/script/thermal_guard.sh" start >/dev/null 2>&1
    gw_log "模式 $OLD -> $MODE（前台 ${PKG:-none}，屏幕 ${SCREEN:-未知}）"
}

choose_mode() {
    if [ "$SCREEN" = asleep ]; then
        printf powersave
        return
    fi
    if [ -n "$PKG" ] && is_game "$PKG"; then
        RM=$(rule_mode "$PKG")
        case "$RM" in powersave|balance|performance|fast|crazy) printf '%s' "$RM"; return;; esac
        printf fast
        return
    fi
    # 非游戏回到均衡；如果用户手动锁了省电，保持省电。
    [ "$(read_mode)" = powersave ] && printf powersave || printf balance
}

run_loop() {
    mkdir -p "$RUNTIME" 2>/dev/null
    printf '%s\n' "$$" > "$PIDFILE" 2>/dev/null
    LAST_PKG=__init__ LAST_SCREEN=__init__ LAST_DUMP=0 TOP_APP_OK=1
    top_app_pids >/dev/null 2>&1 || TOP_APP_OK=0
    while :; do
        sample_state
        if [ "$PKG" != "$LAST_PKG" ] || [ "$SCREEN" != "$LAST_SCREEN" ]; then
            MODE=$(choose_mode)
            apply_mode "$MODE" || :
            LAST_PKG=$PKG LAST_SCREEN=$SCREEN
        fi
        sleep 4
    done
}

case "$1" in
    start)
        if [ -f "$PIDFILE" ]; then
            OLD=$(cat "$PIDFILE" 2>/dev/null)
            case "$OLD" in ''|*[!0-9]*) ;; *) kill -0 "$OLD" 2>/dev/null && exit 0;; esac
        fi
        mkdir -p "$RUNTIME" 2>/dev/null
        ( cd "$RUNTIME" 2>/dev/null || cd /; nohup sh "$0" run >/dev/null 2>&1 & )
        ;;
    stop)
        if [ -f "$PIDFILE" ]; then
            OLD=$(cat "$PIDFILE" 2>/dev/null)
            case "$OLD" in ''|*[!0-9]*) ;; *) kill "$OLD" 2>/dev/null;; esac
            rm -f "$PIDFILE"
        fi
        ;;
    run) run_loop;;
    *) printf 'usage: %s start|stop|run\n' "$0" >&2; exit 1;;
esac
