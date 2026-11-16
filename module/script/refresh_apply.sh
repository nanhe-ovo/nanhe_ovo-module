#!/system/bin/sh
# 开机应用屏幕刷新率。
#
# 背景：部分机型（MTK / HyperOS）在开机早期把刷新率锁在 60Hz，解锁后也不恢复，
# 表现为「开机屏幕刷新率锁 60Hz」。这里在系统启动完成、屏幕解锁之后再写一次
# 系统刷新率，并在随后补写两次，抵消系统在开机/解锁阶段的静默回落。
#
# 只读写 /data/adb/nanhe_ovo 目录下由本模块自己创建的文件；拒绝符号链接；
# 任何失败都不影响开机（始终 exit 0）。

RROOT=/data/adb/nanhe_ovo
TARGET=$RROOT/refresh.txt
PIN=$RROOT/refresh_pin
TIERS='30 48 60 72 90 120 144 165 180 240'

log() {
    echo "- refresh_apply: $*"
    # 同时落到模块日志里，供 WebUI 的「运行日志」查看开机阶段的刷新率动作
    [ -d "$RROOT" ] && [ ! -L "$RROOT/log.txt" ] || return 0
    RG_MSG=$(printf '%s' "$*" | tr '\n\r\t' '   ')
    printf '%s\tinfo\tboot\t%s\n' "$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || printf '1970-01-01 00:00:00')" \
        "$RG_MSG" >> "$RROOT/log.txt" 2>/dev/null || :
    RG_LINES=$(wc -l < "$RROOT/log.txt" 2>/dev/null)
    case "$RG_LINES" in ''|*[!0-9]*) return 0;; esac
    if [ "$RG_LINES" -gt 200 ]; then
        tail -n 200 "$RROOT/log.txt" > "$RROOT/log.txt.trim" 2>/dev/null &&
            cat "$RROOT/log.txt.trim" > "$RROOT/log.txt" 2>/dev/null
        rm -f "$RROOT/log.txt.trim" 2>/dev/null
    fi
    return 0
}

# 设备声明的刷新率（整数 Hz，升序去重）
# 一个 dump 里可能同时出现 fps= / refreshRate= / renderFrameRate= / vsyncPeriod=
# （纳秒，按 1e9/period 换算）等写法，全部收集后取并集。
refresh_table() {
    RT_HZ=$(
        {
            dumpsys display 2>/dev/null
            dumpsys SurfaceFlinger 2>/dev/null
        } | awk -v lo=20 -v hi=300 '
            function take(v,   n) { n = int(v + 0.5); if (n >= lo && n <= hi) hit[n] = 1 }
            {
                line = tolower($0)

                # fps=120.000004 / refreshRate=90.0 / renderFrameRate=…
                rest = line
                while (match(rest, /(fps|refresh[-_ ]?rate|renderframerate|framerate|mrefreshrate)[ \t]*[=:]*[ \t]*[0-9]+(\.[0-9]+)?/)) {
                    seg = substr(rest, RSTART, RLENGTH)
                    v = seg
                    sub(/[^0-9]*/, "", v)
                    take(v + 0)
                    rest = substr(rest, RSTART + RLENGTH)
                }

                # vsyncPeriod=8333333（纳秒）→ 120Hz
                rest = line
                while (match(rest, /vsyncperiod[ \t]*[=:]*[ \t]*[0-9]+/)) {
                    seg = substr(rest, RSTART, RLENGTH)
                    v = seg
                    gsub(/[^0-9]/, "", v)
                    if ((v + 0) > 0) take(1000000000 / (v + 0))
                    rest = substr(rest, RSTART + RLENGTH)
                }

                # 1080x2400@120.0 / 120Hz 这类写法
                rest = line
                while (match(rest, /[0-9]+(\.[0-9]+)?[ \t]*hz/)) {
                    seg = substr(rest, RSTART, RLENGTH)
                    v = seg
                    sub(/[^0-9]*/, "", v)
                    take(v + 0)
                    rest = substr(rest, RSTART + RLENGTH)
                }
            }
            END { for (k in hit) print k }
        ' | sort -u -n | awk 'BEGIN{s=""} {s = s (s == "" ? "" : " ") $0} END{printf "%s", s}'
    )
    printf '%s' "$RT_HZ"
}
refresh_known() {
    if [ -n "$(refresh_table)" ]; then printf 1; else printf 0; fi
}
refresh_supported() {
    RS_TABLE=${1-$(refresh_table)}
    if [ -z "$RS_TABLE" ]; then printf '%s' "$TIERS"; return 0; fi
    RS_OUT=
    for RS_T in $TIERS; do
        case " $RS_TABLE " in *" $RS_T "*) RS_OUT="$RS_OUT${RS_OUT:+ }$RS_T";; esac
    done
    printf '%s' "$RS_OUT"
}
refresh_current() {
    RC_HZ=$(dumpsys SurfaceFlinger 2>/dev/null |
        sed -n 's/.*[Rr]efresh[ -][Rr]ate[: ]*\([0-9][0-9]*\(\.[0-9]*\)\?\).*/\1/p' | head -n 1)
    case "$RC_HZ" in ''|*[!0-9.]*) ;;
        *) awk -v a="$RC_HZ" 'BEGIN{printf "%d", a+0.5}'; return 0;; esac
    RC_SET=$(settings get system peak_refresh_rate 2>/dev/null)
    case "$RC_SET" in ''|null|*[!0-9.]*) return 0;; esac
    awk -v a="$RC_SET" 'BEGIN{printf "%d", a+0.5}'
}

wait_boot() {
    WB_N=0
    while [ "$WB_N" -lt 120 ]; do
        [ "$(getprop sys.boot_completed 2>/dev/null)" = 1 ] && return 0
        sleep 1
        WB_N=$((WB_N + 1))
    done
    return 1
}

apply_rate() {
    AR_HZ=$1 AR_PIN=$2
    case "$AR_HZ" in ''|*[!0-9]*) return 1;; esac
    command -v settings >/dev/null 2>&1 || return 1
    settings put system peak_refresh_rate "$AR_HZ" >/dev/null 2>&1 || return 1
    if [ "$AR_PIN" = on ]; then
        settings put system min_refresh_rate "$AR_HZ" >/dev/null 2>&1 || {
            log "写入 min_refresh_rate=$AR_HZ 失败"
            return 1
        }
    else
        settings delete system min_refresh_rate >/dev/null 2>&1
    fi
    AR_READ=$(settings get system peak_refresh_rate 2>/dev/null)
    case "$AR_READ" in ''|null) return 1;; esac
    awk -v a="$AR_READ" -v b="$AR_HZ" 'BEGIN{exit !((a+0)==(b+0))}' || return 1
    log "已应用 ${AR_HZ}Hz（下限额${AR_PIN}）"
    return 0
}

[ -d "$RROOT" ] && [ ! -L "$RROOT" ] || exit 0
[ "$(id -u 2>/dev/null)" = 0 ] || exit 0

wait_boot || { log '等待开机完成超时，跳过'; exit 0; }

SUPPORTED=$(refresh_supported)
KNOWN=$(refresh_known)

PIN_STATE=off
[ -f "$PIN" ] && PIN_STATE=on

TARGET_HZ=
if [ -f "$TARGET" ]; then
    if [ -L "$TARGET" ]; then
        log 'refresh.txt 是符号链接，已忽略'
    else
        SAVED=$(cat "$TARGET" 2>/dev/null)
        case " $SUPPORTED " in *" $SAVED "*) TARGET_HZ=$SAVED;; esac
    fi
fi

# 没有保存过目标（首次开机）：取本机支持的最高档，直接解决「开机锁 60Hz」。
# 读不到档位表时不要凭空猜最高档（可能给到这块屏根本不支持的 240Hz），
# 改成沿用系统当前的刷新率——它至少是本机正在跑的值。
if [ -z "$TARGET_HZ" ]; then
    if [ "$KNOWN" = 1 ]; then
        for TIER in $TIERS; do
            case " $SUPPORTED " in *" $TIER "*) TARGET_HZ=$TIER;; esac
        done
        WHY="首次开机默认取最高档"
    else
        CUR=$(refresh_current)
        case " $SUPPORTED " in *" $CUR "*) TARGET_HZ=$CUR;; esac
        WHY="未读到档位表，沿用当前刷新率"
    fi
    [ -n "$TARGET_HZ" ] || { log '无法确定可用刷新率档位，跳过'; exit 0; }
    PIN_STATE=on
    printf '%s\n' "$TARGET_HZ" > "$TARGET" 2>/dev/null || log "保存目标 ${TARGET_HZ}Hz 失败"
    : > "$PIN" 2>/dev/null || :
    log "${WHY} ${TARGET_HZ}Hz"
fi

apply_rate "$TARGET_HZ" "$PIN_STATE" || log '首次应用失败'
# 系统在解锁后的几秒内可能再次回落，补写两次
sleep 6
apply_rate "$TARGET_HZ" "$PIN_STATE" || log '第二次应用失败'
sleep 10
apply_rate "$TARGET_HZ" "$PIN_STATE" || log '第三次应用失败'

exit 0
