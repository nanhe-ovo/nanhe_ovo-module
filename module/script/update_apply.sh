#!/system/bin/sh
# 开机落地云更新：上次开机暂存并标记的更新包，在引擎启动前一次性解压覆盖模块目录。
# 校验失败或包结构异常时只清理半成品并记日志，保留当前可用的安装，不刷入坏包。

MODDIR=$(dirname "${0%/*}")
RUNTIME_ROOT=/data/adb/nanhe_ovo
UPDATE_ROOT=$RUNTIME_ROOT/update
STAGED=$UPDATE_ROOT/staged.zip
PENDING=$UPDATE_ROOT/pending
LOG_FILE=$RUNTIME_ROOT/log.txt
BUSYBOX=$MODDIR/bin/busybox/busybox

boot_log() {
    BL_STAMP=$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || printf '1970-01-01 00:00:00')
    printf '%s\t%s\t%s\t%s\n' "$BL_STAMP" "$1" update "$2" >> "$LOG_FILE" 2>/dev/null
}

[ -f "$PENDING" ] && [ ! -L "$PENDING" ] || exit 0
[ -f "$STAGED" ] && [ ! -L "$STAGED" ] || { rm -f "$PENDING" 2>/dev/null; exit 0; }

P_VERSION=; P_SHA=
while IFS="=" read -r PK PV; do
    case "$PK" in version) P_VERSION=$PV;; sha) P_SHA=$PV;; esac
done < "$PENDING"

fail_apply() {
    boot_log error "$1"
    rm -f "$STAGED" "$PENDING" 2>/dev/null
    exit 0
}

# 二次校验摘要：暂存包在落地前又被改动或损坏时，拒绝覆盖。
case "$P_SHA" in ''|*[!0-9a-fA-F]*) ;;
    *)
        if command -v sha256sum >/dev/null 2>&1; then
            ACT_SHA=$(sha256sum "$STAGED" 2>/dev/null | awk '{print $1}')
        elif [ -x "$BUSYBOX" ]; then
            ACT_SHA=$("$BUSYBOX" sha256sum "$STAGED" 2>/dev/null | awk '{print $1}')
        else
            ACT_SHA=
        fi
        [ "$ACT_SHA" = "$P_SHA" ] || fail_apply '暂存包 SHA256 不匹配，已放弃本次更新，保留旧版本'
        ;;
esac

# 结构自检：包内必须有 module.prop。
if command -v unzip >/dev/null 2>&1; then
    unzip -l "$STAGED" 2>/dev/null | grep -q 'module.prop' || fail_apply '更新包缺少 module.prop，已放弃'
elif [ -x "$BUSYBOX" ]; then
    "$BUSYBOX" unzip -l "$STAGED" 2>/dev/null | grep -q 'module.prop' || fail_apply '更新包缺少 module.prop，已放弃'
else
    fail_apply '设备没有可用的解压工具，已放弃本次更新'
fi

# 解压覆盖模块目录；用户配置在 /sdcard/Android/yc/uperf 与线程运行时目录，不受影响。
if command -v unzip >/dev/null 2>&1; then
    unzip -o "$STAGED" -d "$MODDIR" >/dev/null 2>&1 || fail_apply '解压更新包失败，已保留旧版本'
elif [ -x "$BUSYBOX" ]; then
    "$BUSYBOX" unzip -o "$STAGED" -d "$MODDIR" >/dev/null 2>&1 || fail_apply '解压更新包失败，已保留旧版本'
else
    fail_apply '设备没有可用的解压工具，已放弃本次更新'
fi

# 解包后恢复可执行位（KernelSU / APatch 解包常丢可执行位）。
chown 0:0 "$MODDIR/bin/uperf" "$BUSYBOX" "$MODDIR"/bin/appopt/AppOpt "$MODDIR"/bin/appopt/AppOpt-ebpf 2>/dev/null
chmod 0755 "$MODDIR/bin/uperf" "$BUSYBOX" "$MODDIR"/bin/appopt/AppOpt "$MODDIR"/bin/appopt/AppOpt-ebpf 2>/dev/null
chmod 0755 "$MODDIR"/script/*.sh 2>/dev/null
chmod 0644 "$MODDIR/module.prop" 2>/dev/null
[ -d "$MODDIR/webroot" ] && chmod 0644 "$MODDIR"/webroot/* 2>/dev/null

rm -f "$STAGED" "$PENDING" 2>/dev/null
boot_log info "云更新已落地：${P_VERSION:-未知版本}，本次开机按新版本运行"
exit 0
