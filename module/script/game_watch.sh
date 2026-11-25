#!/system/bin/sh
# 前台感知的动态调度：游戏进前台拉 fast，退出游戏回 balance，灭屏切 powersave。
# 只在前台包名/亮灭屏变化时写一次，避免每 2 秒重复抖动 Uperf 与 AppOptR。
# 手动模式仍可在下一次前台变化前保持，不会被立即覆盖。

MODDIR=$(cd "$(dirname "$0")/.." && pwd)
RUNTIME=/data/adb/nanhe_ovo
UPERF=/sdcard/Android/yc/uperf
RULES=$UPERF/perapp_powermode.txt
GAME_LIST=$MODDIR/game.list
PIDFILE=$RUNTIME/game_watch.pid
LOGFILE=$RUNTIME/game_watch.log
MODE_FILE=$UPERF/cur_powermode.txt

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

# 取前台包名。优先 mResumedActivity / topResumedActivity，失败再看 mCurrentFocus。
foreground_pkg() {
    PKG=$(dumpsys activity activities 2>/dev/null | awk '
        /mResumedActivity|topResumedActivity|ResumedActivity:/ {
            for (i = 1; i <= NF; i++) {
                if ($i ~ /^[A-Za-z0-9_.]+\/[A-Za-z0-9_.$]+$/) {
                    split($i, a, "/"); print a[1]; exit
                }
            }
        }')
    if [ -z "$PKG" ]; then
        PKG=$(dumpsys window windows 2>/dev/null | awk '
            /mCurrentFocus|mFocusedApp/ {
                for (i = 1; i <= NF; i++) {
                    if ($i ~ /^[A-Za-z0-9_.]+\/[A-Za-z0-9_.$]+$/) {
                        split($i, a, "/"); print a[1]; exit
                    }
                }
            }')
    fi
    printf '%s' "$PKG"
}

screen_awake() {
    ST=$(dumpsys power 2>/dev/null | awk -F= '/mWakefulness=/{gsub(/[ \t]/,"",$2); print $2; exit}')
    case "$ST" in Dozing|Asleep) printf asleep;; *) printf awake;; esac
}

is_game() {
    [ -f "$GAME_LIST" ] || return 1
    awk -F'\t' -v p="$1" '!/^#/ && $1 == p { found = 1; exit } END { exit(found ? 0 : 1) }' "$GAME_LIST" 2>/dev/null
}

# per-app 规则优先；没有显式规则的游戏回退 fast，非游戏回退 balance。
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
    [ -d "$UPERF" ] || return 1
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
    # GPU / DDR 各自按模式限幅；脚本不存在或节点不存在时静默跳过。
    [ -x "$MODDIR/script/gpu_profile.sh" ] && sh "$MODDIR/script/gpu_profile.sh" "$MODE" >/dev/null 2>&1
    [ -f "$MODDIR/script/ddr_profile.sh" ] && sh "$MODDIR/script/ddr_profile.sh" "$MODE" >/dev/null 2>&1
    if [ ! -f "$THREAD_DISABLED" ]; then
        thread_gen_conf "$MODE" >/dev/null 2>&1 || gw_log "线程规则生成失败：$MODE"
        thread_start >/dev/null 2>&1 || :
    fi
    [ -f "$MODDIR/script/thermal_guard.sh" ] && sh "$MODDIR/script/thermal_guard.sh" start >/dev/null 2>&1
    gw_log "模式 $OLD -> $MODE（前台 ${PKG:-未知}，屏幕 ${SCREEN:-未知}）"
}

choose_mode() {
    if [ "$SCREEN" = asleep ]; then
        printf powersave
        return
    fi
    if is_game "$PKG"; then
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
    LAST_PKG=__init__ LAST_SCREEN=__init__
    while :; do
        PKG=$(foreground_pkg)
        SCREEN=$(screen_awake)
        if [ "$PKG" != "$LAST_PKG" ] || [ "$SCREEN" != "$LAST_SCREEN" ]; then
            MODE=$(choose_mode)
            apply_mode "$MODE" || :
            LAST_PKG=$PKG LAST_SCREEN=$SCREEN
        fi
        sleep 2
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
