#!/system/bin/sh
# 平滑温控闸门：在硬件 LMH / 厂商热控硬夹之前，按温度分档逐步压 CPU 上限。
# 5 秒一个 tick，升温每次最多降一档（约 15%），降温需连续 3 个 tick 才回升一档，
# 避免在阈值附近来回拉满/降频。只在真正过热时写 cpufreq，平时不碰用户频率设置。

MODDIR=$(cd "$(dirname "$0")/.." && pwd)
RUNTIME=/data/adb/nanhe_ovo
PIDFILE=$RUNTIME/thermal_guard.pid
BASEFILE=$RUNTIME/thermal_base.tsv
LOGFILE=$RUNTIME/thermal_guard.log
MODE_FILE=/sdcard/Android/yc/uperf/cur_powermode.txt

tg_log() {
    printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)" "$*" >> "$LOGFILE" 2>/dev/null || :
    if [ "$(wc -l < "$LOGFILE" 2>/dev/null | tr -d ' ')" -gt 200 ] 2>/dev/null; then
        tail -n 160 "$LOGFILE" > "$LOGFILE.tmp" 2>/dev/null && cat "$LOGFILE.tmp" > "$LOGFILE" 2>/dev/null
        rm -f "$LOGFILE.tmp"
    fi
}

read_mode() {
    M=$(cat "$MODE_FILE" 2>/dev/null)
    case "$M" in powersave|balance|performance|fast|crazy) printf '%s' "$M";; *) printf balance;; esac
}

# 温度统一成摄氏度：内核常见 45000（毫度）、4500（0.1 度）、450（0.1 度旧节点）。
norm_temp() {
    V=$1
    case "$V" in ''|*[!0-9]*) printf 0; return;; esac
    if [ "$V" -ge 10000 ] 2>/dev/null; then printf '%s' "$((V / 1000))"
    elif [ "$V" -ge 1000 ] 2>/dev/null; then printf '%s' "$((V / 100))"
    elif [ "$V" -ge 200 ] 2>/dev/null; then printf '%s' "$((V / 10))"
    else printf '%s' "$V"; fi
}

soc_temp() {
    MAX=0
    for Z in /sys/class/thermal/thermal_zone*; do
        [ -r "$Z/type" ] && [ -r "$Z/temp" ] || continue
        TY=$(cat "$Z/type" 2>/dev/null)
        case "$TY" in
            *cpu*|*CPU*|*soc*|*SOC*|*tsens*|*cluster*|*big*|*little*|*gpu*|*GPU*|*ap*) ;;
            *) continue ;;
        esac
        RAW=$(cat "$Z/temp" 2>/dev/null)
        C=$(norm_temp "$RAW")
        [ "$C" -gt "$MAX" ] 2>/dev/null && MAX=$C
    done
    printf '%s' "$MAX"
}

# 当前温度对应的目标档位。档位越高，CPU 上限越低。
target_level() { # $1=mode $2=temp
    M=$1 T=$2
    case "$M" in
        fast|performance|crazy)
            if [ "$T" -ge 88 ]; then echo 4
            elif [ "$T" -ge 84 ]; then echo 3
            elif [ "$T" -ge 79 ]; then echo 2
            elif [ "$T" -ge 74 ]; then echo 1
            else echo 0; fi ;;
        balance)
            if [ "$T" -ge 85 ]; then echo 4
            elif [ "$T" -ge 80 ]; then echo 3
            elif [ "$T" -ge 75 ]; then echo 2
            elif [ "$T" -ge 70 ]; then echo 1
            else echo 0; fi ;;
        powersave)
            if [ "$T" -ge 80 ]; then echo 4
            elif [ "$T" -ge 75 ]; then echo 3
            elif [ "$T" -ge 70 ]; then echo 2
            elif [ "$T" -ge 66 ]; then echo 1
            else echo 0; fi ;;
        *) echo 0;;
    esac
}

# 档位 1..4 的 CPU 上限百分比；档位 0 不限制。
level_pct() {
    case "$1" in 1) echo 85;; 2) echo 70;; 3) echo 55;; 4) echo 40;; *) echo 100;; esac
}

# 降档触发温度（用于 3℃ 回差）。
level_trigger() { # $1=mode $2=level
    M=$1 L=$2
    case "$M" in
        fast|performance|crazy)
            case "$L" in 1) echo 74;; 2) echo 79;; 3) echo 84;; 4) echo 88;; esac ;;
        balance)
            case "$L" in 1) echo 70;; 2) echo 75;; 3) echo 80;; 4) echo 85;; esac ;;
        powersave)
            case "$L" in 1) echo 66;; 2) echo 70;; 3) echo 75;; 4) echo 80;; esac ;;
        *) echo 999;;
    esac
}

save_base() {
    [ -f "$BASEFILE" ] && return 0
    : > "$BASEFILE.tmp"
    for P in /sys/devices/system/cpu/cpufreq/policy*; do
        [ -r "$P/scaling_max_freq" ] || continue
        MAX=$(cat "$P/scaling_max_freq" 2>/dev/null)
        MIN=$(cat "$P/scaling_min_freq" 2>/dev/null)
        case "$MAX" in ''|*[!0-9]*) continue;; esac
        case "$MIN" in ''|*[!0-9]*) MIN=0;; esac
        printf '%s\t%s\t%s\n' "$P" "$MIN" "$MAX" >> "$BASEFILE.tmp" 2>/dev/null || return 1
    done
    mv "$BASEFILE.tmp" "$BASEFILE" 2>/dev/null || return 1
}

apply_cap() { # $1=档位
    L=$1
    [ "$L" -gt 0 ] 2>/dev/null || return 0
    save_base || return 1
    PCT=$(level_pct "$L")
    while IFS='	' read -r P MIN MAX; do
        [ -n "$P" ] || continue
        [ -r "$P/scaling_max_freq" ] || continue
        HW=$(cat "$P/cpuinfo_max_freq" 2>/dev/null)
        case "$HW" in ''|*[!0-9]*) HW=$MAX;; esac
        TARGET=$((HW * PCT / 100))
        [ "$TARGET" -gt 0 ] 2>/dev/null || continue
        CMIN=$(cat "$P/scaling_min_freq" 2>/dev/null)
        case "$CMIN" in ''|*[!0-9]*) CMIN=0;; esac
        if [ "$CMIN" -gt "$TARGET" ] 2>/dev/null; then
            chmod 0666 "$P/scaling_min_freq" 2>/dev/null || :
            printf '%s\n' "$TARGET" > "$P/scaling_min_freq" 2>/dev/null || :
        fi
        chmod 0666 "$P/scaling_max_freq" 2>/dev/null || :
        printf '%s\n' "$TARGET" > "$P/scaling_max_freq" 2>/dev/null || :
    done < "$BASEFILE"
    tg_log "温控档位 $L：CPU 上限 ${PCT}%"
}

restore_base() {
    [ -f "$BASEFILE" ] || return 0
    while IFS='	' read -r P MIN MAX; do
        [ -n "$P" ] || continue
        if [ "$MIN" -gt 0 ] 2>/dev/null; then
            chmod 0666 "$P/scaling_min_freq" 2>/dev/null || :
            printf '%s\n' "$MIN" > "$P/scaling_min_freq" 2>/dev/null || :
        fi
        chmod 0666 "$P/scaling_max_freq" 2>/dev/null || :
        printf '%s\n' "$MAX" > "$P/scaling_max_freq" 2>/dev/null || :
    done < "$BASEFILE"
    rm -f "$BASEFILE"
    tg_log '温度回落：恢复 CPU 频率基线'
}

run_guard() {
    printf '%s\n' "$$" > "$PIDFILE" 2>/dev/null
    LEVEL=0 COOL=0
    trap 'restore_base; rm -f "$PIDFILE"; exit 0' TERM INT
    while :; do
        TEMP=$(soc_temp)
        MODE=$(read_mode)
        if [ "$TEMP" -gt 0 ] 2>/dev/null; then
            TARGET=$(target_level "$MODE" "$TEMP")
            if [ "$TARGET" -gt "$LEVEL" ]; then
                # 升温每次最多降一档；≥90℃ 时允许一次降两档，先压住尖峰。
                if [ "$TEMP" -ge 90 ]; then LEVEL=$((LEVEL + 2)); else LEVEL=$((LEVEL + 1)); fi
                [ "$LEVEL" -gt 4 ] && LEVEL=4
                COOL=0
                apply_cap "$LEVEL" || :
            elif [ "$TARGET" -lt "$LEVEL" ]; then
                LIMIT=$(level_trigger "$MODE" "$LEVEL")
                if [ -n "$LIMIT" ] && [ "$TEMP" -le $((LIMIT - 3)) ] 2>/dev/null; then
                    COOL=$((COOL + 1))
                    if [ "$COOL" -ge 3 ]; then
                        LEVEL=$((LEVEL - 1))
                        [ "$LEVEL" -lt 0 ] && LEVEL=0
                        COOL=0
                        if [ "$LEVEL" -eq 0 ]; then restore_base; else apply_cap "$LEVEL" || :; fi
                    fi
                else
                    COOL=0
                fi
            else
                COOL=0
            fi
        fi
        sleep 5
    done
}

case "$1" in
    start)
        mkdir -p "$RUNTIME" 2>/dev/null
        if [ -f "$PIDFILE" ]; then
            OLD=$(cat "$PIDFILE" 2>/dev/null)
            case "$OLD" in ''|*[!0-9]*) ;; *) kill -0 "$OLD" 2>/dev/null && exit 0;; esac
        fi
        # 上次异常退出留下的基线先恢复，避免带着旧上限重启。
        restore_base
        ( cd "$RUNTIME" 2>/dev/null || cd /; nohup sh "$0" run >/dev/null 2>&1 & )
        ;;
    stop)
        if [ -f "$PIDFILE" ]; then
            OLD=$(cat "$PIDFILE" 2>/dev/null)
            case "$OLD" in ''|*[!0-9]*) ;; *) kill "$OLD" 2>/dev/null;; esac
            rm -f "$PIDFILE"
        fi
        restore_base
        ;;
    run) run_guard;;
    *) printf 'usage: %s start|stop|run\n' "$0" >&2; exit 1;;
esac
