#!/system/bin/sh
# 南何ovo 安装脚本（Magisk / KernelSU / APatch 通用）
#
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# 引擎与平台配置来自 Uperf-Game-Turbo（作者 Matt Yang / 吟惋兮，Apache-2.0）。

SKIPUNZIP=0
MODPATH="${MODPATH:-$MODDIR}"

# 安装器（Magisk/KernelSU）自带 ui_print 与 abort；仅在没有时提供本地回退。
type ui_print >/dev/null 2>&1 || ui_print() { echo "$1"; }
type abort >/dev/null 2>&1 || abort() { ui_print "$1"; exit 1; }

VERSION="$(awk -F '=' '$1 == "version" { print $2; exit }' "$MODPATH/module.prop" 2>/dev/null)"

note() { ui_print "- $1"; }

# --- 权限标准化 ---
# KernelSU / APatch 解包模块时不会还原 zip 里记录的可执行位，文件可能以 0644 落盘；
# 因此「校验」必须排在「授权」之后，否则会把权限缺失误判成文件缺失。
fix_perms() {
    for f in "$MODPATH/bin/uperf" "$MODPATH"/bin/busybox/*; do
        [ -f "$f" ] || continue
        chown 0:0 "$f" 2>/dev/null
        chmod 0755 "$f" 2>/dev/null
    done
    for f in "$MODPATH"/customize.sh "$MODPATH"/*.sh "$MODPATH"/script/*.sh; do
        [ -f "$f" ] || continue
        chown 0:0 "$f" 2>/dev/null
        chmod 0755 "$f" 2>/dev/null
    done
    [ -f "$MODPATH/module.prop" ] && chmod 0644 "$MODPATH/module.prop" 2>/dev/null
    for f in "$MODPATH"/webroot/*; do
        [ -f "$f" ] && chmod 0644 "$f" 2>/dev/null
    done
    return 0
}

# --- 引擎就绪：解包不完整时尽量自愈，而不是直接判死 ---
ensure_engine() {
    ENGINE="$MODPATH/bin/uperf"
    [ -s "$ENGINE" ] && return 0

    # 1) 从本模块的旧安装（升级场景）取回引擎
    for prev in /data/adb/modules/nanhe_ovo/bin/uperf /data/adb/modules_update/nanhe_ovo/bin/uperf; do
        [ -s "$prev" ] || continue
        [ "$prev" = "$ENGINE" ] && continue
        cp -f "$prev" "$ENGINE" 2>/dev/null && note "已从旧安装恢复 bin/uperf"
        break
    done
    [ -s "$ENGINE" ] && return 0

    # 2) 管理器给的 ZIPFILE 还在，就按条目重新解出 bin/
    if [ -n "${ZIPFILE:-}" ] && [ -f "$ZIPFILE" ]; then
        if type unzip >/dev/null 2>&1; then
            unzip -o "$ZIPFILE" 'bin/*' -d "$MODPATH" >/dev/null 2>&1
        elif [ -x "$MODPATH/bin/busybox/busybox" ]; then
            "$MODPATH/bin/busybox/busybox" unzip -o "$ZIPFILE" 'bin/*' -d "$MODPATH" >/dev/null 2>&1
        fi
        [ -s "$ENGINE" ] && note "安装包解包不完整，已从 zip 重新解出 bin/"
    fi
    return 0
}

ui_print "* 南何ovo ${VERSION} · 性能调度与频率面板"
ui_print "* 引擎来源：Uperf-Game-Turbo（Apache-2.0）"
ui_print "* 请勿同时安装其它 uperf 类模块，也不要自行切换 CPU 调速器"
ui_print ""

# --- 架构检查：本模块内置的 uperf 为 aarch64 可执行文件 ---
ABI="$(getprop ro.product.cpu.abi 2>/dev/null)"
case "$ABI" in
    arm64*) note "架构 ${ABI}，符合要求" ;;
    *) abort "! 需要 arm64-v8a 设备，当前为 [${ABI}]" ;;
esac

# --- 冲突提示（只提示，不删除任何其它模块）---
for other in /data/adb/modules/uperf /data/adb/modules_update/uperf; do
    [ -d "$other" ] && ui_print "! 检测到已安装的 uperf 模块：${other}，两者会同时改写频率与调度"
done

# --- 平台配置选择 ---
ensure_engine
fix_perms

. "$MODPATH/script/pathinfo.sh"
. "$MODPATH/script/libsysinfo.sh"

PLATFORM="$(getprop ro.board.platform 2>/dev/null)"
BOARD="$(getprop ro.product.board 2>/dev/null)"
CFGNAME="$(get_config_name "$PLATFORM")"
if [ "$CFGNAME" = unsupported ]; then
    CFGNAME="$(get_config_name "$BOARD")"
fi

note "ro.board.platform=[${PLATFORM}] ro.product.board=[${BOARD}]"
note "匹配配置名=[${CFGNAME}]"

if [ "$CFGNAME" != unsupported ] && [ -f "$MODPATH/config/${CFGNAME}.json" ]; then
    SRC="$MODPATH/config/${CFGNAME}.json"
    note "使用平台配置 ${CFGNAME}.json"
else
    SRC="$MODPATH/config/template.json"
    CFGNAME=template
    [ -f "$SRC" ] || abort "! 模块内缺少 template.json，安装包不完整"
    note "未匹配到平台配置，改用通用模板 template.json（频率档位可能与本机不完全一致；该模板不含功耗模型，uperf 不会接管 CPU 频率）"
fi

if [ ! -f "$MODPATH/bin/uperf" ]; then
    note "bin 目录内容：$(ls -l "$MODPATH/bin" 2>/dev/null | tr '\n' ' ')"
    abort "! 模块内缺少 bin/uperf，安装包不完整（请用完整 zip 重刷）"
fi
[ -s "$MODPATH/bin/uperf" ] || abort "! bin/uperf 为空文件，安装包已损坏"
chmod 0755 "$MODPATH/bin/uperf" 2>/dev/null
[ -x "$MODPATH/bin/uperf" ] || abort "! bin/uperf 无法执行：chmod 0755 失败，请确认 /data 分区可写"

if [ ! -f "$MODPATH/bin/busybox/busybox" ]; then
    abort "! 模块内缺少 bin/busybox/busybox，安装包不完整"
fi
[ -s "$MODPATH/bin/busybox/busybox" ] || abort "! bin/busybox/busybox 为空文件，安装包已损坏"
chmod 0755 "$MODPATH/bin/busybox/busybox" 2>/dev/null
[ -x "$MODPATH/bin/busybox/busybox" ] || abort "! busybox 无法执行：chmod 0755 失败"

[ -f "$MODPATH/script/control.sh" ] || abort "! 模块内缺少 WebUI 后端 script/control.sh"
[ -f "$MODPATH/webroot/index.html" ] || abort "! 模块内缺少 WebUI 页面，安装包不完整"

# --- 写入用户目录（保留既有分应用规则）---
mkdir -p "$USER_PATH" || abort "! 无法创建 ${USER_PATH}（存储未挂载或权限不足）"
if [ -f "$USER_PATH/uperf.json" ]; then
    cp -f "$USER_PATH/uperf.json" "$USER_PATH/uperf.json.bak" && note "已备份旧 uperf.json"
fi
cp -f "$SRC" "$USER_PATH/uperf.json" || abort "! 写入 ${USER_PATH}/uperf.json 失败"
if [ ! -f "$USER_PATH/perapp_powermode.txt" ]; then
    cp -f "$MODPATH/config/perapp_powermode.txt" "$USER_PATH/perapp_powermode.txt" || abort "! 写入分应用规则失败"
fi
if [ ! -f "$USER_PATH/cur_powermode.txt" ]; then
    printf '%s\n' balance >"$USER_PATH/cur_powermode.txt" || abort "! 写入默认模式失败"
fi
chmod 0644 "$USER_PATH/uperf.json" "$USER_PATH/perapp_powermode.txt" 2>/dev/null
[ -f "$USER_PATH/cur_powermode.txt" ] && chmod 0644 "$USER_PATH/cur_powermode.txt" 2>/dev/null
note "配置已写入 ${USER_PATH}"

# --- WebUI 后端运行时目录 ---
mkdir -p /data/adb/nanhe_ovo || abort "! 无法创建 /data/adb/nanhe_ovo"
chmod 0700 /data/adb/nanhe_ovo 2>/dev/null
printf '%s\n' "$CFGNAME" >/data/adb/nanhe_ovo/device_config.txt
chmod 0600 /data/adb/nanhe_ovo/device_config.txt 2>/dev/null
# 回退模板时把原因写进运行日志：模板没有 CPU 功耗模型，uperf 不接管频率，
# 系统 DVFS 会按自己的策略频繁升降频（真机上表现为「模块在降频」）。
if [ "$CFGNAME" = template ]; then
    LOGF=/data/adb/nanhe_ovo/log.txt
    if [ ! -L "$LOGF" ]; then
        printf '%s\t%s\t%s\t%s\n' "$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)" warn config \
            "未匹配到平台配置（platform=${PLATFORM:-?} board=${BOARD:-?}），已回退 template.json；该模板不含 CPU 功耗模型，uperf 不会接管频率，系统 DVFS 可能频繁升降频" \
            >>"$LOGF" 2>/dev/null
    fi
fi

# --- SELinux 上下文（权限已由 fix_perms 统一处理）---
if type chcon >/dev/null 2>&1; then
    find "$MODPATH/bin" "$MODPATH/script" -type f 2>/dev/null | while read -r f; do
        chcon u:object_r:system_file:s0 "$f" 2>/dev/null
    done
fi

# 平台配置只需要一份，安装后从模块目录移除，减少只读分区占用。
rm -rf "$MODPATH/config"

ui_print ""
ui_print "* 安装完成，重启后引擎自动启动"
ui_print "* 打开 WebUI：KernelSU / APatch 管理器 → 模块 → 南何ovo → 打开 WebUI"
ui_print "* Magisk 本体没有模块 WebUI，可用 KsuWebUIStandalone 等工具打开同一页面"
ui_print "* 便携控制：sh /data/powercfg.sh balance"
ui_print "* 分应用规则：/sdcard/Android/yc/uperf/perapp_powermode.txt"
ui_print "* 首次重启后请先打开 WebUI 确认模式列表与频率节点"
