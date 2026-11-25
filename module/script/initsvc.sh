#!/system/bin/sh
# 引擎启动流程（启动骨架源自 Uperf-Game-Turbo，Apache-2.0；v1.11.0 起不再启动 uperf 进程）。
#
# 与上游的差别：
#   1. /data/powercfg.sh 只在缺失或属于本模块时写入，避免覆盖其它模块的同名入口；
#   2. 系统级调优（powercfg_once / platform_special / miui_migt）可由 WebUI 的
#      「系统调优」开关关闭，关闭后只应用自研 CPU 策略；
#   3. CPU 策略由 script/cpu_policy.sh 读取 cpu_profiles.tsv 表驱动，不依赖 uperf。

BASEDIR="$(dirname "$(readlink -f "$0")")"
. "$BASEDIR/pathinfo.sh"
. "$BASEDIR/libcommon.sh"

# 部分管理器解包时不会还原可执行位，运行前统一修复一次
chmod 0755 "$BIN_PATH/busybox/busybox" 2>/dev/null

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
    echo "- 系统调优已关闭（WebUI 开关），仅应用自研 CPU 策略"
else
    sh "$SCRIPT_PATH/powercfg_once.sh"
    sh "$SCRIPT_PATH/platform_special.sh"
    sh "$SCRIPT_PATH/miui_migt.sh"
fi

# 先让 control.sh 记录本次开机的原始频率边界，再让 cpu_policy 写上限；
# 否则 WebUI 的「恢复默认」会把策略上限误当成开机基线。
[ -f "$SCRIPT_PATH/control.sh" ] && sh "$SCRIPT_PATH/control.sh" status >/dev/null 2>&1 || :

# MTK Mali / 骁龙 kgsl 按当前模式设置真实 OPP 表内的 GPU 窗口。
GP_MODE=$(cat "$USER_PATH/cur_powermode.txt" 2>/dev/null)
case "$GP_MODE" in powersave|balance|performance|fast|crazy) ;; *) GP_MODE=balance;; esac
sh "$SCRIPT_PATH/cpu_policy.sh" apply "$GP_MODE" >/dev/null 2>&1 ||
    echo "- CPU 策略应用失败：$GP_MODE（详见 /data/adb/nanhe_ovo/cpu_policy.log）"
sh "$SCRIPT_PATH/ddr_profile.sh" "$GP_MODE"
sh "$SCRIPT_PATH/gpu_profile.sh" "$GP_MODE"
