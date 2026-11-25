#!/system/bin/sh
# 自研 CPU 策略层：读取构建期生成的 cpu_profiles.tsv，把每个集群的
# scaling_max_freq 限制到当前模式对应的真实 OPP，不再依赖 uperf 进程。
#
# 设计边界：
# - JSON 仍是唯一配置源；本脚本只消费 tools/gen_cpu_profiles.py 生成的表。
# - 不修改 governor，不写厂商私有 PPM；标准 cpufreq 节点写失败就记日志跳过。
# - 模式上限是「上限」，不是常开频率；低负载仍由 schedutil / 厂商 DVFS 下调。
# - crazy 档的 max_khz=0 表示运行期取 cpuinfo_max_freq，不把 999 写进节点。

MODDIR=$(cd "$(dirname "$0")/.." 2>/dev/null && pwd)
RUNTIME=${NANHE_RUNTIME:-/data/adb/nanhe_ovo}
USER_PATH=${NANHE_USER_PATH:-/sdcard/Android/yc/uperf}
SYSFS=${NANHE_SYSFS:-/sys/}
TABLE=$MODDIR/cpu_profiles.tsv
MODE_FILE=$USER_PATH/cur_powermode.txt
LOGFILE=$RUNTIME/cpu_policy.log
BASEFILE=$RUNTIME/cpu_policy_base.tsv
TAB=$(printf '\t')

cp_log() {
    [ -d "$RUNTIME" ] || return 0
    printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)" "$*" >> "$LOGFILE" 2>/dev/null || :
    if [ "$(wc -l < "$LOGFILE" 2>/dev/null | tr -d ' ')" -gt 240 ] 2>/dev/null; then
        tail -n 200 "$LOGFILE" > "$LOGFILE.tmp" 2>/dev/null && cat "$LOGFILE.tmp" > "$LOGFILE" 2>/dev/null
        rm -f "$LOGFILE.tmp"
    fi
}

valid_mode() {
    case "$1" in powersave|balance|performance|fast|crazy) return 0;; *) return 1;; esac
}

read_mode() {
    M=$(cat "$MODE_FILE" 2>/dev/null)
    valid_mode "$M" || M=balance
    printf '%s' "$M"
}

read_soc() {
    S=$(cat "$RUNTIME/device_config.txt" 2>/dev/null)
    case "$S" in ''|*[!A-Za-z0-9_.+-]*) S=unknown;; esac
    printf '%s' "$S"
}

# 读取一个 policy 的可用频率表，选不超过 target 的最高真实 OPP。
pick_opp() { # $1=policy 目录  $2=目标 kHz
    OPP_FILE=$1/scaling_available_frequencies
    if [ -r "$OPP_FILE" ]; then
        OPP=$(tr -s ' \t\r\n' '\n' < "$OPP_FILE" 2>/dev/null | awk -v t="$2" '
            $1 ~ /^[0-9]+$/ { if ($1 <= t) best = $1 }
            END { if (best != "") print best }
        ')
        [ -n "$OPP" ] && { printf '%s' "$OPP"; return 0; }
    fi
    # 没有可用表时退回 cpuinfo_max_freq；仍取不到就不写。
    HW=$(cat "$1/cpuinfo_max_freq" 2>/dev/null)
    case "$HW" in ''|*[!0-9]*) return 1;; esac
    [ "$2" -le 0 ] && { printf '%s' "$HW"; return 0; }
    [ "$2" -lt "$HW" ] && { printf '%s' "$2"; return 0; }
    printf '%s' "$HW"
}

find_policy() { # $1=簇首核
    for P in "$SYSFS"/devices/system/cpu/cpufreq/policy*; do
        [ -d "$P" ] || continue
        RELATED=$(cat "$P/related_cpus" 2>/dev/null)
        case " $RELATED " in *" $1 "*) printf '%s' "$P"; return 0;; esac
        # 没有 related_cpus 时按目录编号兜底（policy0 / policy4 / policy7）
        case "${P##*/policy}" in
            "$1") printf '%s' "$P"; return 0;;
        esac
    done
    return 1
}

write_node() { # $1=节点  $2=值
    [ -e "$1" ] || return 1
    printf '%s\n' "$2" > "$1" 2>/dev/null || return 1
    RV=$(cat "$1" 2>/dev/null)
    [ "$RV" = "$2" ]
}

snapshot_base() {
    [ -f "$BASEFILE" ] && return 0
    : > "$BASEFILE.tmp" || return 1
    for P in "$SYSFS"/devices/system/cpu/cpufreq/policy*; do
        [ -r "$P/scaling_max_freq" ] || continue
        MAX=$(cat "$P/scaling_max_freq" 2>/dev/null)
        MIN=$(cat "$P/scaling_min_freq" 2>/dev/null)
        case "$MAX" in ''|*[!0-9]*) continue;; esac
        case "$MIN" in ''|*[!0-9]*) MIN=0;; esac
        printf '%s\t%s\t%s\n' "$P" "$MIN" "$MAX" >> "$BASEFILE.tmp" || return 1
    done
    mv "$BASEFILE.tmp" "$BASEFILE" 2>/dev/null || return 1
}

# 顶层 top-app 的 uclamp.min：只给游戏前台一个软下限，不锁死频率。
# 0–1024 是 Android 的 uclamp 标尺；没有这个节点就静默跳过。
apply_uclamp() { # $1=mode
    case "$1" in
        powersave) UV=0;; balance) UV=0;; performance) UV=160;; fast) UV=256;; crazy) UV=384;; *) UV=0;;
    esac
    for D in /dev/cpuctl/top-app /dev/cpuctl/foreground; do
        [ -e "$D/cpu.uclamp.min" ] || continue
        write_node "$D/cpu.uclamp.min" "$UV" 2>/dev/null || cp_log "uclamp 写入失败：$D（模式 $1）"
        return 0
    done
    return 0
}

apply_from_table() { # $1=soC  $2=mode
    AS_SOC=$1 AS_MODE=$2
    AS_ROWS=$(awk -F '\t' -v s="$AS_SOC" -v m="$AS_MODE" '
        /^#/ || NF < 5 { next }
        $1 == s && $2 == m { print $3 "\t" $4 "\t" $5 }
    ' "$TABLE" 2>/dev/null)
    [ -n "$AS_ROWS" ] || return 1
    AS_OK=0 AS_FAIL=0
    printf '%s\n' "$AS_ROWS" > "$RUNTIME/.cpu_policy_rows" || return 1
    while IFS=$TAB read -r CL FIRST TARGET; do
        [ -n "$CL" ] || continue
        POLICY=$(find_policy "$FIRST") || {
            cp_log "找不到簇 $CL（首核 $FIRST）的 cpufreq policy，跳过"
            AS_FAIL=$((AS_FAIL + 1))
            continue
        }
        MAX=$(pick_opp "$POLICY" "$TARGET") || {
            cp_log "簇 $CL 没有可用 OPP（目标 ${TARGET}kHz），跳过"
            AS_FAIL=$((AS_FAIL + 1))
            continue
        }
        CMIN=$(cat "$POLICY/scaling_min_freq" 2>/dev/null)
        case "$CMIN" in ''|*[!0-9]*) CMIN=0;; esac
        if [ "$CMIN" -gt "$MAX" ] 2>/dev/null; then
            LOW=$(pick_opp "$POLICY" "$MAX") || LOW=$MAX
            write_node "$POLICY/scaling_min_freq" "$LOW" 2>/dev/null || cp_log "簇 $CL 下调 min 失败"
        fi
        if write_node "$POLICY/scaling_max_freq" "$MAX"; then
            AS_OK=$((AS_OK + 1))
        else
            AS_FAIL=$((AS_FAIL + 1))
            cp_log "簇 $CL 写上限失败：目标 ${MAX}kHz（节点可能只读或被厂商 PPM 接管）"
        fi
    done < "$RUNTIME/.cpu_policy_rows"
    rm -f "$RUNTIME/.cpu_policy_rows" 2>/dev/null || :
    cp_log "模式 $AS_MODE 已应用：$AS_OK 个簇成功，$AS_FAIL 个失败（SoC $AS_SOC）"
    [ "$AS_OK" -gt 0 ]
}

# template / 未匹配平台没有功耗模型：用硬件峰值的温和比例兜底，
# 避免「没有表就完全不接管」导致系统 DVFS 自由升降频。
apply_generic() { # $1=mode
    case "$1" in
        powersave) PCT=60;; balance) PCT=80;; performance) PCT=94;; fast) PCT=94;; crazy) PCT=100;; *) PCT=100;;
    esac
    AG_OK=0 AG_FAIL=0
    for P in "$SYSFS"/devices/system/cpu/cpufreq/policy*; do
        [ -d "$P" ] || continue
        HW=$(cat "$P/cpuinfo_max_freq" 2>/dev/null)
        case "$HW" in ''|*[!0-9]*) continue;; esac
        TARGET=$((HW * PCT / 100))
        MAX=$(pick_opp "$P" "$TARGET") || continue
        CMIN=$(cat "$P/scaling_min_freq" 2>/dev/null)
        case "$CMIN" in ''|*[!0-9]*) CMIN=0;; esac
        [ "$CMIN" -gt "$MAX" ] 2>/dev/null && write_node "$P/scaling_min_freq" "$MAX" 2>/dev/null || :
        if write_node "$P/scaling_max_freq" "$MAX"; then
            AG_OK=$((AG_OK + 1))
        else
            AG_FAIL=$((AG_FAIL + 1))
        fi
    done
    cp_log "无平台功耗模型，使用通用上限 ${PCT}%：$AG_OK 个簇成功，$AG_FAIL 个失败（模式 $1）"
    [ "$AG_OK" -gt 0 ]
}

do_apply() { # $1=mode
    A_MODE=$1
    valid_mode "$A_MODE" || { echo "invalid mode: $A_MODE" >&2; return 1; }
    mkdir -p "$RUNTIME" 2>/dev/null
    snapshot_base || :
    SOC=$(read_soc)
    if [ -f "$TABLE" ] && apply_from_table "$SOC" "$A_MODE"; then
        apply_uclamp "$A_MODE"
        printf 'ok\tpolicy\t%s\t%s\n' "$A_MODE" "$SOC"
        return 0
    fi
    if apply_generic "$A_MODE"; then
        apply_uclamp "$A_MODE"
        printf 'ok\tpolicy\t%s\t%s\tgeneric\n' "$A_MODE" "$SOC"
        return 0
    fi
    cp_log "模式 $A_MODE 应用失败：没有可写的 cpufreq 节点"
    return 1
}

do_status() {
    SOC=$(read_soc)
    MODE=$(read_mode)
    ROWS=0
    READY=no
    if [ -f "$TABLE" ]; then
        ROWS=$(awk -F '\t' -v s="$SOC" '$1 == s && NF >= 5 { n++ } END { print n + 0 }' "$TABLE" 2>/dev/null)
        [ "$ROWS" -gt 0 ] && READY=yes
    fi
    printf 'mode\t%s\n' "$MODE"
    printf 'soc\t%s\n' "$SOC"
    printf 'rows\t%s\n' "$ROWS"
    printf 'ready\t%s\n' "$READY"
}

case "$1" in
    apply) do_apply "$2";;
    status) do_status;;
    current) read_mode;;
    restore)
        # 恢复本层在本次开机第一次 apply 前记录的上限；没有快照就无动作。
        [ -f "$BASEFILE" ] || exit 0
        while IFS=$TAB read -r P MIN MAX; do
            [ -n "$P" ] || continue
            [ -e "$P/scaling_max_freq" ] || continue
            case "$MIN" in ''|*[!0-9]*) MIN=0;; esac
            case "$MAX" in ''|*[!0-9]*) continue;; esac
            [ "$MIN" -gt 0 ] 2>/dev/null && write_node "$P/scaling_min_freq" "$MIN" 2>/dev/null || :
            write_node "$P/scaling_max_freq" "$MAX" 2>/dev/null || :
        done < "$BASEFILE"
        rm -f "$BASEFILE"
        printf 'ok\trestore\n'
        ;;
    *) printf 'usage: %s apply MODE|status|current|restore\n' "$0" >&2; exit 1;;
esac
