#!/system/bin/sh
# 南何ovo WebUI 后端。只使用固定路径，从不读取可写目录里的脚本。
#
# 命令：
#   status                          读取状态（模式列表 / 频率节点 / 进程 / 调优开关）
#   apps                            已安装应用包名
#   rules                           当前分应用规则原文
#   rule PACKAGE MODE|delete        写入或删除一条分应用调度策略
#   mode MODE                       切换全局性能模式
#   freq ID MIN MAX                 写入某个 CPU 策略 / GPU 节点的频率区间
#   restore                         恢复本次开机的原始频率边界
#   tune on|off                     开关开机系统级调优（下次开机生效）
#   refresh HZ on|off               设置屏幕刷新率；on 同时钉住下限，取消静止降频
#   deviceinfo                      机型与系统信息（只读，供关于页展示）
#   logs / clearlog                 读取 / 清空运行日志
#   logline LEVEL TAG MESSAGE       由页面写入一条日志（前端发现的问题自动记录）

PATH=/system/bin:/system/xbin
export PATH
LC_ALL=C
export LC_ALL
unset ENV BASH_ENV CDPATH
umask 077
set -f
RUNTIME_ROOT=/data/adb/nanhe_ovo
RUNTIME=/data/adb/nanhe_ovo/runtime
LOG_FILE=/data/adb/nanhe_ovo/log.txt
LOG_ONCE=/data/adb/nanhe_ovo/.log_once
LOG_MAX=200
TUNE_FLAG=/data/adb/nanhe_ovo/tune_disabled
MODULE=/data/adb/modules/nanhe_ovo
UPERF=/sdcard/Android/yc/uperf
LOCKED=0
TX_ACTIVE=0
TEXT_ACTIVE=0
CT_TMP=
WORK=

err() { printf '%s\n' "control: $*" >&2; log_write error "${CMD:-control}" "$*"; }
fail() { err "$*"; exit 1; }
# ---------------------------------------------------------------- 运行日志
# 就地记录：命令失败、后端读到异常状态、前端上报的页面问题都写进
# /data/adb/nanhe_ovo/log.txt；超过 LOG_MAX 行就裁掉最早的，避免无限增长。
log_stamp() { date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || printf '1970-01-01 00:00:00'; }
log_sane() {
    printf '%s' "$1" | tr '\n\r\t' '   ' | sed 's/^ *//; s/ *$//' | cut -c1-200
}
log_write() { # LEVEL TAG MESSAGE
    LW_LEVEL=$1 LW_TAG=$2
    LW_MSG=$(log_sane "$3")
    case "$LW_LEVEL" in info|warn|error) ;; *) LW_LEVEL=info;; esac
    case "$LW_TAG" in ''|*[!a-z0-9_.-]*) LW_TAG=control;; esac
    [ -n "$LW_MSG" ] || return 0
    [ -d "$RUNTIME_ROOT" ] && [ ! -L "$LOG_FILE" ] || return 0
    printf '%s\t%s\t%s\t%s\n' "$(log_stamp)" "$LW_LEVEL" "$LW_TAG" "$LW_MSG" >> "$LOG_FILE" 2>/dev/null || return 0
    LW_LINES=$(wc -l < "$LOG_FILE" 2>/dev/null)
    case "$LW_LINES" in ''|*[!0-9]*) return 0;; esac
    if [ "$LW_LINES" -gt "$LOG_MAX" ]; then
        tail -n "$LOG_MAX" "$LOG_FILE" > "$LOG_FILE.trim" 2>/dev/null &&
            cat "$LOG_FILE.trim" > "$LOG_FILE" 2>/dev/null
        rm -f "$LOG_FILE.trim" 2>/dev/null
    fi
    return 0
}
# 同一开机内只记一次的诊断项（轮询 status 时不会把同一问题刷成几百行）
log_once() { # KEY LEVEL TAG MESSAGE
    LN_KEY=$1 LN_LEVEL=$2 LN_TAG=$3 LN_MSG=$4
    case "$LN_KEY" in ''|*[!a-z0-9_-]*) return 0;; esac
    [ -d "$RUNTIME_ROOT" ] && [ ! -L "$LOG_ONCE" ] || return 0
    mkdir -p "$LOG_ONCE" 2>/dev/null || return 0
    [ ! -L "$LOG_ONCE" ] || return 0
    LN_MARK=$LOG_ONCE/${BOOT:-unknown}_$LN_KEY
    [ -e "$LN_MARK" ] && return 0
    log_write "$LN_LEVEL" "$LN_TAG" "$LN_MSG"
    : > "$LN_MARK" 2>/dev/null || :
    return 0
}
is_uint() {
    case "$1" in ''|*[!0-9]*|??????????????*) return 1;; esac
    case "$1" in 0|[1-9]*) ;; *) return 1;; esac
    [ "$1" = 0 ] || [ "${1#0}" = "$1" ]
}
is_freq() { is_uint "$1" && [ "$1" != 0 ]; }
le() { awk -v a="$1" -v b="$2" 'BEGIN {exit !(a+0<=b+0)}'; }
read_num() {
    RN=$(cat "$1" 2>/dev/null) || return 1
    is_uint "$RN" || return 1
    printf '%s' "$RN"
}
# 模式名只允许小写标识符；是否存在由 uperf.json 的 presets 决定。
valid_mode() {
    case "$1" in ''|*[!a-z0-9_]*) return 1;; esac
    case "$1" in [a-z]*) ;; *) return 1;; esac
    [ "${#1}" -le 24 ] || return 1
}
valid_package() {
    case "$1" in '*'|'-') return 0;; esac
    [ "${#1}" -le 255 ] || return 1
    printf '%s\n' "$1" | awk 'BEGIN{ok=0} /^[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_]*)+$/ {ok=1} END{exit !ok}'
}

# 每次成对写入都保证不会出现 min > max 的中间状态。
# 本函数不做回滚；调用方必须在调用前写 journal。
write_pair() {
    WP_PATH=$1 WP_MIN=$2 WP_MAX=$3
    WP_OLD_MIN=$(read_num "$WP_PATH/$MIN_NODE") || return 1
    WP_OLD_MAX=$(read_num "$WP_PATH/$MAX_NODE") || return 1
    le "$WP_OLD_MIN" "$WP_OLD_MAX" || return 1
    if ! le "$WP_MIN" "$WP_OLD_MAX"; then
        printf '%s\n' "$WP_MAX" > "$WP_PATH/$MAX_NODE" || return 1
        printf '%s\n' "$WP_MIN" > "$WP_PATH/$MIN_NODE" || return 1
    else
        printf '%s\n' "$WP_MIN" > "$WP_PATH/$MIN_NODE" || return 1
        printf '%s\n' "$WP_MAX" > "$WP_PATH/$MAX_NODE" || return 1
    fi
    WP_READ_MIN=$(read_num "$WP_PATH/$MIN_NODE") || return 1
    WP_READ_MAX=$(read_num "$WP_PATH/$MAX_NODE") || return 1
    [ "$WP_READ_MIN" = "$WP_MIN" ] && [ "$WP_READ_MAX" = "$WP_MAX" ]
}
nodes_for() {
    case "$1" in cpu-policy*) MIN_NODE=scaling_min_freq; MAX_NODE=scaling_max_freq;;
        gpu-*) MIN_NODE=min_freq; MAX_NODE=max_freq;; *) return 1;; esac
}
rollback() {
    [ "$TX_ACTIVE" = 1 ] || return 0
    RB_BAD=0
    while IFS="$(printf '\t')" read -r RB_ID RB_PATH RB_MIN RB_MAX; do
        [ -n "$RB_ID" ] || continue
        nodes_for "$RB_ID" || { RB_BAD=1; continue; }
        write_pair "$RB_PATH" "$RB_MIN" "$RB_MAX" || { err "ROLLBACK FAILED: $RB_ID"; RB_BAD=1; }
    done < "$WORK/journal"
    TX_ACTIVE=0
    return "$RB_BAD"
}
text_rollback() {
    [ "$TEXT_ACTIVE" = 1 ] || return 0
    if [ "$CT_EXISTED" = 1 ]; then
        cat "$WORK/text.rollback" > "$CT_DEST" && cmp -s "$WORK/text.rollback" "$CT_DEST" || err 'TEXT ROLLBACK FAILED'
    else
        rm -f "$CT_DEST" || err 'TEXT ROLLBACK FAILED'
    fi
    TEXT_ACTIVE=0
}
cleanup() {
    rollback || :
    text_rollback
    if [ -n "$CT_TMP" ]; then rm -f "$CT_TMP" 2>/dev/null; fi
    if [ -n "$WORK" ] && [ -d "$WORK" ]; then
        # WORK 是固定运行时目录下由本脚本生成的子目录
        rm -f "$WORK"/* 2>/dev/null
        rmdir "$WORK" 2>/dev/null
    fi
    if [ "$LOCKED" = 1 ]; then rmdir "$LOCK" 2>/dev/null; fi
}
trap 'cleanup' 0
trap 'err "interrupted"; exit 1' 1 2 15

init() {
    [ "$(id -u)" = 0 ] || fail 'root required'
    BOOT=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null) || fail 'cannot read boot id'
    case "$BOOT" in ''|*[!a-fA-F0-9-]*) fail 'invalid boot id';; esac
    [ "${#BOOT}" = 36 ] || fail 'invalid boot id length'
    # 不接受任何环境变量覆盖，拒绝被替换的特权运行时路径
    for P in "$RUNTIME_ROOT" "$RUNTIME"; do
        [ ! -L "$P" ] || fail 'runtime must not be a symlink'
        if [ ! -d "$P" ]; then mkdir "$P" || fail 'cannot create runtime'; fi
        [ "$(stat -c %u "$P" 2>/dev/null)" = 0 ] || fail 'runtime must belong to root'
        chmod 700 "$P" || fail 'cannot secure runtime directory'
    done
    LOCK="$RUNTIME/lock.$BOOT"
    mkdir "$LOCK" 2>/dev/null || fail 'backend busy'
    LOCKED=1
    WORK="$RUNTIME/work.$$"
    mkdir "$WORK" || fail 'cannot create private work directory'
    BASELINE="$RUNTIME/baseline.$BOOT.tsv"
}

freq_table() {
    FT_FILE=$1
    [ -r "$FT_FILE" ] || return 0
    # 只要有一个 token 不是限长正整数，整张表作废
    awk 'BEGIN{bad=0;n=0} {for(i=1;i<=NF;i++){if($i !~ /^[1-9][0-9]*$/ || length($i)>13)bad=1; else {v[$i]=1;n++}}} END{if(!bad&&n)for(x in v)print x}' "$FT_FILE" 2>/dev/null |
        sort -n | awk 'BEGIN{s=""} {s=s (s==""?"":" ") $0} END{printf "%s",s}'
}
# 设备清单只来自固定的 sysfs 发现根目录，属于可信输出。
discover() {
    : > "$WORK/devices" || fail 'cannot create inventory'
    set +f
    for D in /sys/devices/system/cpu/cpufreq/policy*; do
        [ -d "$D" ] || continue
        N=${D##*/policy}
        case "$N" in ''|*[!0-9]*) continue;; esac
        printf 'cpu-policy%s\t%s\tCPU 策略 %s\tkHz\n' "$N" "$D" "$N" >> "$WORK/devices"
    done
    : > "$WORK/gpu-paths"
    for D in /sys/class/devfreq/* /sys/class/kgsl/kgsl-3d0/devfreq /sys/devices/platform/kgsl-3d0/devfreq; do
        [ -d "$D" ] || continue
        CANON=$(readlink -f "$D" 2>/dev/null) || continue
        case "$CANON" in /sys/devices/*) ;; *) continue;; esac
        LOWER=$(printf '%s' "$CANON" | tr '[:upper:]' '[:lower:]')
        case "$LOWER" in *gpu*|*mali*|*kgsl*) ;; *) continue;; esac
        case "$CANON" in *[!a-zA-Z0-9_./:+@-]*) continue;; esac
        [ -e "$CANON/min_freq" ] && [ -e "$CANON/max_freq" ] || continue
        printf '%s\n' "$CANON" >> "$WORK/gpu-paths"
    done
    set -f
    sort -u "$WORK/gpu-paths" > "$WORK/gpus" || fail 'cannot sort GPU inventory'
    GI=0
    while IFS= read -r D; do
        [ -n "$D" ] || continue
        printf 'gpu-%s\t%s\tGPU %s（%s）\tHz\n' "$GI" "$D" "$GI" "${D##*/}" >> "$WORK/devices"
        GI=$((GI + 1))
    done < "$WORK/gpus"
}
load_device() {
    DEVICE_LINE=$(awk -F '\t' -v id="$1" '$1==id{print;exit}' "$WORK/devices")
    [ -n "$DEVICE_LINE" ] || { err "unknown device: $1"; return 1; }
    IFS="$(printf '\t')" read -r DEVICE_ID DEVICE_PATH DEVICE_LABEL DEVICE_UNIT <<EOF
$DEVICE_LINE
EOF
    nodes_for "$DEVICE_ID" || return 1
    case "$DEVICE_ID" in cpu-*) TABLE=$(freq_table "$DEVICE_PATH/scaling_available_frequencies");;
        gpu-*) TABLE=$(freq_table "$DEVICE_PATH/available_frequencies")
            [ -n "$TABLE" ] || TABLE=$(freq_table "$DEVICE_PATH/freq_table");; esac
}
check_pair() {
    is_freq "$1" && is_freq "$2" && le "$1" "$2" || { err 'invalid frequency bounds'; return 1; }
    [ -n "$TABLE" ] || { err "$DEVICE_ID: no valid frequency table; read-only"; return 1; }
    case " $TABLE " in *" $1 "*) ;; *) err "$DEVICE_ID: minimum is not in frequency table"; return 1;; esac
    case " $TABLE " in *" $2 "*) ;; *) err "$DEVICE_ID: maximum is not in frequency table"; return 1;; esac
}
snapshot() {
    # 在第一次改动频率之前，一次性记录当时可读的全部节点
    [ ! -L "$BASELINE" ] || fail 'baseline symlink refused'
    if [ -f "$BASELINE" ]; then return 0; fi
    : > "$WORK/baseline" || fail 'cannot prepare baseline'
    while IFS="$(printf '\t')" read -r SS_ID SS_PATH SS_LABEL SS_UNIT; do
        nodes_for "$SS_ID" || continue
        SS_MIN=$(read_num "$SS_PATH/$MIN_NODE") || continue
        SS_MAX=$(read_num "$SS_PATH/$MAX_NODE") || continue
        le "$SS_MIN" "$SS_MAX" || continue
        printf '%s\t%s\t%s\t%s\n' "$SS_ID" "$SS_PATH" "$SS_MIN" "$SS_MAX" >> "$WORK/baseline" || fail 'baseline write failed'
    done < "$WORK/devices"
    [ -s "$WORK/baseline" ] || fail 'no readable baseline devices'
    mv "$WORK/baseline" "$BASELINE" || fail 'baseline commit failed'
}
ensure_baseline_device() {
    awk -F '\t' -v id="$DEVICE_ID" -v p="$DEVICE_PATH" 'NF==4&&$1==id&&$2==p{ok=1} END{exit !ok}' "$BASELINE" || {
        err "$DEVICE_ID was not captured in this boot baseline"; return 1;
    }
}
journal_device() {
    JD_MIN=$(read_num "$DEVICE_PATH/$MIN_NODE") || return 1
    JD_MAX=$(read_num "$DEVICE_PATH/$MAX_NODE") || return 1
    le "$JD_MIN" "$JD_MAX" || return 1
    printf '%s\t%s\t%s\t%s\n' "$DEVICE_ID" "$DEVICE_PATH" "$JD_MIN" "$JD_MAX" >> "$WORK/journal"
}
cmd_freq() {
    discover
    load_device "$1" || return 1
    check_pair "$2" "$3" || return 1
    snapshot
    # 快照会遍历所有设备，节点名全局量可能停在别的设备上，这里重新定位
    nodes_for "$DEVICE_ID" || return 1
    ensure_baseline_device || return 1
    : > "$WORK/journal" || return 1
    journal_device || { err 'cannot read/journal current bounds'; return 1; }
    TX_ACTIVE=1
    if ! write_pair "$DEVICE_PATH" "$2" "$3"; then
        err "$DEVICE_ID: write failed or exact readback mismatch; rolling back"
        rollback || :
        return 1
    fi
    TX_ACTIVE=0
    printf 'ok\tfreq\t%s\t%s\t%s\n' "$DEVICE_ID" "$2" "$3"
}
cmd_restore() {
    [ -f "$BASELINE" ] && [ ! -L "$BASELINE" ] || { err 'no baseline for this boot'; return 1; }
    discover
    : > "$WORK/journal" || return 1
    : > "$WORK/restore" || return 1
    # 逐条校验保存的记录，绝不执行保存的路径
    while IFS="$(printf '\t')" read -r RS_ID RS_PATH RS_MIN RS_MAX RS_EXTRA; do
        [ -n "$RS_ID" ] && [ -z "$RS_EXTRA" ] || { err 'invalid baseline record'; return 1; }
        load_device "$RS_ID" || return 1
        [ "$DEVICE_PATH" = "$RS_PATH" ] || { err 'baseline device path changed'; return 1; }
        # 未被改动的只读设备可能也在开机快照里，只读校验、不写入
        RS_NOW_MIN=$(read_num "$DEVICE_PATH/$MIN_NODE") || { err 'cannot read restore bounds'; return 1; }
        RS_NOW_MAX=$(read_num "$DEVICE_PATH/$MAX_NODE") || { err 'cannot read restore bounds'; return 1; }
        if [ "$RS_NOW_MIN" = "$RS_MIN" ] && [ "$RS_NOW_MAX" = "$RS_MAX" ]; then continue; fi
        check_pair "$RS_MIN" "$RS_MAX" || return 1
        journal_device || { err 'cannot journal current bounds'; return 1; }
        printf '%s\t%s\t%s\t%s\n' "$DEVICE_ID" "$DEVICE_PATH" "$RS_MIN" "$RS_MAX" >> "$WORK/restore" || return 1
    done < "$BASELINE"
    [ -s "$BASELINE" ] || { err 'empty baseline'; return 1; }
    TX_ACTIVE=1
    while IFS="$(printf '\t')" read -r RS_ID RS_PATH RS_MIN RS_MAX; do
        nodes_for "$RS_ID" || return 1
        if ! write_pair "$RS_PATH" "$RS_MIN" "$RS_MAX"; then
            err "$RS_ID: restore/readback failed; rolling back restore"
            rollback || :
            return 1
        fi
    done < "$WORK/restore"
    TX_ACTIVE=0
    printf 'ok\trestore\n'
}

# 完整递归下降校验 uperf.json。模式名只能是 root.presets 的直接子键，
# 字符串、注释或更深层的同名键都不能授权模式。
# 参数为空时输出合法的 presets 键（用于 WebUI 的模式列表）。
config_scan() {
    [ -f "$UPERF/uperf.json" ] || return 1
    awk -v wanted="$1" '
    function ws(){while(substr(s,p,1) ~ /[ \t\r\n]/ && p<=length(s))p++}
    function str( c,h,j){
      if(substr(s,p++,1)!="\""){bad=1;return ""} out=""
      while(p<=length(s)){
        c=substr(s,p++,1); if(c=="\"")return out
        if(c=="\\"){
          c=substr(s,p++,1)
          if(c=="u"){h=substr(s,p,4);if(length(h)!=4||h~/[^0-9a-fA-F]/){bad=1;return ""}p+=4;out=out "?"}
          else if(c ~ /^["\\\/bfnrt]$/)out=out "?";else{bad=1;return ""}
        }else{if(c ~ /[[:cntrl:]]/){bad=1;return ""}out=out c}
      }bad=1;return ""
    }
    function value(path,depth, c,k,t,n){
      if(depth>64){bad=1;return}ws();c=substr(s,p,1)
      if(c=="{"){
        if(path=="@mode")found=1
        p++;ws();if(substr(s,p,1)=="}"){p++;return}
        while(!bad){ws();if(substr(s,p,1)!="\""){bad=1;return}k=str();
          ws();if(substr(s,p++,1)!=":"){bad=1;return}
          t="!";if(path=="@root"&&k=="presets")t="@presets";else if(path=="@presets"&&k==wanted)t="@mode"
          else if(path=="@presets"&&wanted==""){if(k ~ /^[a-z][a-z0-9_]*$/ && length(k)<=24)print k}
          value(t,depth+1);ws();c=substr(s,p++,1);if(c=="}")return;if(c!=","){bad=1;return}
        }
      }else if(c=="["){
        p++;ws();if(substr(s,p,1)=="]"){p++;return}
        while(!bad){value("!",depth+1);ws();c=substr(s,p++,1);if(c=="]")return;if(c!=","){bad=1;return}}
      }else if(c=="\""){t=str()}
      else {t=substr(s,p);if(match(t,/^-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?/)){p+=RLENGTH}
        else if(substr(t,1,4)=="true"||substr(t,1,4)=="null")p+=4
        else if(substr(t,1,5)=="false")p+=5
        else bad=1}
    }
    {s=s $0 "\n";if(length(s)>4194304)exit 2}
    END{if(length(s)>4194304)exit 2;p=1;ws();if(substr(s,p,1)!="{")exit 1;value("@root",0);ws();exit (bad||p<=length(s)||(wanted!=""&&!found))}
    ' "$UPERF/uperf.json"
}
config_has_mode() { valid_mode "$1" || return 1; config_scan "$1" >/dev/null; }
config_presets() {
    PS=$(config_scan "") || return 1
    printf '%s' "$PS" | sort -u | awk 'BEGIN{s=""} {s=s (s==""?"":" ") $0} END{printf "%s",s}'
}

# 保持 inode 的写入：同目录暂存文件写完后再覆盖目标，使 uperf 的 inotify 生效。
# 每次提交前都留一份私有回滚副本和持久 .bak。
commit_text() {
    CT_DEST=$1 CT_SOURCE=$2
    [ -d "$UPERF" ] || { err 'uperf directory missing'; return 1; }
    [ ! -L "$CT_DEST" ] && [ ! -L "$CT_DEST.bak" ] || { err 'symlink destination/backup refused'; return 1; }
    if [ -e "$CT_DEST" ] && [ ! -f "$CT_DEST" ]; then err 'destination is not a regular file'; return 1; fi
    CT_TMP=$(mktemp "$UPERF/.nanhe.XXXXXX") || { err 'cannot create same-directory temp'; return 1; }
    if ! cat "$CT_SOURCE" > "$CT_TMP"; then rm -f "$CT_TMP"; err 'cannot stage text'; return 1; fi
    CT_EXISTED=0
    if [ -f "$CT_DEST" ]; then
        CT_EXISTED=1
        if ! cat "$CT_DEST" > "$WORK/text.rollback" || ! cat "$WORK/text.rollback" > "$CT_DEST.bak"; then
            rm -f "$CT_TMP"; err 'backup failed; not writing destination'; return 1
        fi
        if ! cmp -s "$WORK/text.rollback" "$CT_DEST.bak"; then rm -f "$CT_TMP"; err 'backup readback mismatch'; return 1; fi
    else
        : > "$WORK/text.rollback" || { rm -f "$CT_TMP"; return 1; }
        : > "$CT_DEST.bak" || { rm -f "$CT_TMP"; err 'backup creation failed'; return 1; }
    fi
    TEXT_ACTIVE=1
    if cat "$CT_TMP" > "$CT_DEST" && cmp -s "$CT_TMP" "$CT_DEST"; then
        TEXT_ACTIVE=0
        rm -f "$CT_TMP"
        CT_TMP=
        return 0
    fi
    err 'text commit/readback failed; rolling back'
    text_rollback
    rm -f "$CT_TMP"
    CT_TMP=
    return 1
}
cmd_rule() {
    valid_package "$1" || { err 'invalid package selector'; return 1; }
    if [ "$2" != delete ]; then
        config_has_mode "$2" || { err 'mode absent from local uperf.json presets'; return 1; }
    fi
    RULES="$UPERF/perapp_powermode.txt"
    [ ! -L "$RULES" ] || { err 'rules symlink refused'; return 1; }
    if [ -e "$RULES" ]; then
        [ -f "$RULES" ] && [ -r "$RULES" ] || { err 'cannot read rules'; return 1; }
        awk -v pkg="$1" '$1!=pkg{print}' "$RULES" > "$WORK/text.new" || return 1
    else : > "$WORK/text.new" || return 1
    fi
    if [ "$2" != delete ]; then printf '%s %s\n' "$1" "$2" >> "$WORK/text.new" || return 1; fi
    commit_text "$RULES" "$WORK/text.new" || return 1
    printf 'ok\trule\t%s\t%s\n' "$1" "$2"
}
# 超频模式（crazy）：把每个可写 CPU 集群的上限推到频率表最高档。
# 只写上限、单台独立尝试；失败按原因分类记日志并跳过，不中断模式切换。
apply_crazy_boost() {
    discover
    BOOSTED=0
    while IFS="$(printf '\t')" read -r BL_ID BL_PATH BL_LABEL BL_UNIT; do
        case "$BL_ID" in cpu-*) ;; *) continue;; esac
        nodes_for "$BL_ID" || continue
        BL_TABLE=$(freq_table "$BL_PATH/scaling_available_frequencies")
        [ -n "$BL_TABLE" ] || continue
        BL_TARGET=${BL_TABLE##* }
        is_freq "$BL_TARGET" || continue
        BL_NOW=$(read_num "$BL_PATH/$MAX_NODE") || continue
        is_freq "$BL_NOW" || continue
        [ "$BL_NOW" = "$BL_TARGET" ] && continue
        if printf '%s\n' "$BL_TARGET" > "$BL_PATH/$MAX_NODE" 2>"$WORK/boost.err"; then
            BL_READ=$(read_num "$BL_PATH/$MAX_NODE") || BL_READ=
            if [ "$BL_READ" = "$BL_TARGET" ]; then
                log_write info boost "$BL_ID: 上限 $BL_NOW → $BL_TARGET（表内最高档，不超出厂上限）"
                BOOSTED=$((BOOSTED + 1))
            else
                log_write warn boost "$BL_ID: 写入后回读不符（当前 $BL_READ），已跳过"
            fi
        else
            BL_MSG=$(log_sane "$(sed 's/^[^:]*: *//' "$WORK/boost.err" | head -n 1)")
            case "$BL_MSG" in
                *"Permission denied"*) log_write warn boost "$BL_ID: 上限节点被内核/SELinux 设为只读，无法推高（已跳过）";;
                *"No such file"*|*"not exist"*) log_write warn boost "$BL_ID: 频率节点不存在，已跳过";;
                *) log_write warn boost "$BL_ID: 写上限失败（$BL_MSG），已跳过";;
            esac
        fi
    done < "$WORK/devices"
    log_write info boost "超频模式：已尝试推高 $BOOSTED 个集群上限到表内最高档，其余按日志跳过"
    return 0
}
cmd_mode() {
    config_has_mode "$1" || { err 'mode absent from local uperf.json presets'; return 1; }
    CM_PREV=$(cat "$UPERF/cur_powermode.txt" 2>/dev/null)
    valid_mode "$CM_PREV" || CM_PREV=
    printf '%s\n' "$1" > "$WORK/text.new" || return 1
    commit_text "$UPERF/cur_powermode.txt" "$WORK/text.new" || return 1
    if [ "$1" = crazy ]; then
        apply_crazy_boost || :
    elif [ "$CM_PREV" = crazy ]; then
        # 离开超频模式：恢复本次开机的频率基线（无基线则无事可做）
        [ -f "$BASELINE" ] && cmd_restore || :
    fi
    sh "$MODULE/script/gpu_profile.sh" "$1" >/dev/null 2>&1 ||
        log_write warn gpu 'GPU 分模式窗口应用失败，已保留当前节点值'
    printf 'ok\tmode\t%s\n' "$1"
}
cmd_tune() {
    case "$1" in
        on) rm -f "$TUNE_FLAG" || { err 'cannot enable tuning'; return 1; } ;;
        off) : > "$TUNE_FLAG" || { err 'cannot disable tuning'; return 1; } ;;
        *) err 'invalid tune argument'; return 1 ;;
    esac
    printf 'ok\ttune\t%s\n' "$1"
}
module_version() {
    MV=$(awk -F '=' '$1=="version"{print $2;exit}' "$MODULE/module.prop" 2>/dev/null)
    printf '%s' "$MV" | sed 's/[^0-9A-Za-z._+-]/ /g' | tr -d ' \n'
}
device_config() {
    DC=$(cat "$RUNTIME_ROOT/device_config.txt" 2>/dev/null)
    case "$DC" in ''|*[!A-Za-z0-9_.+-]*) DC=unknown;; esac
    printf '%s' "$DC"
}

# 包名过滤：只放行「至少含一个点」的合法包名
filter_pkgs() {
    awk '/^[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_]*)+$/ && !seen[$0]++'
}

# 包名枚举：各 ROM / 各管理器环境下 pm、cmd 的可用性并不一致
# （HyperOS 上 root shell 里 `pm list packages` 可能直接退出 1）。
# 逐级降级，任何一级成功即返回；全部失败也只告警，不中断命令。
list_packages() {
    LP_OUT="$WORK/packages"
    for LP_TRY in 'pm list packages' 'pm list packages -3' 'cmd package list packages' 'pm list packages -u'; do
        # 有意让 $LP_TRY 按空格拆成命令与参数
        if $LP_TRY > "$LP_OUT" 2>/dev/null && [ -s "$LP_OUT" ]; then
            sed -n 's/^package://p' "$LP_OUT" | filter_pkgs
            return 0
        fi
    done
    # 兜底一：系统包清单（root 可读），每行首列即包名
    if [ -f /data/system/packages.list ] && [ -s /data/system/packages.list ]; then
        awk 'NF >= 1 {print $1}' /data/system/packages.list 2>/dev/null | filter_pkgs
        return 0
    fi
    # 兜底二：dumpsys package
    if command -v dumpsys >/dev/null 2>&1 && dumpsys package > "$LP_OUT" 2>/dev/null && [ -s "$LP_OUT" ]; then
        sed -n 's/^ *Package \[\([^]]*\)\].*/\1/p' "$LP_OUT" | filter_pkgs
        return 0
    fi
    err 'package enumeration unavailable; app list left empty'
    log_once apps-empty warn apps '应用包名枚举失败（pm / packages.list / dumpsys 都不可用），应用页只保留已保存的规则'
    return 0
}

# ---------------------------------------------------------------- 屏幕刷新率
# 候选档位：30–240Hz 的常用档。设备未声明的档位由 UI 置灰，并由后端拒绝写入。
REFRESH_TIERS='30 48 60 72 90 120 144 165 180 240'
REFRESH_TARGET="$RUNTIME_ROOT/refresh.txt"
REFRESH_PIN="$RUNTIME_ROOT/refresh_pin"
REFRESH_MANAGE="$RUNTIME_ROOT/refresh_manage"

# 设备声明的刷新率（整数 Hz，升序、去重、空格分隔）。
# 只读取固定系统命令的输出；一个 dump 里可能同时出现 fps= / refreshRate= /
# renderFrameRate= / vsyncPeriod=（纳秒，按 1e9/period 换算）等写法，全部收集后取并集。
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
# 1 = 真的从设备读到了档位表；0 = 读不到（此时不整体禁用，交给系统裁决）
refresh_known() {
    if [ -n "$(refresh_table)" ]; then printf 1; else printf 0; fi
}
# 候选档位与设备声明值的交集。
# 读不到设备档位表时返回全部候选档位：宁可让用户试一次被系统忽略，
# 也不要因为一次 dump 解析失败就把整块刷新率调节禁用。
refresh_supported() {
    RSUP_TABLE=${1-$(refresh_table)}
    if [ -z "$RSUP_TABLE" ]; then printf '%s' "$REFRESH_TIERS"; return 0; fi
    RSUP_OUT=
    for RSUP_T in $REFRESH_TIERS; do
        case " $RSUP_TABLE " in *" $RSUP_T "*) RSUP_OUT="$RSUP_OUT${RSUP_OUT:+ }$RSUP_T";; esac
    done
    printf '%s' "$RSUP_OUT"
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
refresh_target() {
    RV_T=$(cat "$REFRESH_TARGET" 2>/dev/null)
    case "$RV_T" in ''|*[!0-9]*) return 0;; esac
    printf '%s' "$RV_T"
}
refresh_manage_state() {
    RM_STATE=$(cat "$REFRESH_MANAGE" 2>/dev/null)
    case "$RM_STATE" in on|off) printf '%s' "$RM_STATE"; return 0;; esac
    # v1.5.0 升级兼容：旧版只要保存过目标就持续接管刷新率。
    if [ -f "$REFRESH_TARGET" ] && [ ! -L "$REFRESH_TARGET" ]; then printf on; else printf off; fi
}
refresh_save_manage() {
    [ ! -L "$REFRESH_MANAGE" ] || { err 'refresh manage state symlink refused'; return 1; }
    printf '%s\n' "$1" > "$WORK/refresh_manage.new" || { err 'cannot stage refresh manage state'; return 1; }
    cat "$WORK/refresh_manage.new" > "$REFRESH_MANAGE" || { err 'cannot save refresh manage state'; return 1; }
}
refresh_pin_state() {
    if [ "$(refresh_manage_state)" = on ] && [ -f "$REFRESH_PIN" ]; then printf on; else printf off; fi
}
refresh_restore_system() {
    RR_ORIG="$RUNTIME_ROOT/refresh_orig.txt"
    [ -f "$RR_ORIG" ] && [ ! -L "$RR_ORIG" ] || return 0
    command -v settings >/dev/null 2>&1 || { err 'settings command unavailable'; return 1; }
    RR_PEAK=$(awk -F '\t' 'NR==1{print $1}' "$RR_ORIG" 2>/dev/null)
    RR_MIN=$(awk -F '\t' 'NR==1{print $2}' "$RR_ORIG" 2>/dev/null)
    # 先解除模块钉住的下限，避免恢复较低 peak 时出现 min > peak。
    settings delete system min_refresh_rate >/dev/null 2>&1 || { err 'cannot release min_refresh_rate'; return 1; }
    case "$RR_PEAK" in ''|null) settings delete system peak_refresh_rate >/dev/null 2>&1;;
        *[!0-9.]*) err 'invalid saved peak_refresh_rate'; return 1;;
        *) settings put system peak_refresh_rate "$RR_PEAK" >/dev/null 2>&1 || { err 'cannot restore peak_refresh_rate'; return 1; };; esac
    case "$RR_MIN" in ''|null) :;;
        *[!0-9.]*) err 'invalid saved min_refresh_rate'; return 1;;
        *) settings put system min_refresh_rate "$RR_MIN" >/dev/null 2>&1 || { err 'cannot restore min_refresh_rate'; return 1; };; esac
    log_write info refresh '刷新率管理已关闭，已还原接管前的系统设置'
}
cmd_refresh_manage() {
    RMA_STATE=$1
    [ ! -L "$REFRESH_MANAGE" ] || { err 'refresh manage state symlink refused'; return 1; }
    if [ "$RMA_STATE" = off ]; then
        refresh_restore_system || return 1
        refresh_save_manage off || return 1
        rm -f "$REFRESH_PIN" 2>/dev/null || :
        printf 'ok\trefresh_manage\toff\n'
        return 0
    fi
    RMA_TARGET=$(refresh_target)
    case "$RMA_TARGET" in ''|*[!0-9]*) RMA_TARGET=$(refresh_current);; esac
    case "$RMA_TARGET" in ''|*[!0-9]*)
        for RMA_HZ in $(refresh_supported); do RMA_TARGET=$RMA_HZ; done;; esac
    case "$RMA_TARGET" in ''|*[!0-9]*) err 'cannot determine refresh target'; return 1;; esac
    cmd_refresh "$RMA_TARGET" on || return 1
    printf 'ok\trefresh_manage\ton\n'
}
# 写入系统刷新率：peak 决定上限，min 决定下限（下限钉死即「取消静止降频」）。
# 不用 min>peak 的中间态：先写 peak，再写 min。
cmd_refresh() {
    RH_HZ=$1 RH_PIN=$2
    is_uint "$RH_HZ" && [ "$RH_HZ" -ge 20 ] && [ "$RH_HZ" -le 300 ] || { err 'invalid refresh rate'; return 1; }
    [ ! -L "$REFRESH_TARGET" ] && [ ! -L "$REFRESH_PIN" ] || { err 'refresh state symlink refused'; return 1; }
    RH_SUP=$(refresh_supported)
    RH_TABLE=$(refresh_table)
    if [ -n "$RH_TABLE" ]; then
        case " $RH_SUP " in *" $RH_HZ "*) ;;
            *) err "$RH_HZ Hz is not supported by this device"; return 1;; esac
    else
        log_write info refresh "未读到档位表，已放行 ${RH_HZ}Hz（系统不接受时会保持原值）"
    fi
    if command -v settings >/dev/null 2>&1; then :; else err 'settings command unavailable'; return 1; fi
    RH_OLD_PEAK=$(settings get system peak_refresh_rate 2>/dev/null)
    RH_OLD_MIN=$(settings get system min_refresh_rate 2>/dev/null)
    # 首次写入前记下系统原值，卸载时还原（不把用户的系统设置留在模块改过的状态）
    RH_ORIG="$RUNTIME_ROOT/refresh_orig.txt"
    if [ ! -e "$RH_ORIG" ] && [ ! -L "$RH_ORIG" ]; then
        printf '%s\t%s\n' "${RH_OLD_PEAK:-null}" "${RH_OLD_MIN:-null}" > "$RH_ORIG" 2>/dev/null || :
    fi
    settings put system peak_refresh_rate "$RH_HZ" >/dev/null 2>&1 || { err 'cannot write peak_refresh_rate'; return 1; }
    if [ "$RH_PIN" = on ]; then
        settings put system min_refresh_rate "$RH_HZ" >/dev/null 2>&1 || {
            # 下限写不进去就把上限还原，避免留下「上限变了、下限没变」的中间态
            case "$RH_OLD_PEAK" in ''|null) settings delete system peak_refresh_rate >/dev/null 2>&1;;
                *) settings put system peak_refresh_rate "$RH_OLD_PEAK" >/dev/null 2>&1;; esac
            err 'cannot write min_refresh_rate; peak restored'; return 1
        }
    else
        settings delete system min_refresh_rate >/dev/null 2>&1
    fi
    RH_READ=$(settings get system peak_refresh_rate 2>/dev/null)
    case "$RH_READ" in ''|null) err 'peak_refresh_rate readback failed'; return 1;; esac
    awk -v a="$RH_READ" -v b="$RH_HZ" 'BEGIN{exit !((a+0)==(b+0))}' || { err 'peak_refresh_rate readback mismatch'; return 1; }
    if [ "$RH_PIN" = on ]; then
        RH_READ_MIN=$(settings get system min_refresh_rate 2>/dev/null)
        case "$RH_READ_MIN" in ''|null) err 'min_refresh_rate readback failed'; return 1;; esac
        awk -v a="$RH_READ_MIN" -v b="$RH_HZ" 'BEGIN{exit !((a+0)==(b+0))}' || { err 'min_refresh_rate readback mismatch'; return 1; }
    fi
    printf '%s\n' "$RH_HZ" > "$WORK/refresh.new" || { err 'cannot stage refresh target'; return 1; }
    cat "$WORK/refresh.new" > "$REFRESH_TARGET" || { err 'cannot save refresh target'; return 1; }
    if [ "$RH_PIN" = on ]; then : > "$REFRESH_PIN" || { err 'cannot save pin state'; return 1; }
    else rm -f "$REFRESH_PIN" || { err 'cannot clear pin state'; return 1; }; fi
    refresh_save_manage on || return 1
    printf 'ok\trefresh\t%s\t%s\n' "$RH_HZ" "$RH_PIN"
}

# ---------------------------------------------------------------- 机型信息
put_kv() {
    # 标签允许含空格，必须正好三个参数；漏引号会让值落到 $4 被静默丢弃
    if [ "$#" -ne 3 ]; then echo "- deviceinfo: put_kv expects 3 args, got $#" >&2; return 1; fi
    PK_OUT=$(printf '%s' "$3" | tr '\n\r\t' '   ' | sed 's/^ *//; s/ *$//')
    [ -n "$PK_OUT" ] || PK_OUT=未知
    printf 'kv\t%s\t%s\t%s\n' "$1" "$2" "$PK_OUT"
}
prop_of() { P=$(getprop "$1" 2>/dev/null); printf '%s' "$P"; }
gm() { awk -v k="$1:" '$1==k{print $2; exit}' /proc/meminfo 2>/dev/null; }
to_gib() { awk -v v="$1" 'BEGIN{ if (v=="" ) {print "未知"; exit} printf "%.2f GB", v*1024/1073741824 }'; }
cpu_count() {
    CC_RANGE=$(cat /sys/devices/system/cpu/possible 2>/dev/null)
    printf '%s' "$CC_RANGE" | awk -F- 'NF==2&&$2+0>=$1+0{print $2-$1+1; ok=1} NF==1&&$1+0>=0{print 1; ok=1} END{exit !ok}'
}
selinux_state() {
    SL=$(getenforce 2>/dev/null)
    case "$SL" in Enforcing|enforcing|1) printf '强制 Enforcing'; return 0;; Permissive|permissive|0) printf '宽容 Permissive'; return 0;; esac
    SL_RAW=$(cat /sys/fs/selinux/enforce 2>/dev/null)
    case "$SL_RAW" in 1) printf '强制 Enforcing';; 0) printf '宽容 Permissive';; esac
}
cpu_temp() {
    CT_OUT=
    set +f
    for CT_DIR in /sys/class/thermal/thermal_zone*; do
        [ -d "$CT_DIR" ] || continue
        CT_TYPE=$(cat "$CT_DIR/type" 2>/dev/null)
        case "$CT_TYPE" in *cpu*|*CPU*|*soc*|*SOC*|*ap*) ;; *) continue;; esac
        CT_RAW=$(read_num "$CT_DIR/temp") || continue
        CT_OUT=$CT_RAW
        break
    done
    set -f
    case "$CT_OUT" in ''|*[!0-9]*) return 0;; esac
    if [ "$CT_OUT" -gt 1000 ]; then awk -v v="$CT_OUT" 'BEGIN{printf "%.1f °C", v/1000}'
    else awk -v v="$CT_OUT" 'BEGIN{printf "%.1f °C", v}'; fi
}
battery_value() { printf '%s\n' "$BV_DUMP" | awk -v k="$1:" '$1==k{print $2; exit}'; }
bat_health() {
    case "$1" in 2) printf '良好';; 3) printf '过热';; 4) printf '损坏';; 5) printf '过压';; 6) printf '故障';; 7) printf '过冷';; *) printf '未知';; esac
}
bat_status() {
    case "$1" in 2) printf '充电中';; 3) printf '放电中';; 4) printf '未充电';; 5) printf '已充满';; *) printf '未知';; esac
}
power_watts() {
    PV_V=$(read_num /sys/class/power_supply/battery/voltage_now) || return 0
    PV_I=$(read_num /sys/class/power_supply/battery/current_now) || return 0
    [ "$PV_V" -gt 0 ] && [ "$PV_I" -gt 0 ] || return 0
    awk -v v="$PV_V" -v i="$PV_I" 'BEGIN{printf "%.2f W", v*i/1000000000000}'
}
cmd_deviceinfo() {
    put_kv device 品牌 "$(prop_of ro.product.brand)"
    put_kv device 型号 "$(prop_of ro.product.model)"
    put_kv device 制造商 "$(prop_of ro.product.manufacturer)"
    put_kv device 设备代号 "$(prop_of ro.product.device)"
    put_kv device 指纹 "$(prop_of ro.build.fingerprint)"
    put_kv system "Android 版本" "$(prop_of ro.build.version.release)"
    put_kv system "API 级别" "$(prop_of ro.build.version.sdk)"
    put_kv system 安全补丁 "$(prop_of ro.build.version.security_patch)"
    put_kv system 当前槽位 "$(prop_of ro.boot.slot_suffix)"
    put_kv system SELinux "$(selinux_state)"
    put_kv system "Build 号" "$(prop_of ro.build.id)"
    put_kv system 内核版本 "$(uname -r 2>/dev/null)"
    put_kv hardware 主架构 "$(prop_of ro.product.cpu.abi)"
    put_kv hardware "支持 ABI" "$(prop_of ro.product.cpu.abilist | tr ',' '/')"
    put_kv hardware 核心数 "$(cpu_count)"
    put_kv hardware 硬件 "$(prop_of ro.hardware)"
    put_kv hardware 主板 "$(prop_of ro.product.board)"
    put_kv hardware "CPU 温度" "$(cpu_temp)"
    MI_TOTAL=$(gm MemTotal) MI_AVAIL=$(gm MemAvailable)
    case "$MI_AVAIL" in ''|*[!0-9]*) MI_AVAIL=$(gm MemFree);; esac
    put_kv memory 总内存 "$(to_gib "$MI_TOTAL")"
    put_kv memory 可用内存 "$(to_gib "$MI_AVAIL")"
    case "$MI_TOTAL$MI_AVAIL" in *[!0-9]*|'') put_kv memory 已用内存 未知;;
        *) put_kv memory 已用内存 "$(to_gib "$((MI_TOTAL - MI_AVAIL))")";; esac
    put_kv memory 交换分区 "$(to_gib "$(gm SwapTotal)")"
    DF_LINE=$(df -k /data 2>/dev/null | awk 'NR==2{printf "%s %s %s", $2, $3, $4}')
    set -- $DF_LINE
    put_kv storage 总容量 "$(to_gib "$1")"
    put_kv storage 已用 "$(to_gib "$2")"
    put_kv storage 可用 "$(to_gib "$3")"
    set --
    WM_SIZE=$(wm size 2>/dev/null | sed -n 's/^ *[Pp]hysical size: *//p' | head -n 1)
    WM_SIZE_SHOW=$(printf '%s' "$WM_SIZE" | sed 's/[xX]/ × /')
    [ -n "$WM_SIZE_SHOW" ] && WM_SIZE_SHOW="$WM_SIZE_SHOW px"
    put_kv screen 分辨率 "$WM_SIZE_SHOW"
    WM_DPI=$(wm density 2>/dev/null | sed -n 's/^ *[Pp]hysical density: *//p' | head -n 1)
    put_kv screen 像素密度 "$(printf '%s' "$WM_DPI" | sed 's/$/ dpi/')"
    put_kv screen 当前刷新率 "$(RC_SHOW=$(refresh_current); if [ -n "$RC_SHOW" ]; then printf '%s Hz' "$RC_SHOW"; fi)"
    BV_DUMP=$(dumpsys battery 2>/dev/null)
    put_kv battery 电量 "$(BL=$(battery_value level); if [ -n "$BL" ]; then printf '%s%%' "$BL"; fi)"
    put_kv battery 温度 "$(BT=$(battery_value temperature); case "$BT" in ''|*[!0-9]*) ;; *) awk -v v="$BT" 'BEGIN{printf "%.1f °C", v/10}';; esac)"
    put_kv battery 健康 "$(bat_health "$(battery_value health)")"
    put_kv battery 状态 "$(bat_status "$(battery_value status)")"
    put_kv battery 技术 "$(battery_value technology)"
    put_kv battery 充电功率 "$(power_watts)"
    printf 'ok\tdeviceinfo\n'
}

# ---------------------------------------------------------------- 运行日志读取
cmd_logs() {
    if [ -L "$LOG_FILE" ]; then err 'log file symlink refused'; return 1; fi
    if [ -f "$LOG_FILE" ]; then
        while IFS="$(printf '\t')" read -r LG_TIME LG_LEVEL LG_TAG LG_MSG; do
            [ -n "$LG_TIME" ] || continue
            printf 'log\t%s\t%s\t%s\t%s\n' "$LG_TIME" "$LG_LEVEL" "$LG_TAG" "$LG_MSG"
        done < "$LOG_FILE"
    fi
    printf 'ok\tlogs\n'
}
cmd_logline() {
    LL_LEVEL=$1 LL_TAG=$2 LL_MSG=$3
    case "$LL_LEVEL" in info|warn|error) ;; *) err 'invalid log level'; return 1;; esac
    case "$LL_TAG" in ''|*[!a-z0-9_.-]*) err 'invalid log tag'; return 1;; esac
    LL_BODY=$(log_sane "$LL_MSG")
    [ -n "$LL_BODY" ] || { err 'empty log message'; return 1; }
    log_write "$LL_LEVEL" "$LL_TAG" "$LL_BODY"
    printf 'ok\tlogline\n'
}
cmd_clearlog() {
    if [ -L "$LOG_FILE" ] || [ -L "$LOG_ONCE" ]; then err 'log file symlink refused'; return 1; fi
    rm -f "$LOG_FILE" || { err 'cannot clear log'; return 1; }
    # 连去重标记一起清掉：用户主动清空后，同类问题应该能重新记录
    if [ -d "$LOG_ONCE" ]; then rm -rf "$LOG_ONCE" || { err 'cannot clear log'; return 1; }; fi
    printf 'ok\tclearlog\n'
}

# Root 方案只读探测：KernelSU 分两种形态，LKM 是把 kernelsu.ko 作为可加载模块挂上，
# GKI 是直接把 KernelSU 编进内核镜像（因此没有 /sys/module/kernelsu 节点）。
root_mode() {
    if [ -d /data/adb/ksu ] || [ -x /data/adb/ksud ]; then
        if [ -d /sys/module/kernelsu ]; then printf 'KernelSU · LKM'
        else printf 'KernelSU · GKI'; fi
        return 0
    fi
    if [ -d /data/adb/ap ] || [ -x /data/adb/apd ]; then printf 'APatch'; return 0; fi
    if [ -d /data/adb/magisk ] || [ -x /data/adb/magisk/magisk ]; then printf 'Magisk'; return 0; fi
    printf '未知'
}
# SUSFS 兼容探测代码仅保留供旧环境和后续适配；v1.6.0 的 status 不调用它。
# 本模块从不加载/卸载 .ko，也不写 kallsyms、kptr_restrict 或 /proc/susfs_*。
susfs_state() {
    if [ -e /proc/susfs_path ] || [ -d /sys/module/susfs_guard_lkm ]; then printf '已加载'; return 0; fi
    if [ -f /data/adb/modules/susfs_guard_lkm/module.prop ]; then printf '未加载（SUSFS Guard 已安装）'; return 0; fi
    printf '未安装'
}
cmd_status() {
    discover
    printf 'info\tboot_id\t%s\n' "$BOOT"
    if [ -f "$BASELINE" ] && [ ! -L "$BASELINE" ]; then BS=可用; else BS=无; fi
    printf 'info\tbaseline\t%s\n' "$BS"
    printf 'info\tconfig\t%s\n' "$UPERF/uperf.json"
    printf 'info\tversion\t%s\n' "$(module_version)"
    printf 'info\tdevice_config\t%s\n' "$(device_config)"
    if [ -f "$TUNE_FLAG" ]; then printf 'info\ttune\t关闭\n'; else printf 'info\ttune\t开启\n'; fi
    CM=$(cat "$UPERF/cur_powermode.txt" 2>/dev/null)
    valid_mode "$CM" || CM=unknown
    printf 'info\tmode\t%s\n' "$CM"
    PM="$(config_presets)" || PM=
    printf 'info\tmodes\t%s\n' "$PM"
    UP=unknown
    if command -v pidof >/dev/null 2>&1; then
        if pidof uperf >/dev/null 2>&1; then UP=运行中; else UP=未运行; fi
    fi
    printf 'info\tuperf\t%s\n' "$UP"
    RT_RATE=$(refresh_current)
    RT_TARGET=$(refresh_target)
    RT_TABLE=$(refresh_table)
    RT_SUP=$(refresh_supported "$RT_TABLE") || RT_SUP=
    printf 'info\trefresh\t%s\n' "${RT_RATE:-unknown}"
    printf 'info\trefresh_target\t%s\n' "${RT_TARGET:-none}"
    printf 'info\trefresh_pin\t%s\n' "$(refresh_pin_state)"
    printf 'info\trefresh_manage\t%s\n' "$(refresh_manage_state)"
    printf 'info\trefresh_tiers\t%s\n' "$REFRESH_TIERS"
    printf 'info\trefresh_supported\t%s\n' "$RT_SUP"
    printf 'info\trefresh_known\t%s\n' "$([ -n "$RT_TABLE" ] && printf 1 || printf 0)"
    # SUSFS 兼容探测函数保留供后续适配，但 v1.6.0 不再读取、上报或告警。
    printf 'info\troot\t%s\n' "$(root_mode)"
    # 读到异常状态时自动记一条（每开机一次，不随轮询刷屏）
    [ -n "$RT_TABLE" ] || log_once refresh-table warn refresh '未读到刷新率档位表：dumpsys display 与 SurfaceFlinger 都没有给出可用档位，已放开全部档位供尝试'
    [ -n "$RT_RATE" ] || log_once refresh-current warn refresh '读不到当前刷新率（SurfaceFlinger 与 peak_refresh_rate 都没有有效值）'
    [ "$BS" = 可用 ] || log_once baseline warn boot '本次开机没有生成频率基线，restore 将不可用'
    [ -f "$UPERF/uperf.json" ] || log_once uperf-config warn config '没有找到 uperf.json，模式与应用规则不可用'
    while IFS="$(printf '\t')" read -r ST_ID ST_PATH ST_LABEL ST_UNIT; do
        load_device "$ST_ID" || return 1
        ST_MIN=$(read_num "$DEVICE_PATH/$MIN_NODE") || ST_MIN=unknown
        ST_MAX=$(read_num "$DEVICE_PATH/$MAX_NODE") || ST_MAX=unknown
        case "$DEVICE_ID" in cpu-*) ST_CUR=$(read_num "$DEVICE_PATH/scaling_cur_freq") || ST_CUR=unknown;;
            gpu-*) ST_CUR=$(read_num "$DEVICE_PATH/cur_freq") || ST_CUR=unknown;; esac
        printf 'device\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$DEVICE_ID" "$DEVICE_LABEL" "$ST_UNIT" "$ST_MIN" "$ST_MAX" "$ST_CUR" "$TABLE"
    done < "$WORK/devices"
    printf 'ok\tstatus\n'
}

# 在任何特权文件操作之前先校验参数数量与基本语法。
[ "$#" -gt 0 ] || fail 'usage: control.sh status|apps|rules|deviceinfo|logs|clearlog|logline LEVEL TAG MSG|restore|freq ID MIN MAX|rule PACKAGE MODE|mode MODE|tune on|off|refresh HZ on|off|refresh_manage on|off'
CMD=$1; shift
case "$CMD:$#" in
    status:0|restore:0|apps:0|rules:0|deviceinfo:0|logs:0|clearlog:0) ;;
    logline:3) case "$1" in info|warn|error) ;; *) fail 'invalid log level';; esac
        case "$2" in ''|*[!a-z0-9_.-]*) fail 'invalid log tag';; esac
        [ -n "$3" ] || fail 'empty log message';;
    freq:3) case "$1" in cpu-policy[0-9]*|gpu-[0-9]*) ;; *) fail 'invalid device id';; esac
        case "${1#cpu-policy}" in *[!0-9]*) case "${1#gpu-}" in ''|*[!0-9]*) fail 'invalid device id';; esac;; esac
        is_freq "$2" && is_freq "$3" || fail 'invalid frequency';;
    rule:2) valid_package "$1" || fail 'invalid package selector'; [ "$2" = delete ] || valid_mode "$2" || fail 'invalid mode';;
    mode:1) valid_mode "$1" || fail 'invalid mode';;
    tune:1|refresh_manage:1) case "$1" in on|off) ;; *) fail 'invalid switch argument';; esac;;
    refresh:2) is_uint "$1" || fail 'invalid refresh rate'
        case "$2" in on|off) ;; *) fail 'invalid pin argument';; esac;;
    *) fail 'invalid command or argument count';;
esac
init
case "$CMD" in
    status) cmd_status;; freq) cmd_freq "$@";; restore) cmd_restore;;
    apps) list_packages;;
    rules) [ -f "$UPERF/perapp_powermode.txt" ] || fail 'rules file missing'; cat "$UPERF/perapp_powermode.txt";;
    deviceinfo) cmd_deviceinfo;;
    logs) cmd_logs;; logline) cmd_logline "$@";; clearlog) cmd_clearlog;;
    rule) cmd_rule "$@";; mode) cmd_mode "$@";; tune) cmd_tune "$@";; refresh) cmd_refresh "$@";;
    refresh_manage) cmd_refresh_manage "$@";;
esac
RC=$?
[ "$RC" = 0 ] || err "command failed: $CMD"
exit "$RC"
