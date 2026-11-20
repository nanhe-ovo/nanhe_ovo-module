#!/system/bin/sh
# 线程调度引擎封装（引擎：AppOptR，作者 SutoLiu，GPL-3.0，https://gitee.com/sutoliu/AppOptR）
# 由 control.sh（WebUI 后端）与 thread_svc.sh（开机服务）共同引用。
# 本库只负责：档位配置生成（原子热载）、守护进程起停、crazy 档 core_ctl 保核/恢复。

THREAD_ROOT=/data/adb/nanhe_ovo/thread
THREAD_ACTIVE=$THREAD_ROOT/active.conf
THREAD_USER=$THREAD_ROOT/user.conf
THREAD_PROFILE=$THREAD_ROOT/profile.txt
THREAD_DISABLED=/data/adb/nanhe_ovo/thread_disabled
APPOpt_BIN=/data/adb/modules/nanhe_ovo/bin/appopt/AppOpt
THREAD_CPU_SET=nanhe_opt

# 拓扑展开：语义核（e/p/hp/all）必须落成确定的数字掩码再交给引擎。
# 引擎在 2 簇与单簇平台上会把 p-core / hp-core 解析成空集，空集会连带清空
# 基础 cpuset 的 cpus，游戏线程被塞进无 CPU 的 cgroup，表现为启动卡死/闪退。
TOPO_ALL=${TOPO_ALL:-0-7}
TOPO_BG=${TOPO_BG:-0-7}
TOPO_REND=${TOPO_REND:-0-7}
TOPO_MAIN=${TOPO_MAIN:-0-7}
TOPO_MAIN2=${TOPO_MAIN2:-$TOPO_MAIN}
TOPO_GAME=${TOPO_GAME:-$TOPO_ALL}
TOPO_SPIRE=${TOPO_SPIRE:-0}

thread_topo() {
    for _lt in "${MODDIR:-/data/adb/modules/nanhe_ovo}/script/libtopo.sh" \
               /data/adb/modules/nanhe_ovo/script/libtopo.sh; do
        [ -f "$_lt" ] && . "$_lt" && { topo_init; return 0; }
    done
    return 1
}

# 读 stdin，把规则行右侧的语义核展开为数字掩码；空结果回退全核。
thread_expand_stream() {
    awk -v E="$TOPO_BG" -v P="$TOPO_REND" -v H="$TOPO_MAIN" -v A="$TOPO_ALL" '
    function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
    {
        line = $0
        if (line ~ /^[ \t]*#/ ) { print line; next }
        if (line ~ /^[ \t]*$/) { print line; next }
        eq = index(line, "=")
        if (eq == 0) { print line; next }
        left = substr(line, 1, eq)
        rest = substr(line, eq + 1)
        tail = ""
        if (match(rest, /[ \t]*\{/)) { tail = substr(rest, RSTART); rest = substr(rest, 1, RSTART - 1) }
        rest = trim(rest)
        if (rest == "") { print line; next }
        n = split(rest, parts, ",")
        out = ""; bad = 0
        for (i = 1; i <= n; i++) {
            p = trim(parts[i])
            if (p == "e-core") p = E
            else if (p == "p-core") p = P
            else if (p == "hp-core") p = H
            else if (p == "all-core") p = A
            if (p == "") { bad = 1; break }
            out = out (i > 1 ? "," : "") p
        }
        if (bad || out == "") { print left A tail; next }
        print left out tail
    }'
}

# 当前生效的档位名（由上次 thread_gen_conf 写入）
thread_profile() {
    TP=$(cat "$THREAD_PROFILE" 2>/dev/null)
    case "$TP" in ''|*[!a-z0-9_]*) TP=;; esac
    printf '%s' "$TP"
}

# AppOpt 守护进程 pid（空格分隔；无则空）
thread_pid() {
    TPID=
    if command -v pidof >/dev/null 2>&1; then TPID=$(pidof AppOpt 2>/dev/null); fi
    case "$TPID" in *[!0-9' ']*) TPID=;; esac
    printf '%s' "$TPID"
}

# 状态文案：已关闭（用户开关）/ 运行中 / 未运行
thread_report() {
    if [ -f "$THREAD_DISABLED" ]; then printf '已关闭'; return 0; fi
    if [ -n "$(thread_pid)" ]; then printf '运行中'; else printf '未运行'; fi
}

# 用户开关状态：on=启用的开关；off=关闭
thread_manage_state() {
    if [ -f "$THREAD_DISABLED" ]; then printf off; else printf on; fi
}

# 生成 active.conf = 模块档位规则 + 用户单应用规则。
# 保持 inode 的整文件覆盖（AppOptR 的 inotify 监听 IN_CLOSE_WRITE，立即热载）。
# 参数：档位名（powersave/balance/performance/fast/crazy，未知时回退 balance）。
thread_gen_conf() { # $1: mode
    TG_MODE=$1
    case "$TG_MODE" in ''|*[!a-z0-9_]*) TG_MODE=balance;; esac
    TG_SRC=/data/adb/modules/nanhe_ovo/appopt/appopt_${TG_MODE}.conf
    [ -f "$TG_SRC" ] || TG_SRC=/data/adb/modules/nanhe_ovo/appopt/appopt_balance.conf
    [ -f "$TG_SRC" ] || return 1
    thread_topo
    mkdir -p "$THREAD_ROOT" 2>/dev/null || return 1
    [ ! -L "$THREAD_ROOT" ] && [ ! -L "$THREAD_ACTIVE" ] && [ ! -L "$THREAD_USER" ] || return 1
    chmod 0700 "$THREAD_ROOT" 2>/dev/null
    : > "$THREAD_ROOT/.active.tmp" 2>/dev/null || return 1
    thread_expand_stream < "$TG_SRC" > "$THREAD_ROOT/.active.tmp" || { rm -f "$THREAD_ROOT/.active.tmp"; return 1; }
    if [ -f "$THREAD_USER" ]; then
        thread_expand_stream < "$THREAD_USER" >> "$THREAD_ROOT/.active.tmp" || { rm -f "$THREAD_ROOT/.active.tmp"; return 1; }
    fi
    cat "$THREAD_ROOT/.active.tmp" > "$THREAD_ACTIVE" || { rm -f "$THREAD_ROOT/.active.tmp"; return 1; }
    rm -f "$THREAD_ROOT/.active.tmp"
    printf '%s\n' "$TG_MODE" > "$THREAD_PROFILE" 2>/dev/null || :
    return 0
}

# 启动守护进程：cwd 放在运行目录（AppOpt.json 设置落在这里），
# eBPF 程序与主程序同目录（$APPOpt_BIN 的父目录），内核无 BTF 时引擎自行回退 proc 模式。
thread_start() {
    [ ! -f "$THREAD_DISABLED" ] || return 0
    [ -n "$(thread_pid)" ] && return 0
    [ -x "$APPOpt_BIN" ] || return 1
    mkdir -p "$THREAD_ROOT" 2>/dev/null || return 1
    chmod 0700 "$THREAD_ROOT" 2>/dev/null
    ( cd "$THREAD_ROOT" && nohup "$APPOpt_BIN" -c "$THREAD_ACTIVE" -s 2 -b "$THREAD_CPU_SET" >/dev/null 2>&1 & )
    return 0
}

# 停止守护进程并尽力清理 cpuset 分组（空目录才能 rmdir，失败不报错）。
thread_stop() {
    TPID_LIST=$(thread_pid)
    if [ -n "$TPID_LIST" ]; then kill $TPID_LIST 2>/dev/null; fi
    if [ -d "/dev/cpuset/$THREAD_CPU_SET" ]; then
        set +f
        rmdir "/dev/cpuset/$THREAD_CPU_SET"/* 2>/dev/null
        set -f
        rmdir "/dev/cpuset/$THREAD_CPU_SET" 2>/dev/null
    fi
    return 0
}

# ------------------------------------------------ crazy 档保核（core_ctl）
# 基线：/data/adb/nanhe_ovo/corectl.<boot_id>.tsv，每行 path<TAB>min<TAB>max
CORECTL_BASE() { printf '%s/corectl.%s.tsv' /data/adb/nanhe_ovo "$1"; }

# 进入 crazy：把每个热插拔簇的 min_cpus 抬到 max_cpus，避免核心下线/上线抖动。
# 首次调用时记录本机基线，退出 crazy 时恢复。
thread_corectl_pin() { # $1: boot_id
    CT_BOOT=$1
    case "$CT_BOOT" in ''|*[!a-fA-F0-9-]*) return 1;; esac
    CT_BASE=$(CORECTL_BASE "$CT_BOOT")
    [ ! -L "$CT_BASE" ] || return 1
    CT_SEEN=0 CT_PINNED=0
    set +f
    for CT_MAX in /sys/devices/system/cpu/cpu*/core_ctl/max_cpus; do
        [ -r "$CT_MAX" ] || continue
        CT_MIN=${CT_MAX%/*}/min_cpus
        [ -r "$CT_MIN" ] || continue
        CT_VMAX=$(cat "$CT_MAX" 2>/dev/null); CT_VMIN=$(cat "$CT_MIN" 2>/dev/null)
        case "$CT_VMAX$CT_VMIN" in ''|*[!0-9]*) continue;; esac
        CT_SEEN=$((CT_SEEN + 1))
        if [ ! -f "$CT_BASE" ]; then
            printf '%s\t%s\t%s\n' "$CT_MIN" "$CT_VMIN" "$CT_VMAX" >> "$CT_BASE" 2>/dev/null || return 1
        fi
        [ "$CT_VMIN" = "$CT_VMAX" ] && continue
        chmod a+w "$CT_MIN" 2>/dev/null || continue
        printf '%s\n' "$CT_VMAX" > "$CT_MIN" 2>/dev/null || { chmod a-w "$CT_MIN" 2>/dev/null; continue; }
        chmod a-w "$CT_MIN" 2>/dev/null
        [ "$(cat "$CT_MIN" 2>/dev/null)" = "$CT_VMAX" ] && CT_PINNED=$((CT_PINNED + 1))
    done
    set -f
    [ "$CT_SEEN" -gt 0 ] && [ -f "$CT_BASE" ]
}

# 退出 crazy：按基线恢复 min_cpus。无基线时无事可做。
thread_corectl_unpin() { # $1: boot_id
    CT_BOOT=$1
    case "$CT_BOOT" in ''|*[!a-fA-F0-9-]*) return 1;; esac
    CT_BASE=$(CORECTL_BASE "$CT_BOOT")
    [ -f "$CT_BASE" ] && [ ! -L "$CT_BASE" ] || return 0
    CT_OK=0
    while IFS="$(printf '\t')" read -r CT_PATH CT_MIN CT_MAX; do
        [ -n "$CT_PATH" ] || continue
        case "$CT_PATH" in /sys/devices/system/cpu/cpu*/core_ctl/min_cpus) ;; *) return 1;; esac
        case "$CT_MIN$CT_MAX" in ''|*[!0-9]*) return 1;; esac
        [ -r "$CT_PATH" ] || continue
        CT_NOW=$(cat "$CT_PATH" 2>/dev/null)
        case "$CT_NOW" in ''|*[!0-9]*) continue;; esac
        [ "$CT_NOW" = "$CT_MIN" ] && { CT_OK=$((CT_OK + 1)); continue; }
        chmod a+w "$CT_PATH" 2>/dev/null || continue
        printf '%s\n' "$CT_MIN" > "$CT_PATH" 2>/dev/null
        chmod a-w "$CT_PATH" 2>/dev/null
        [ "$(cat "$CT_PATH" 2>/dev/null)" = "$CT_MIN" ] && CT_OK=$((CT_OK + 1))
    done < "$CT_BASE"
    return 0
}
