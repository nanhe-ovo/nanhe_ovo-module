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
    for f in "$MODPATH"/bin/busybox/* "$MODPATH"/bin/appopt/*; do
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

ui_print "* 南何ovo ${VERSION} · 性能调度与频率面板"
ui_print "* CPU 策略：自研 cpu_policy.sh（表驱动，不再内置 uperf 二进制）"
ui_print "* 配置数据来源：Uperf-Game-Turbo 功耗模型（Apache-2.0，仅作为 JSON 配置源）"
ui_print "* 线程引擎：AppOptR（SutoLiu，GPL-3.0，gitee.com/sutoliu/AppOptR）"
ui_print "* 请勿同时安装其它会改写 CPU 频率的模块，也不要自行切换 CPU 调速器"
ui_print ""

# --- 架构检查：busybox 与 AppOptR 二进制为 aarch64 ---
ABI="$(getprop ro.product.cpu.abi 2>/dev/null)"
case "$ABI" in
    arm64*) note "架构 ${ABI}，符合要求" ;;
    *) abort "! 需要 arm64-v8a 设备，当前为 [${ABI}]" ;;
esac

# --- 冲突提示（只提示，不删除任何其它模块）---
for other in /data/adb/modules/uperf /data/adb/modules_update/uperf; do
    [ -d "$other" ] && ui_print "! 检测到已安装的 uperf 模块：${other}；本模块不再启动 uperf，但双方仍可能同时改写频率"
done

# --- 平台配置选择 ---
fix_perms

. "$MODPATH/script/pathinfo.sh"
. "$MODPATH/script/libsysinfo.sh"

PLATFORM="$(getprop ro.board.platform 2>/dev/null)"
BOARD="$(getprop ro.product.board 2>/dev/null)"
SOCMODEL="$(getprop ro.soc.model 2>/dev/null)"
CFGNAME="$(get_config_name "$PLATFORM")"
if [ "$CFGNAME" = unsupported ]; then
    CFGNAME="$(get_config_name "$BOARD")"
fi
if [ "$CFGNAME" = unsupported ] && [ -n "$SOCMODEL" ]; then
    # 第三路：平台属性缺失或被伪装时，用 SoC 型号精确映射（SM8250-AC / MT6995 等）
    CFGNAME="$(get_config_name_by_model "$SOCMODEL")"
fi
CFG_SRC=prop

note "ro.board.platform=[${PLATFORM}] ro.product.board=[${BOARD}] ro.soc.model=[${SOCMODEL}]"

# 拓扑校验：改机型 prop（伪装机型）后属性会指向别的平台配置，频率表与功耗模型
# 都对不上，表现为「调度不生效 / 一直降频」。这里用真实核数与最高频复核，
# 不符时按拓扑指纹在本机所有配置里挑最接近的一份，而不是直接退 template。
if [ "$CFGNAME" = unsupported ]; then
    TCFG="$(topo_pick_config "$MODPATH/config")"
    if [ -n "$TCFG" ]; then
        note "属性未匹配（platform=${PLATFORM} board=${BOARD}），按拓扑指纹选用 ${TCFG}"
        CFGNAME="$TCFG"
        CFG_SRC=topo
    fi
elif [ -f "$MODPATH/config/${CFGNAME}.json" ]; then
    if ! topo_config_ok "$CFGNAME" "$MODPATH/config"; then
        TCFG="$(topo_pick_config "$MODPATH/config")"
        if [ -n "$TCFG" ] && [ "$TCFG" != "$CFGNAME" ]; then
            note "属性配置 ${CFGNAME}.json 与本机拓扑不符（核数 $(topo_nr_core)，最高频 $(topo_max_freq)kHz），按拓扑指纹改用 ${TCFG}"
            CFGNAME="$TCFG"
            CFG_SRC=topo
        else
            note "属性配置 ${CFGNAME}.json 与本机拓扑不符，且没有同核数候选，仍沿用属性结果"
        fi
    fi
else
    note "属性映射到 ${CFGNAME}，但模块内没有该配置，按原逻辑回落到模板"
fi

note "匹配配置名=[${CFGNAME}]（来源：${CFG_SRC}）"

if [ "$CFGNAME" != unsupported ] && [ -f "$MODPATH/config/${CFGNAME}.json" ]; then
    SRC="$MODPATH/config/${CFGNAME}.json"
    note "使用平台配置 ${CFGNAME}.json"
else
    SRC="$MODPATH/config/template.json"
    CFGNAME=template
    [ -f "$SRC" ] || abort "! 模块内缺少 template.json，安装包不完整"
    note "未匹配到平台配置，改用通用模板 template.json（该模板不含功耗模型，cpu_policy 会用硬件峰值的温和比例兜底）"
fi

if [ ! -s "$MODPATH/cpu_profiles.tsv" ]; then
    abort "! 模块内缺少 cpu_profiles.tsv，安装包不完整（请用完整 zip 重刷）"
fi
[ -s "$MODPATH/script/cpu_policy.sh" ] || abort "! 模块内缺少 script/cpu_policy.sh，安装包不完整"

if [ ! -f "$MODPATH/bin/busybox/busybox" ]; then
    abort "! 模块内缺少 bin/busybox/busybox，安装包不完整"
fi
[ -s "$MODPATH/bin/busybox/busybox" ] || abort "! bin/busybox/busybox 为空文件，安装包已损坏"
chmod 0755 "$MODPATH/bin/busybox/busybox" 2>/dev/null
[ -x "$MODPATH/bin/busybox/busybox" ] || abort "! busybox 无法执行：chmod 0755 失败"

# --- 线程引擎（AppOptR，GPL-3.0）---
if [ ! -s "$MODPATH/bin/appopt/AppOpt" ]; then
    abort "! 模块内缺少线程引擎 bin/appopt/AppOpt，安装包不完整（请用完整 zip 重刷）"
fi
chmod 0755 "$MODPATH/bin/appopt/AppOpt" "$MODPATH/bin/appopt/AppOpt-ebpf" 2>/dev/null
"$MODPATH/bin/appopt/AppOpt" -v >/dev/null 2>&1 || abort "! 线程引擎 AppOpt 无法执行（二进制损坏或与本机不兼容）"

[ -f "$MODPATH/script/control.sh" ] || abort "! 模块内缺少 WebUI 后端 script/control.sh"
[ -f "$MODPATH/webroot/index.html" ] || abort "! 模块内缺少 WebUI 页面，安装包不完整"

# --- 写入用户目录（保留既有分应用规则）---
mkdir -p "$USER_PATH" || abort "! 无法创建 ${USER_PATH}（存储未挂载或权限不足）"
if [ -f "$USER_PATH/uperf.json" ]; then
    cp -f "$USER_PATH/uperf.json" "$USER_PATH/uperf.json.bak" && note "已备份旧配置 uperf.json"
fi
cp -f "$SRC" "$USER_PATH/uperf.json" || abort "! 写入 ${USER_PATH}/uperf.json 失败"

# 分应用规则迁移：旧模板是 14 款 performance + "* performance"，
# 新模板是 48 款 fast + 三角洲 crazy + "- powersave" + "* balance"。
# 直接按“文件存在就跳过”会让升级用户继续落到旧默认规则，三角洲尤其明显。
merge_perapp() {
    OLD_RULES="$USER_PATH/perapp_powermode.txt"
    NEW_RULES="$MODPATH/config/perapp_powermode.txt"
    [ -f "$OLD_RULES" ] && [ ! -L "$OLD_RULES" ] || return 0
    [ -f "$NEW_RULES" ] || return 0
    # 已经是新模板（含三角洲 crazy 且默认 balance）就不动用户文件
    if grep -q '^com\.tencent\.tmgp\.dfm[[:space:]]\+crazy' "$OLD_RULES" 2>/dev/null &&
       grep -q '^[[:space:]]*\*[[:space:]]*balance' "$OLD_RULES" 2>/dev/null; then
        return 0
    fi
    cp -f "$OLD_RULES" "$OLD_RULES.bak" 2>/dev/null || :
    awk -F ' ' '
        FNR == NR {
            if ($0 ~ /^#/ || NF == 0) next
            if ($1 == "*" || $1 == "-") { print; next }
            known[$1] = 1
            print
            next
        }
        {
            if ($0 ~ /^#/ || NF == 0) next
            if ($1 == "*" || $1 == "-") next
            if ($1 in known) next
            print
        }
    ' "$NEW_RULES" "$OLD_RULES" > "$USER_PATH/.perapp.merge" || return 0
    mv -f "$USER_PATH/.perapp.merge" "$OLD_RULES" 2>/dev/null || :
    chmod 0644 "$OLD_RULES" 2>/dev/null || :
    note "已迁移旧版分应用规则（保留自定义包，默认规则更新为 fast/crazy/balance）"
}
merge_perapp
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
printf '%s\n' "$CFG_SRC" >/data/adb/nanhe_ovo/config_source.txt
chmod 0600 /data/adb/nanhe_ovo/device_config.txt /data/adb/nanhe_ovo/config_source.txt 2>/dev/null
# 回退模板时写日志：模板没有功耗模型，cpu_policy 只用通用上限兜底。
if [ "$CFGNAME" = template ]; then
    LOGF=/data/adb/nanhe_ovo/log.txt
    if [ ! -L "$LOGF" ]; then
        printf '%s\t%s\t%s\t%s\n' "$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)" warn config \
            "未匹配到平台配置（platform=${PLATFORM:-?} board=${BOARD:-?}），已回退 template.json；该模板不含 CPU 功耗模型，cpu_policy 将使用硬件峰值的温和比例" \
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
ui_print "* 安装完成，重启后 CPU 策略自动应用"
ui_print "* 打开 WebUI：KernelSU / APatch 管理器 → 模块 → 南何ovo → 打开 WebUI"
ui_print "* Magisk 本体没有模块 WebUI，可用 KsuWebUIStandalone 等工具打开同一页面"
ui_print "* 便携控制：sh /data/powercfg.sh balance"
ui_print "* 分应用规则：/sdcard/Android/yc/uperf/perapp_powermode.txt"
ui_print "* 线程调度跟随首页模式切换，应用页可为单个应用绑定线程预设"
ui_print "* 首次重启后请先打开 WebUI 确认模式列表与频率节点"
