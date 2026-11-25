#!/system/bin/sh
# DDR / 总线带宽上限：按模式把 devfreq 与 MTK bus_dcvs 的 max_freq 压到
# hw_max_freq 的 45%~90%，不再长期钉 100%。保留 CPU/GPU 频率策略的调节空间，
# 但避免 DDR 长时间满频导致内存/主板区域发热。
MODE=${1:-balance}
case "$MODE" in
    powersave) PCT=45 ;;
    balance) PCT=65 ;;
    performance) PCT=75 ;;
    fast) PCT=82 ;;
    crazy) PCT=90 ;;
    *) exit 0 ;;
esac

cap_node() { # $1=max_freq 节点
    NODE=$1
    [ -f "$NODE" ] || return 0
    HW=${NODE%/max_freq}/hw_max_freq
    HW_VAL=$(cat "$HW" 2>/dev/null)
    case "$HW_VAL" in ''|*[!0-9]*)
        HW_VAL=$(awk '{ for (i = 1; i <= NF; i++) { f = $i + 0; if (f > max) max = f } } END { print max + 0 }' "${NODE%/max_freq}/available_frequencies" 2>/dev/null)
        ;;
    esac
    case "$HW_VAL" in ''|*[!0-9]*) return 0;; esac
    [ "$HW_VAL" -gt 0 ] 2>/dev/null || return 0
    TARGET=$((HW_VAL * PCT / 100))
    [ "$TARGET" -gt 0 ] 2>/dev/null || return 0
    chmod 0666 "$NODE" 2>/dev/null || :
    printf '%s\n' "$TARGET" > "$NODE" 2>/dev/null || :
}

# MTK bus_dcvs：DDR / LLCC / L3 各自由 hw_max_freq 决定上限。
for D in /sys/devices/system/cpu/bus_dcvs/DDR /sys/devices/system/cpu/bus_dcvs/LLCC /sys/devices/system/cpu/bus_dcvs/L3; do
    [ -d "$D" ] || continue
    for N in "$D"/*/max_freq; do
        [ -e "$N" ] && cap_node "$N"
    done
done

# 通用 devfreq：只匹配 DDR / 总线带宽类节点，不碰 GPU、相机、编码器。
for N in /sys/class/devfreq/*/max_freq; do
    [ -e "$N" ] || continue
    case "${N%/max_freq}" in
        *ddr*|*DDR*|*cpubw*|*gpubw*|*llccbw*|*cpu-llcc*|*cpu-ddr*|*llcc-ddr*|*bus*|*snoc*|*noc*) cap_node "$N" ;;
    esac
done
