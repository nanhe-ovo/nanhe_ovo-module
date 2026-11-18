#!/system/bin/sh
# 引擎启动流程（基于 Uperf-Game-Turbo 的 initsvc.sh，Apache-2.0）。
#
# 与上游的差别：
#   1. /data/powercfg.sh 只在缺失或属于本模块时写入，避免覆盖其它模块的同名入口；
#   2. 系统级调优（powercfg_once / platform_special / miui_migt）可由 WebUI 的
#      「系统调优」开关关闭，关闭后只启动 uperf 引擎本身。

BASEDIR="$(dirname "$(readlink -f "$0")")"
. "$BASEDIR/pathinfo.sh"
. "$BASEDIR/libcommon.sh"
. "$BASEDIR/libuperf.sh"

# 部分管理器解包时不会还原可执行位，运行前统一修复一次
chmod 0755 "$BIN_PATH/busybox/busybox" "$BIN_PATH/uperf" 2>/dev/null

# 安装 busybox 的 applet 软链
"$BIN_PATH/busybox/busybox" --install -s "$BIN_PATH/busybox" 2>/dev/null

# 便携入口：供 Scene / 终端 / 其它面板调用
write_entry() {
    _target="$1"
    if [ -e "$_target" ] && ! grep -q 'nanhe_ovo' "$_target" 2>/dev/null; then
        echo "- $_target 已被其它模块占用，跳过写入"
        return 0
    fi
    cat >"$_target" <<EOF
#!/system/bin/sh
# nanhe_ovo portable entry
exec sh $SCRIPT_PATH/powercfg_main.sh "\$1"
EOF
    chmod 0755 "$_target"
}
write_entry /data/powercfg.sh
write_entry /data/powercfg-base.sh
cp -af "$SCRIPT_PATH/powercfg.json" /data/powercfg.json 2>/dev/null

wait_until_login

if [ -f /data/adb/nanhe_ovo/tune_disabled ]; then
    echo "- 系统调优已关闭（WebUI 开关），仅启动 uperf 引擎"
else
    sh "$SCRIPT_PATH/powercfg_once.sh"
    sh "$SCRIPT_PATH/platform_special.sh"
    sh "$SCRIPT_PATH/miui_migt.sh"
fi

uperf_start

# MTK Mali 按当前模式设置真实 OPP 表内的 GPU 下限与降频迟滞。
GP_MODE=$(cat "$USER_PATH/cur_powermode.txt" 2>/dev/null)
sh "$SCRIPT_PATH/gpu_profile.sh" "$GP_MODE"
