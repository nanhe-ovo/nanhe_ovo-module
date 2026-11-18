#!/system/bin/sh
# 南何ovo · MTK Mali GPU 分模式频率窗口（v1.6.0）
# 只使用设备真实 OPP 表与已有 devfreq 节点；不写死频点、不升压、不关闭温控。

RROOT=/data/adb/nanhe_ovo
MODE=${1:-balance}

log() {
    [ -d "$RROOT" ] && [ ! -L "$RROOT/log.txt" ] || return 0
    GP_MSG=$(printf '%s' "$*" | tr '\n\r\t' '   ')
    printf '%s\tinfo\tgpu\t%s\n' "$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)" "$GP_MSG" >> "$RROOT/log.txt" 2>/dev/null || :
}

is_mtk_platform() {
    GP_PLATFORM=$(getprop ro.board.platform 2>/dev/null)
    GP_HARDWARE=$(getprop ro.hardware 2>/dev/null)
    case "$GP_PLATFORM $GP_HARDWARE" in *mt[0-9]*|*MT[0-9]*) return 0;; esac
    getprop 2>/dev/null | grep -q 'ro.mtk' && return 0
    return 1
}

write_node() {
    [ -f "$2" ] && [ ! -L "$2" ] || return 1
    printf '%s\n' "$1" > "$2" 2>/dev/null || return 1
    return 0
}

# 从 OPP 表中选不超过比例目标的最高档；绝不凭空构造表外频点。
pick_opp() {
    awk -v pct="$1" -v ceiling="$2" '
        BEGIN { target = ceiling * pct / 100; low = 0; pick = 0 }
        {
            for (i = 1; i <= NF; i++) {
                f = $i + 0
                if (f <= 0 || f > ceiling) continue
                if (low == 0 || f < low) low = f
                if (f <= target && f > pick) pick = f
            }
        }
        END { if (pick > 0) printf "%d", pick; else if (low > 0) printf "%d", low }
    ' "$3"
}

save_original() {
    GP_STATE=$1 GP_NODE=$2 GP_DEV=$3
    [ -e "$GP_STATE/$GP_NODE" ] && return 0
    if [ -f "$GP_DEV/$GP_NODE" ]; then
        cat "$GP_DEV/$GP_NODE" > "$GP_STATE/$GP_NODE" 2>/dev/null || :
    else
        printf '__missing__\n' > "$GP_STATE/$GP_NODE" 2>/dev/null || :
    fi
}

restore_node() {
    GP_STATE=$1 GP_NODE=$2 GP_DEV=$3
    [ -f "$GP_STATE/$GP_NODE" ] || return 0
    GP_SAVED=$(cat "$GP_STATE/$GP_NODE" 2>/dev/null)
    case "$GP_SAVED" in ''|'__missing__') return 0;; esac
    write_node "$GP_SAVED" "$GP_DEV/$GP_NODE" || :
}

apply_device() {
    GP_DEV=$1 GP_INDEX=$2 GP_MODE=$3
    [ -f "$GP_DEV/available_frequencies" ] || return 0
    GP_MAX=$(cat "$GP_DEV/max_freq" 2>/dev/null)
    case "$GP_MAX" in ''|*[!0-9]*) return 0;; esac

    BOOT_ID=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null | tr -d '-')
    case "$BOOT_ID" in ''|*[!0-9A-Fa-f]*) BOOT_ID=current;; esac
    GP_STATE="$RROOT/gpu_profile/$BOOT_ID/gpu$GP_INDEX"
    [ ! -L "$RROOT/gpu_profile" ] || return 0
    mkdir -p "$GP_STATE" 2>/dev/null || return 0
    for GP_NODE in min_freq max_freq upthreshold downdifferential polling_interval; do
        save_original "$GP_STATE" "$GP_NODE" "$GP_DEV"
    done

    case "$GP_MODE" in
        powersave|balance)
            # 先恢复下限再恢复上限；开机快照之外的值一律不猜。
            restore_node "$GP_STATE" min_freq "$GP_DEV"
            restore_node "$GP_STATE" max_freq "$GP_DEV"
            for GP_NODE in upthreshold downdifferential polling_interval; do
                restore_node "$GP_STATE" "$GP_NODE" "$GP_DEV"
            done
            return 0;;
        performance) GP_PCT=75; GP_UP=85; GP_DOWN=15;;
        fast) GP_PCT=85; GP_UP=90; GP_DOWN=10;;
        crazy) GP_PCT=95; GP_UP=95; GP_DOWN=5;;
        *) return 0;;
    esac

    GP_MIN=$(pick_opp "$GP_PCT" "$GP_MAX" "$GP_DEV/available_frequencies")
    case "$GP_MIN" in ''|*[!0-9]*) return 0;; esac
    # 不压低上限，只抬高表内下限，缩小无效跳频区间。
    if write_node "$GP_MIN" "$GP_DEV/min_freq"; then
        GP_READ=$(cat "$GP_DEV/min_freq" 2>/dev/null)
        [ "$GP_READ" = "$GP_MIN" ] || log "Mali GPU$GP_INDEX 下限回读不符，厂商策略可能覆盖（$GP_MODE）"
    else
        log "Mali GPU$GP_INDEX 下限不可写，已跳过（$GP_MODE）"
    fi
    write_node "$GP_UP" "$GP_DEV/upthreshold" || :
    write_node "$GP_DOWN" "$GP_DEV/downdifferential" || :
    # simple_ondemand 常见单位为 ms；节点不存在时不做任何兼容性强写。
    write_node 32 "$GP_DEV/polling_interval" || :
}

is_mtk_platform || exit 0
case "$MODE" in powersave|balance|performance|fast|crazy) ;; *) exit 0;; esac
GP_N=0
for GP_CLASS in /sys/class/devfreq/*; do
    [ -d "$GP_CLASS" ] || continue
    GP_REAL=$(readlink -f "$GP_CLASS" 2>/dev/null)
    case "$GP_CLASS $GP_REAL" in *mali*|*Mali*|*gpufreq*|*mtk*gpu*) ;; *) continue;; esac
    apply_device "$GP_CLASS" "$GP_N" "$MODE"
    GP_N=$((GP_N + 1))
done
exit 0
