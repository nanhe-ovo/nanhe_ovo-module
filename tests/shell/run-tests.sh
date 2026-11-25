#!/usr/bin/env bash
# 南何ovo · 后端与安装器的 POSIX 验证。
# 说明：本脚本在 Linux/macOS 上运行 module/ 内的脚本，用 PATH 兜底桩替换
# Android 专有命令（getprop / id / stat / pm / pidof），并把固定的绝对路径
# 替换到一个临时根目录（$FAKE）。替换后的副本与出厂脚本只差路径前缀。
set -u

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
MODULE="$ROOT/module"
WORK=$(mktemp -d)
SH=$(command -v dash 2>/dev/null || command -v sh)
REAL_STAT=$(command -v stat)
REAL_TAIL=$(command -v tail)
REAL_ID=$(command -v id)
HOST_PATH="$PATH"
F=0

ok()   { printf 'PASS %s\n' "$1"; }
bad()  { printf 'FAIL %s\n' "$1"; F=1; }
skip() { printf 'SKIP %s\n' "$1"; }
eq()   { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1（期望 [$2]，实际 [$3]）"; fi; }
has()  { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1（输出未包含 [$3]，实际 [$2]）" ;; esac; }
hasnt(){ case "$2" in *"$3"*) bad "$1（输出意外包含 [$3]）" ;; *) ok "$1" ;; esac; }

cleanup_all() { rm -rf "$WORK"; }
# KEEP_WORK=1 保留临时目录便于排查
if [ "${KEEP_WORK:-0}" = 1 ]; then trap - 0; else trap cleanup_all 0; fi

########################################
# 1. 语法检查
########################################
printf '\n== 语法检查（%s）==\n' "$SH"
SYNTAX_FAIL=0
while IFS= read -r f; do
    if ! "$SH" -n "$f" 2>"$WORK/syntax.err"; then
        bad "语法 ${f#$ROOT/}：$(cat "$WORK/syntax.err")"; SYNTAX_FAIL=1
    fi
done < <(find "$MODULE" -name '*.sh' -o -name 'customize.sh' -o -name 'service.sh' -o -name 'post-fs-data.sh' -o -name 'uninstall.sh' | sort)
[ "$SYNTAX_FAIL" = 0 ] && ok "全部 shell 脚本语法通过"

for f in customize.sh service.sh post-fs-data.sh uninstall.sh bin/busybox/busybox script/control.sh script/initsvc.sh script/cpu_policy.sh; do
    [ -x "$MODULE/$f" ] || bad "缺少可执行位：$f"
done
ok "模块内脚本与二进制具备可执行位"

########################################
# 2. 构造假的 sysfs / sdcard / Android 命令
########################################
FAKE="$WORK/fake"
make_fixture() {
    D=$1
    rm -rf "$D"; mkdir -p "$D"
    # CPU 策略 0
    mkdir -p "$D/sys/devices/system/cpu/cpufreq/policy0"
    printf '%s\n' 300000 > "$D/sys/devices/system/cpu/cpufreq/policy0/scaling_min_freq"
    printf '%s\n' 1800000 > "$D/sys/devices/system/cpu/cpufreq/policy0/scaling_max_freq"
    printf '%s\n' 1200000 > "$D/sys/devices/system/cpu/cpufreq/policy0/scaling_cur_freq"
    printf '%s\n' "300000 600000 1200000 1800000" > "$D/sys/devices/system/cpu/cpufreq/policy0/scaling_available_frequencies"
    # CPU 策略 4
    mkdir -p "$D/sys/devices/system/cpu/cpufreq/policy4"
    printf '%s\n' 710400 > "$D/sys/devices/system/cpu/cpufreq/policy4/scaling_min_freq"
    printf '%s\n' 2803200 > "$D/sys/devices/system/cpu/cpufreq/policy4/scaling_max_freq"
    printf '%s\n' 1800000 > "$D/sys/devices/system/cpu/cpufreq/policy4/scaling_cur_freq"
    printf '%s\n' "710400 1200000 1800000 2400000 2803200" > "$D/sys/devices/system/cpu/cpufreq/policy4/scaling_available_frequencies"
    # GPU（kgsl 风格）
    mkdir -p "$D/sys/devices/platform/kgsl-3d0/devfreq"
    printf '%s\n' 220000000 > "$D/sys/devices/platform/kgsl-3d0/devfreq/min_freq"
    printf '%s\n' 903000000 > "$D/sys/devices/platform/kgsl-3d0/devfreq/max_freq"
    printf '%s\n' 578000000 > "$D/sys/devices/platform/kgsl-3d0/devfreq/cur_freq"
    printf '%s\n' "220000000 525000000 578000000 903000000" > "$D/sys/devices/platform/kgsl-3d0/devfreq/available_frequencies"
    mkdir -p "$D/sys/class/devfreq"
    ln -s ../../devices/platform/kgsl-3d0/devfreq "$D/sys/class/devfreq/kgsl-3d0"
    # 非 GPU devfreq：必须被过滤掉
    mkdir -p "$D/sys/devices/platform/soc/sramc/devfreq"
    printf '%s\n' 100000000 > "$D/sys/devices/platform/soc/sramc/devfreq/min_freq"
    printf '%s\n' 200000000 > "$D/sys/devices/platform/soc/sramc/devfreq/max_freq"
    printf '%s\n' "100000000 200000000" > "$D/sys/devices/platform/soc/sramc/devfreq/available_frequencies"
    # GPU 但没有频率表：必须拒绝写入（真实设备同样通过 class 目录暴露）
    # 目录名排在 kgsl 之后，保证 gpu-0 是有频率表的那一个
    mkdir -p "$D/sys/devices/platform/vendor-gpu/devfreq"
    printf '%s\n' 300000000 > "$D/sys/devices/platform/vendor-gpu/devfreq/min_freq"
    printf '%s\n' 600000000 > "$D/sys/devices/platform/vendor-gpu/devfreq/max_freq"
    ln -s ../../devices/platform/vendor-gpu/devfreq "$D/sys/class/devfreq/vendor-gpu"
    # 用户目录
    mkdir -p "$D/sdcard/Android/yc/uperf"
    cp "$MODULE/config/sdm8g2.json" "$D/sdcard/Android/yc/uperf/uperf.json"
    cp "$MODULE/config/perapp_powermode.txt" "$D/sdcard/Android/yc/uperf/perapp_powermode.txt"
    printf '%s\n' balance > "$D/sdcard/Android/yc/uperf/cur_powermode.txt"
    # 模块目录（提供 module.prop 版本与游戏名单）
    mkdir -p "$D/data/adb/modules/nanhe_ovo"
    cp "$MODULE/module.prop" "$D/data/adb/modules/nanhe_ovo/module.prop"
    cp "$MODULE/game.list" "$D/data/adb/modules/nanhe_ovo/game.list"
    cp "$MODULE/cpu_profiles.tsv" "$D/data/adb/modules/nanhe_ovo/cpu_profiles.tsv"
    mkdir -p "$D/data/adb/modules/nanhe_ovo/script"
    sed -e "s#/data/adb/modules/nanhe_ovo#$D/data/adb/modules/nanhe_ovo#g" \
        -e "s#/data/adb/nanhe_ovo#$D/data/adb/nanhe_ovo#g" \
        -e "s#/sdcard#$D/sdcard#g" \
        -e "s#/sys/#$D/sys/#g" \
        "$MODULE/script/cpu_policy.sh" > "$D/data/adb/modules/nanhe_ovo/script/cpu_policy.sh"
    mkdir -p "$D/data/adb/modules/nanhe_ovo/config"
    cp "$MODULE/thread_skip.list" "$D/data/adb/modules/nanhe_ovo/thread_skip.list"
    # 运行时
    mkdir -p "$D/data/adb/nanhe_ovo"
    printf '%s\n' sdm8g2 > "$D/data/adb/nanhe_ovo/device_config.txt"
    printf '%s\n' aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee > "$D/boot_id"
    # 系统包清单（apps 的兜底枚举来源）
    mkdir -p "$D/data/system"
    printf '%s\n' "com.example.camera 10234 0 /data/user/0/com.example.camera default:targetSdkVersion=33" \
        "com.example.game 10235 0 /data/user/0/com.example.game default:targetSdkVersion=33" \
        > "$D/data/system/packages.list"
    # Android 命令桩
    mkdir -p "$D/bin"
    printf '#!/bin/sh\necho 0\n' > "$D/bin/id"
    printf '#!/bin/sh\nif [ "$1" = "-c" ] && [ "$2" = "%%u" ]; then echo 0; exit 0; fi\nexec %s "$@"\n' "$REAL_STAT" > "$D/bin/stat"
    printf '#!/bin/sh\nif [ "$1" = AppOpt ]; then\n if [ -f "%s/appopt.running" ]; then echo 7777; exit 0; fi\n exit 1\nfi\nif [ -f "%s/uperf.running" ]; then echo 4242; exit 0; fi\nexit 1\n' "$D" "$D" > "$D/bin/pidof"
    printf '#!/bin/sh\nprintf "package:com.android.settings\\npackage:com.tencent.tmgp.sgame\\npackage:com.example.game\\njunk\\npackage:\\npackage:com.example.reader\\n"\n' > "$D/bin/pm"
    # 屏幕 / 机型信息相关的系统命令桩
    printf '#!/bin/sh\n[ -f "%s/dumpsys_silent" ] && exit 0\n[ -f "%s/dumpsys_variant" ] && { cat "%s/dumpsys_variant"; exit 0; }\ncase "$1" in\n display) printf "DisplayDeviceInfo{name=Built-in, supportedModes [{id=1, width=1880, height=3008, fps=60.000004}, {id=2, width=1880, height=3008, fps=120.0}, {id=3, width=1880, height=3008, fps=144.0}, {id=4, fps=480.0}]}\\n" ;;\n SurfaceFlinger) printf "Display 0: refresh-rate: 120.000000 Hz\\n" ;;\n battery) printf "Current Battery Service state:\\n  level: 82\\n  temperature: 350\\n  health: 2\\n  status: 2\\n  technology: Li-poly\\n" ;;\nesac\n' "$D" "$D" "$D" > "$D/bin/dumpsys"
    printf '#!/bin/sh\nS="%s/settings_store"\n[ -f "$S" ] || : > "$S"\ncase "$1" in\n get) v=$(awk -F= -v k="$3" '"'"'$1==k{v=$2} END{print v}'"'"' "$S"); if [ -n "$v" ]; then printf "%%s\\n" "$v"; else printf "null\\n"; fi ;;\n put) printf "%%s=%%s\\n" "$3" "$4" >> "$S" ;;\n delete) awk -F= -v k="$3" '"'"'$1!=k'"'"' "$S" > "$S.tmp"; mv "$S.tmp" "$S" ;;\nesac\n' "$D" > "$D/bin/settings"
    printf '#!/bin/sh\ncase "$1" in\n size) echo "Physical size: 1880x3008" ;;\n density) echo "Physical density: 450" ;;\nesac\n' > "$D/bin/wm"
    printf '#!/bin/sh\ncase "$1" in\n ro.product.brand) echo REDMI ;;\n ro.product.model) echo 25079RPDCC ;;\n ro.product.manufacturer) echo Xiaomi ;;\n ro.product.device) echo turner ;;\n ro.build.fingerprint) echo "Redmi/turner/turner:17/CP2A.260605.016/OS4.0.3.0:user/release-keys" ;;\n ro.build.version.release) echo 17 ;;\n ro.build.version.sdk) echo 37 ;;\n ro.build.version.security_patch) echo 2026-10-01 ;;\n ro.boot.slot_suffix) echo _a ;;\n ro.build.id) echo CP2A.260605.016 ;;\n ro.product.cpu.abi) echo arm64-v8a ;;\n ro.product.cpu.abilist) echo "arm64-v8a,armeabi-v7a,armeabi" ;;\n ro.hardware) echo mt8799 ;;\n ro.product.board) echo turner ;;\n sys.boot_completed) echo 1 ;;\n *) echo "" ;;\nesac\n' > "$D/bin/getprop"
    printf '#!/bin/sh\necho 6.6.118-android15-test\n' > "$D/bin/uname"
    printf '#!/bin/sh\necho Enforcing\n' > "$D/bin/getenforce"
    printf '#!/bin/sh\nexit 0\n' > "$D/bin/sleep"
    # 机型信息读取的 sysfs 夹具
    mkdir -p "$D/sys/devices/system/cpu"
    printf '0-7\n' > "$D/sys/devices/system/cpu/possible"
    mkdir -p "$D/sys/class/thermal/thermal_zone0"
    printf 'cpu-0\n' > "$D/sys/class/thermal/thermal_zone0/type"
    printf '61500\n' > "$D/sys/class/thermal/thermal_zone0/temp"
    chmod +x "$D/bin/"*
    # 脚本副本：只替换固定路径前缀；后端内部会重置 PATH，这里把桩目录加进去
    sed -e "s#/data/system/packages.list#$D/data/system/packages.list#g" \
        -e "s#/data/adb/modules/nanhe_ovo#$D/data/adb/modules/nanhe_ovo#g" \
        -e "s#/data/adb/nanhe_ovo#$D/data/adb/nanhe_ovo#g" \
        -e "s#/sdcard#$D/sdcard#g" \
        -e "s#/proc/sys/kernel/random/boot_id#$D/boot_id#g" \
        -e "s#/sys/#$D/sys/#g" \
        -e "s#^PATH=/system/bin:/system/xbin#PATH=$D/bin:$HOST_PATH#" \
        "$MODULE/script/control.sh" > "$D/control.sh"
    chmod +x "$D/control.sh"
    # 开机刷新率与 MTK GPU 分模式脚本副本：只替换固定路径前缀
    sed -e "s#/data/adb/nanhe_ovo#$D/data/adb/nanhe_ovo#g" \
        "$MODULE/script/refresh_apply.sh" > "$D/refresh_apply.sh"
    chmod +x "$D/refresh_apply.sh"
    mkdir -p "$D/data/adb/modules/nanhe_ovo/script"
    sed -e "s#/data/adb/nanhe_ovo#$D/data/adb/nanhe_ovo#g" \
        -e "s#/proc/sys/kernel/random/boot_id#$D/boot_id#g" \
        -e "s#/sys/#$D/sys/#g" \
        "$MODULE/script/gpu_profile.sh" > "$D/data/adb/modules/nanhe_ovo/script/gpu_profile.sh"
    chmod +x "$D/data/adb/modules/nanhe_ovo/script/gpu_profile.sh"
    # 线程引擎封装库与开机服务副本：与后端同套路径替换
    sed -e "s#/data/adb/modules/nanhe_ovo#$D/data/adb/modules/nanhe_ovo#g" \
        -e "s#/data/adb/nanhe_ovo#$D/data/adb/nanhe_ovo#g" \
        -e "s#/sdcard#$D/sdcard#g" \
        -e "s#/sys/#$D/sys/#g" \
        "$MODULE/script/libthread.sh" > "$D/data/adb/modules/nanhe_ovo/script/libthread.sh"
    sed -e "s#/data/adb/modules/nanhe_ovo#$D/data/adb/modules/nanhe_ovo#g" \
        -e "s#/data/adb/nanhe_ovo#$D/data/adb/nanhe_ovo#g" \
        -e "s#/sys/#$D/sys/#g" \
        "$MODULE/script/libtopo.sh" > "$D/data/adb/modules/nanhe_ovo/script/libtopo.sh"
    sed -e "s#/data/adb/modules/nanhe_ovo#$D/data/adb/modules/nanhe_ovo#g" \
        -e "s#/data/adb/nanhe_ovo#$D/data/adb/nanhe_ovo#g" \
        -e "s#/sdcard#$D/sdcard#g" \
        -e "s#/sys/#$D/sys/#g" \
        "$MODULE/script/thread_svc.sh" > "$D/data/adb/modules/nanhe_ovo/script/thread_svc.sh"
    chmod +x "$D/data/adb/modules/nanhe_ovo/script/libthread.sh" "$D/data/adb/modules/nanhe_ovo/script/libtopo.sh" "$D/data/adb/modules/nanhe_ovo/script/thread_svc.sh"
    # 五档线程规则与许可证
    mkdir -p "$D/data/adb/modules/nanhe_ovo/appopt"
    cp "$MODULE"/appopt/appopt_*.conf "$D/data/adb/modules/nanhe_ovo/appopt/" 2>/dev/null
    cp "$MODULE/appopt/LICENSE-GPL3.txt" "$D/data/adb/modules/nanhe_ovo/appopt/" 2>/dev/null
    # AppOpt 桩：记录调用参数后退出（真机二进制不能在宿主机上执行）
    mkdir -p "$D/data/adb/modules/nanhe_ovo/bin/appopt"
    printf '#!/bin/sh\necho "$@" > "%s/appopt.invoked"\nexit 0\n' "$D" > "$D/data/adb/modules/nanhe_ovo/bin/appopt/AppOpt"
    cp "$D/data/adb/modules/nanhe_ovo/bin/appopt/AppOpt" "$D/data/adb/modules/nanhe_ovo/bin/appopt/AppOpt-ebpf"
    chmod +x "$D/data/adb/modules/nanhe_ovo/bin/appopt/"*
    # crazy 档保核夹具：cpu0 簇 min=4 / max=6
    mkdir -p "$D/sys/devices/system/cpu/cpu0/core_ctl"
    printf '%s\n' 4 > "$D/sys/devices/system/cpu/cpu0/core_ctl/min_cpus"
    printf '%s\n' 6 > "$D/sys/devices/system/cpu/cpu0/core_ctl/max_cpus"
    # CPU 拓扑夹具：4+4 双簇（0-3 @1.8GHz / 4-7 @2.8GHz），验证语义核展开成数字掩码
    mkdir -p "$D/sys/devices/system/cpu/cpufreq/policy0" "$D/sys/devices/system/cpu/cpufreq/policy4"
    printf '%s\n' '0 1 2 3' > "$D/sys/devices/system/cpu/cpufreq/policy0/related_cpus"
    printf '%s\n' 1800000 > "$D/sys/devices/system/cpu/cpufreq/policy0/cpuinfo_max_freq"
    printf '%s\n' '4 5 6 7' > "$D/sys/devices/system/cpu/cpufreq/policy4/related_cpus"
    printf '%s\n' 2800000 > "$D/sys/devices/system/cpu/cpufreq/policy4/cpuinfo_max_freq"
    printf '%s\n' '0-7' > "$D/sys/devices/system/cpu/present"
    grep -q "PATH=$D/bin:$HOST_PATH" "$D/control.sh" ||
        bad "后端 PATH 行未被替换（control.sh 的内部 PATH 写法已变动，桩命令无法生效）"
    grep -q "sys/kernel/random/boot_id" "$D/control.sh" &&
        bad "boot_id 路径未被完整替换（/sys/ 规则先于 boot_id 规则改写）"
}
make_fixture "$FAKE"
D=$FAKE
CTL="$FAKE/control.sh"
PATH="$FAKE/bin:$PATH"
export PATH

# 记录一次调用
run_ctl() { OUT=$("$SH" "$CTL" "$@" 2>"$FAKE/last.err"); RC=$?; ERR=$(cat "$FAKE/last.err"); }
UP="$FAKE/sdcard/Android/yc/uperf"
sget() { awk -F= -v k="$1" '$1==k{v=$2} END{print v}' "$FAKE/settings_store" 2>/dev/null; }
RR="$FAKE/data/adb/nanhe_ovo"

printf '\n== control.sh 状态 ==\n'
run_ctl status
eq "status 退出码 0" "$RC" 0
eq "可用模式来自 presets（5 个）" "$(printf '%s\n' "$OUT" | awk -F'\t' '$1=="info"&&$2=="modes"{print $3}' | tr ' ' '\n' | sort | tr '\n' ' ')" "balance crazy fast performance powersave "
eq "模式列表排序稳定" "$(printf '%s\n' "$OUT" | awk -F'\t' '$1=="info"&&$2=="modes"{print $3}')" "balance crazy fast performance powersave"
eq "设备节点 4 个（含无表 GPU）" "$(printf '%s\n' "$OUT" | grep -c '^device')" 4
hasnt "非 GPU devfreq 被过滤" "$OUT" "sramc"
eq "当前模式" "$(printf '%s\n' "$OUT" | awk -F'\t' '$2=="mode"{print $3}')" balance
eq "调优默认开启" "$(printf '%s\n' "$OUT" | awk -F'\t' '$2=="tune"{print $3}')" 开启
eq "版本来自 module.prop" "$(printf '%s\n' "$OUT" | awk -F'\t' '$2=="version"{print $3}')" "$(awk -F '=' '$1 == "version" {print $2; exit}' "$MODULE/module.prop")"
eq "策略已接管" "$(printf '%s\n' "$OUT" | awk -F'\t' '$2=="policy"{print $3}')" 已接管（表驱动）
eq "新安装刷新率默认交给系统" "off" "$(printf '%s\n' "$OUT" | awk -F'\t' '$2=="refresh_manage"{print $3}')"
hasnt "SUSFS 不再进入状态上报" "$OUT" "$(printf 'info\tsusfs\t')"
has "SUSFS 兼容函数仍保留" "$(cat "$MODULE/script/control.sh")" 'susfs_state() {'
hasnt "SUSFS 探测不再被 status 调用" "$(cat "$MODULE/script/control.sh")" 'SUSFS_ST='
has "无表 GPU 行仍报告（模拟厂商锁频）" "$OUT" "gpu-1"

printf '\n== 模式切换 ==\n'
INODE_BEFORE=$("$REAL_STAT" -c %i "$UP/cur_powermode.txt")
run_ctl mode performance
eq "mode 成功" "$RC" 0
eq "模式已写入" "$(cat "$UP/cur_powermode.txt")" performance
eq "写入保持 inode（inotify 可用）" "$("$REAL_STAT" -c %i "$UP/cur_powermode.txt")" "$INODE_BEFORE"
eq "存在 .bak" "yes" "$([ -f "$UP/cur_powermode.txt.bak" ] && echo yes)"
run_ctl mode turbo
[ "$RC" != 0 ] && ok "不存在的模式被拒绝" || bad "不存在的模式被接受"
eq "拒绝后文件未变" "$(cat "$UP/cur_powermode.txt")" performance
run_ctl mode 'fast;reboot'
[ "$RC" != 0 ] && ok "注入式模式名被拒绝" || bad "注入式模式名被接受"
run_ctl mode
[ "$RC" != 0 ] && ok "缺少参数被拒绝" || bad "缺少参数被接受"
run_ctl mode crazy extra
[ "$RC" != 0 ] && ok "参数过多被拒绝" || bad "参数过多被接受"
run_ctl mode crazy
eq "超频模式写入成功" "$RC" 0
eq "超频模式已落盘" "$(cat "$UP/cur_powermode.txt")" crazy
has "超频尝试已记日志" "$(cat "$RR/log.txt" 2>/dev/null)" "超频模式"
run_ctl mode balance
eq "退出超频模式成功" "$RC" 0
eq "退出后模式已恢复" "$(cat "$UP/cur_powermode.txt")" balance

printf '\n== 分应用规则 ==\n'
run_ctl rule com.example.game fast
eq "新增规则成功" "$RC" 0
has "规则已落盘" "$(cat "$UP/perapp_powermode.txt")" "com.example.game fast"
run_ctl rule com.example.game performance
eq "同一包更新策略" "$(grep -c 'com.example.game' "$UP/perapp_powermode.txt")" 1
has "策略已更新" "$(cat "$UP/perapp_powermode.txt")" "com.example.game performance"
run_ctl rule com.example.game delete
eq "删除应用规则" "$(grep -c 'com.example.game' "$UP/perapp_powermode.txt")" 0
run_ctl rule '*'
[ "$RC" != 0 ] && ok "缺少策略参数被拒绝" || bad "缺少策略参数被接受"
run_ctl rule '*' delete
eq "删除默认规则成功" "$RC" 0
hasnt "默认规则已移除" "$(cat "$UP/perapp_powermode.txt")" "* balance"
run_ctl rule '-' powersave
eq "写入熄屏规则" "$RC" 0
run_ctl rule 'com.x$(id)' balance
[ "$RC" != 0 ] && ok "非法包名被拒绝" || bad "非法包名被接受"
run_ctl rule com.example.game turbo
[ "$RC" != 0 ] && ok "规则不接受不存在的模式" || bad "规则接受了不存在的模式"
rm -f "$UP/perapp_powermode.txt"
ln -s "$WORK/outside.txt" "$UP/perapp_powermode.txt"
run_ctl rule com.example.game fast
[ "$RC" != 0 ] && ok "规则文件是符号链接时拒绝写入" || bad "跟随了符号链接"
eq "符号链接目标未被写" "no" "$([ -s "$WORK/outside.txt" ] && echo yes || echo no)"
rm -f "$UP/perapp_powermode.txt"
cp "$MODULE/config/perapp_powermode.txt" "$UP/perapp_powermode.txt"

printf '\n== 频率控制 ==\n'
run_ctl freq cpu-policy0 600000 1200000
eq "合法区间写入成功" "$RC" 0
eq "scaling_min 已写" "$(cat "$D/sys/devices/system/cpu/cpufreq/policy0/scaling_min_freq")" 600000
eq "scaling_max 已写" "$(cat "$D/sys/devices/system/cpu/cpufreq/policy0/scaling_max_freq")" 1200000
eq "生成开机基线" "1" "$(ls "$D/data/adb/nanhe_ovo/runtime" | grep -c baseline)"
has "返回 ok freq" "$OUT" "ok	freq	cpu-policy0	600000	1200000"
run_ctl freq cpu-policy0 500000 1200000
[ "$RC" != 0 ] && ok "表外频率被拒绝" || bad "接受了表外频率"
eq "拒绝后 min 未变" "$(cat "$D/sys/devices/system/cpu/cpufreq/policy0/scaling_min_freq")" 600000
run_ctl freq cpu-policy0 1200000 600000
[ "$RC" != 0 ] && ok "min > max 被拒绝" || bad "接受了 min > max"
run_ctl freq gpu-1 300000000 600000000
[ "$RC" != 0 ] && ok "无频率表的 GPU 拒绝写入" || bad "无频率表仍写入"
run_ctl freq gpu-0 525000000 903000000
eq "GPU 区间写入成功" "$RC" 0
eq "GPU min_freq 已写" "$(cat "$D/sys/devices/platform/kgsl-3d0/devfreq/min_freq")" 525000000
run_ctl freq cpu-policy9 300000 600000
[ "$RC" != 0 ] && ok "不存在的节点被拒绝" || bad "不存在的节点被接受"
run_ctl freq '../../etc' 1 2
[ "$RC" != 0 ] && ok "非法节点标识被拒绝" || bad "非法节点标识被接受"

printf '\n== 频率回滚 ==\n'
ROLLBACK_SETUP=no
RB="$WORK/rb"
make_fixture "$RB"
chattr +i "$RB/sys/devices/system/cpu/cpufreq/policy0/scaling_max_freq" 2>/dev/null && ROLLBACK_SETUP=chattr
if [ "$ROLLBACK_SETUP" = no ] && [ "$("$REAL_ID" -u)" != 0 ]; then
    ROLLBACK_SETUP=skip
fi
if [ "$ROLLBACK_SETUP" != chattr ]; then
    skip "回滚路径（当前环境无法模拟只读节点：root + 无 chattr）"
else
    RBCTL="$RB/control.sh"
    OUT=$("$SH" "$RBCTL" freq cpu-policy0 600000 1200000 2>"$RB/err"); RC=$?
    [ "$RC" != 0 ] && ok "写入失败返回非 0" || bad "写入失败被判成功"
    eq "回滚后 min 恢复原值" "$(cat "$RB/sys/devices/system/cpu/cpufreq/policy0/scaling_min_freq")" 300000
    eq "max 保持原值" "$(cat "$RB/sys/devices/system/cpu/cpufreq/policy0/scaling_max_freq")" 1800000
    has "错误信息标注回滚" "$(cat "$RB/err")" "rolling back"
    [ "$ROLLBACK_SETUP" = chattr ] && chattr -i "$RB/sys/devices/system/cpu/cpufreq/policy0/scaling_max_freq" 2>/dev/null
fi

printf '\n== 基线恢复 ==\n'
D=$FAKE
run_ctl restore
eq "restore 成功" "$RC" 0
eq "CPU0 min 回到开机值" "$(cat "$D/sys/devices/system/cpu/cpufreq/policy0/scaling_min_freq")" 300000
eq "CPU0 max 回到开机值" "$(cat "$D/sys/devices/system/cpu/cpufreq/policy0/scaling_max_freq")" 1800000
eq "GPU min 回到开机值" "$(cat "$D/sys/devices/platform/kgsl-3d0/devfreq/min_freq")" 220000000
BASE=$(ls "$D/data/adb/nanhe_ovo/runtime/" | grep baseline)
printf 'gpu-9\t%s\n' "$D/sys/devices/platform/vendor-gpu/devfreq" >> "$D/data/adb/nanhe_ovo/runtime/$BASE"
run_ctl restore
[ "$RC" != 0 ] && ok "基线记录不完整时拒绝恢复" || bad "接受了损坏的基线"
rm -f "$D/data/adb/nanhe_ovo/runtime/$BASE"
run_ctl restore
[ "$RC" != 0 ] && ok "没有基线时 restore 失败" || bad "无基线仍报告成功"

printf '\n== 调优开关 ==\n'
run_ctl tune off
eq "tune off 成功" "$RC" 0
eq "生成关闭标记" "yes" "$([ -f "$D/data/adb/nanhe_ovo/tune_disabled" ] && echo yes)"
run_ctl status
eq "状态显示关闭" "$(printf '%s\n' "$OUT" | awk -F'\t' '$2=="tune"{print $3}')" 关闭
run_ctl tune on
eq "tune on 成功" "$RC" 0
eq "标记已移除" "no" "$([ -f "$D/data/adb/nanhe_ovo/tune_disabled" ] && echo yes || echo no)"
run_ctl tune maybe
[ "$RC" != 0 ] && ok "非法 tune 参数被拒绝" || bad "非法 tune 参数被接受"

printf '\n== 应用列表与并发保护 ==\n'
run_ctl apps
eq "只输出合法包名" "$(printf '%s\n' "$OUT" | grep -c '^com\.')" 4
hasnt "过滤垃圾行" "$OUT" "junk"
has "命中名单的游戏带中文名与 game 标记" "$OUT" "com.tencent.tmgp.sgame	王者荣耀	game"
eq "非游戏包第二列回退包名" "com.example.reader	com.example.reader	app" "$(printf '%s\n' "$OUT" | grep 'com.example.reader')"
hasnt "未命中名单的包不带标记" "$(printf '%s\n' "$OUT" | grep 'com.example.reader')" "game"
run_ctl rules
eq "rules 输出规则原文" "$RC" 0

printf '\n== 应用清单降级（真机 pm 失败场景）==\n'
mv "$D/bin/pm" "$D/bin/pm.off"
run_ctl apps
eq "pm 不可用时 apps 仍退出 0" "$RC" 0
has "回落到系统包清单" "$OUT" "com.example.camera"
run_ctl status
eq "pm 不可用时 status 不受影响" "$RC" 0
eq "status 仍报告 4 个设备" "$(printf '%s\n' "$OUT" | grep -c '^device')" 4

mv "$D/data/system/packages.list" "$D/packages.list.off"
run_ctl apps
eq "全部枚举失败仍退出 0" "$RC" 0
eq "全部失败时清单为空" "" "$OUT"
has "全部失败时给出告警" "$ERR" "package enumeration unavailable"
mv "$D/packages.list.off" "$D/data/system/packages.list"
mv "$D/bin/pm.off" "$D/bin/pm"

printf '\n== 屏幕刷新率（30–240Hz 档位与写入）==\n'
run_ctl status
eq "刷新率档位 10 个" "30 48 60 72 90 120 144 165 180 240" "$(printf '%s\n' "$OUT" | awk -F'\t' '$2=="refresh_tiers"{print $3}')"
eq "只保留设备声明过的档位" "60 120 144" "$(printf '%s\n' "$OUT" | awk -F'\t' '$2=="refresh_supported"{print $3}')"
eq "当前刷新率来自 SurfaceFlinger" "120" "$(printf '%s\n' "$OUT" | awk -F'\t' '$2=="refresh"{print $3}')"
eq "尚未设置目标" "none" "$(printf '%s\n' "$OUT" | awk -F'\t' '$2=="refresh_target"{print $3}')"
eq "档位表来自设备 dump" "1" "$(printf '%s\n' "$OUT" | awk -F'\t' '$2=="refresh_known"{print $3}')"

run_ctl refresh_manage on
eq "开启刷新率总开关成功" "0" "$RC"
eq "无历史目标时固定当前刷新率" "120" "$(sget peak_refresh_rate)"
eq "开启管理即固定下限" "120" "$(sget min_refresh_rate)"
eq "管理状态已持久化" "on" "$(cat "$RR/refresh_manage")"
run_ctl refresh 120 on
eq "写入 120Hz 成功" "0" "$RC"
eq "peak_refresh_rate 已写入" "120" "$(sget peak_refresh_rate)"
eq "min_refresh_rate 已写入（钉住下限）" "120" "$(sget min_refresh_rate)"
eq "目标已记录，供开机应用" "120" "$(cat "$RR/refresh.txt")"
eq "锁定状态已记录" "yes" "$([ -f "$RR/refresh_pin" ] && echo yes || echo no)"

run_ctl refresh 144 off
eq "只写上限时成功" "0" "$RC"
eq "peak 更新为 144" "144" "$(sget peak_refresh_rate)"
eq "关闭锁定时删除下限" "" "$(sget min_refresh_rate)"
eq "锁定状态已清除" "no" "$([ -f "$RR/refresh_pin" ] && echo yes || echo no)"

run_ctl refresh 90 on
[ "$RC" != 0 ] && ok "不支持的档位被拒绝" || bad "不支持的档位被接受"
has "拒绝文案说明不支持" "$ERR" "90 Hz is not supported by this device"
eq "拒绝后上限未变" "144" "$(sget peak_refresh_rate)"

run_ctl refresh 480 on
[ "$RC" != 0 ] && ok "超出 30–240 范围被拒绝" || bad "越界刷新率被接受"
has "越界文案" "$ERR" "invalid refresh rate"
run_ctl refresh 120 maybe
[ "$RC" != 0 ] && ok "非法锁定参数被拒绝" || bad "非法锁定参数被接受"

ln -s /tmp/not-here "$RR/refresh.txt.bad" 2>/dev/null
rm -f "$RR/refresh.txt"
ln -s /tmp/not-here "$RR/refresh.txt"
run_ctl refresh 120 on
[ "$RC" != 0 ] && ok "刷新率状态文件是符号链接时拒绝写入" || bad "符号链接未被拒绝"
has "符号链接文案" "$ERR" "refresh state symlink refused"
rm -f "$RR/refresh.txt" "$RR/refresh.txt.bad"
printf '%s\n' 120 > "$RR/refresh.txt"

run_ctl refresh_manage off
eq "关闭刷新率管理成功" "0" "$RC"
eq "关闭后还原系统原 peak（原为空则删除）" "" "$(sget peak_refresh_rate)"
eq "关闭后还原系统原 min（原为空则删除）" "" "$(sget min_refresh_rate)"
eq "关闭状态已持久化" "off" "$(cat "$RR/refresh_manage")"
eq "关闭后不再保留下限标记" "no" "$([ -f "$RR/refresh_pin" ] && echo yes || echo no)"
run_ctl refresh_manage invalid
[ "$RC" != 0 ] && ok "非法刷新率管理参数被拒绝" || bad "非法刷新率管理参数被接受"
run_ctl refresh 120 on
eq "手动选档会重新开启管理" "on" "$(cat "$RR/refresh_manage")"

printf '\n== 刷新率档位读取（多种 dump 写法与读不到时的兜底）==\n'
# 真机上档位不一定写成 fps=：可能只有 refreshRate= / vsyncPeriod=（纳秒）/ @120Hz
cat > "$D/dumpsys_variant" <<'VARIANT'
DisplayDeviceInfo{"Built-in Screen": 1880 x 3008}
  modeSupport: refreshRate=90.0
  vsyncPeriod=8333333
  modeString 1880x3008@120.0Hz
VARIANT
run_ctl status
eq "refreshRate= 写法可读出" "90" "$(printf '%s\n' "$OUT" | awk -F'\t' '$2=="refresh_supported"{print $3}' | awk '{print $1}')"
eq "vsyncPeriod 与 @120Hz 写法可读出" "90 120" "$(printf '%s\n' "$OUT" | awk -F'\t' '$2=="refresh_supported"{print $3}')"
run_ctl refresh 90 on
eq "读到的档位可以写入" "$RC" 0
eq "写入的档位已生效" "$(sget peak_refresh_rate)" 90
run_ctl refresh 144 on
[ "$RC" != 0 ] && ok "设备没声明的档位仍被拒绝" || bad "未声明的档位被接受"
rm -f "$D/dumpsys_variant"

# 读不到档位表（真机截图里的情形）：不能把全部档位都禁用，放开给用户尝试
: > "$D/dumpsys_silent"
run_ctl status
eq "读不到档位表时 refresh_known=0" "0" "$(printf '%s\n' "$OUT" | awk -F'\t' '$2=="refresh_known"{print $3}')"
eq "读不到档位表时放开全部 10 档" "30 48 60 72 90 120 144 165 180 240" "$(printf '%s\n' "$OUT" | awk -F'\t' '$2=="refresh_supported"{print $3}')"
run_ctl refresh 240 on
eq "未读到档位表时不拒绝写入" "$RC" 0
eq "写入值按原样落盘" "$(sget peak_refresh_rate)" 240
rm -f "$D/dumpsys_silent"
run_ctl status
eq "重新读到档位表后恢复严格校验" "1" "$(printf '%s\n' "$OUT" | awk -F'\t' '$2=="refresh_known"{print $3}')"
run_ctl refresh 90 on
[ "$RC" != 0 ] && ok "恢复严格校验后未声明档位再次被拒绝" || bad "恢复后仍接受未声明档位"
run_ctl refresh 120 on
eq "回到 120Hz 供后续用例" "$RC" 0

# 两份脚本里的解析实现必须一致，否则开机脚本会按另一套规则解析
fn_body() { awk -v fn="$2() {" 'index($0, fn) { f = 1 } f { print } f && /^}/ { exit }' "$1"; }
eq "两处 refresh_table 实现逐字一致" "$(fn_body "$D/refresh_apply.sh" refresh_table)" "$(fn_body "$D/control.sh" refresh_table)"

printf '\n== 机型信息（关于页数据源）==\n'
run_ctl deviceinfo
kv() { printf '%s\n' "$OUT" | awk -F'\t' -v l="$1" '$3==l{print $4; exit}'; }
eq "deviceinfo 退出码 0" "$RC" "0"
eq "品牌取自 ro.product.brand" "$(kv 品牌)" "REDMI"
eq "型号取自 ro.product.model" "$(kv 型号)" "25079RPDCC"
eq "制造商取自 ro.product.manufacturer" "$(kv 制造商)" "Xiaomi"
eq "指纹完整保留" "$(kv 指纹)" "Redmi/turner/turner:17/CP2A.260605.016/OS4.0.3.0:user/release-keys"
eq "含空格的标签带值（Android 版本）" "$(kv "Android 版本")" "17"
eq "含空格的标签带值（API 级别）" "$(kv "API 级别")" "37"
eq "含空格的标签带值（Build 号）" "$(kv "Build 号")" "CP2A.260605.016"
eq "SELinux 本地化" "$(kv SELinux)" "强制 Enforcing"
eq "内核版本取自 uname" "$(kv 内核版本)" "6.6.118-android15-test"
eq "核心数由 possible 范围算得" "$(kv 核心数)" "8"
eq "含空格的标签带值（支持 ABI）" "$(kv "支持 ABI")" "arm64-v8a/armeabi-v7a/armeabi"
eq "含空格的标签带值（CPU 温度）" "$(kv "CPU 温度")" "61.5 °C"
eq "分辨率带 × 与单位" "$(kv 分辨率)" "1880 × 3008 px"
eq "像素密度带 dpi" "$(kv 像素密度)" "450 dpi"
eq "电池电量带百分号" "$(kv 电量)" "82%"
eq "电池温度按十分度换算" "$(kv 温度)" "35.0 °C"
eq "电池健康已本地化" "$(kv 健康)" "良好"
eq "电池状态已本地化" "$(kv 状态)" "充电中"
eq "每个分组都有输出" "$(printf '%s\n' "$OUT" | awk -F'\t' '$1=="kv"{print $2}' | sort -u | tr '\n' ' ')" "battery device hardware memory screen storage system "
eq "只有 kv 与结尾 ok 两类行" "0" "$(printf '%s\n' "$OUT" | awk -F'\t' '$1!="kv"&&$1!="ok"' | wc -l | tr -d ' ')"
eq "结尾为 ok deviceinfo" "ok deviceinfo" "$(printf '%s\n' "$OUT" | awk -F'\t' 'END{print $1, $2}')"

printf '\n== 开机刷新率（总开关与系统管理）==\n'
BOOT_RUN() { BOOT_OUT=$(PATH="$FAKE/bin:$PATH" "$SH" "$FAKE/refresh_apply.sh" 2>&1); BOOT_RC=$?; }
rm -f "$RR/refresh.txt" "$RR/refresh_pin" "$RR/refresh_manage" "$FAKE/settings_store"
BOOT_RUN
eq "无记录时退出 0（不影响开机）" "0" "$BOOT_RC"
eq "新安装不生成刷新率目标" "no" "$([ -f "$RR/refresh.txt" ] && echo yes || echo no)"
eq "新安装开机不写 peak" "" "$(sget peak_refresh_rate)"
eq "新安装开机不写 min" "" "$(sget min_refresh_rate)"
has "日志说明保持系统管理" "$BOOT_OUT" "保持系统设置"

# v1.5.0 只有 refresh.txt、没有总开关文件时，按旧行为兼容为开启。
printf '%s\n' 120 > "$RR/refresh.txt"
rm -f "$RR/refresh_manage" "$FAKE/settings_store"
BOOT_RUN
eq "旧版保存目标仍按 120Hz 应用" "120" "$(sget peak_refresh_rate)"
eq "新版开启管理会强制钉住下限" "120" "$(sget min_refresh_rate)"

printf '%s\n' off > "$RR/refresh_manage"
rm -f "$FAKE/settings_store"
BOOT_RUN
eq "明确关闭时保留系统 peak" "" "$(sget peak_refresh_rate)"
eq "明确关闭时保留系统 min" "" "$(sget min_refresh_rate)"

printf '%s\n' on > "$RR/refresh_manage"
printf '%s\n' 90 > "$RR/refresh.txt"
rm -f "$FAKE/settings_store"
BOOT_RUN
eq "不支持的已保存档位被跳过" "" "$(sget peak_refresh_rate)"
eq "跳过时不再改写目标为最高档" "90" "$(cat "$RR/refresh.txt")"
has "跳过日志说明保持系统设置" "$BOOT_OUT" "保持系统设置"

# 读不到档位表但已有明确目标时，沿用通用候选校验并应用保存值。
: > "$D/dumpsys_silent"
printf '%s\n' 120 > "$RR/refresh.txt"
rm -f "$FAKE/settings_store"
BOOT_RUN
eq "无档位表时仍应用已保存目标" "120" "$(sget peak_refresh_rate)"
eq "无档位表时下限也按总开关固定" "120" "$(sget min_refresh_rate)"
rm -f "$D/dumpsys_silent"
mkdir -p "$D/data/adb/nanhe_ovo/runtime/lock.aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
run_ctl status
eq "残留锁（无存活 PID）自动清理并放行" "0" "$RC"
eq "残留锁目录已被移除" "no" "$([ -d "$D/data/adb/nanhe_ovo/runtime/lock.aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee" ] && echo yes || echo no)"

printf '\n== 运行时目录安全 ==\n'
mv "$D/data/adb/nanhe_ovo/runtime" "$WORK/runtime-real"
ln -s "$WORK/runtime-real" "$D/data/adb/nanhe_ovo/runtime"
run_ctl status
[ "$RC" != 0 ] && ok "运行时目录为符号链接时拒绝" || bad "接受了符号链接运行时目录"
rm -f "$D/data/adb/nanhe_ovo/runtime"
mv "$WORK/runtime-real" "$D/data/adb/nanhe_ovo/runtime"

########################################
# 3. 安装器
########################################
printf '\n== 安装器 ==\n'
INST="$WORK/inst"
_mk_policy() { # $1=根 $2=policy编号 $3=最高频kHz $4=related_cpus
    _p="$1/sys/devices/system/cpu/cpufreq/policy$2"
    mkdir -p "$_p"
    printf '%s\n' "$4" > "$_p/related_cpus"
    printf '%s\n' "$3" > "$_p/cpuinfo_max_freq"
}
make_install() {
    D=$1; plat=$2; abi=$3; MODP=$4
    rm -rf "$D"; mkdir -p "$D/bin"
    cp -a "$MODULE" "$MODP"
    # AppOpt 真机二进制不能在宿主机执行：换成桩，只验证安装器校验逻辑
    printf '#!/bin/sh\nexit 0\n' > "$MODP/bin/appopt/AppOpt"
    cp "$MODP/bin/appopt/AppOpt" "$MODP/bin/appopt/AppOpt-ebpf"
    chmod +x "$MODP/bin/appopt/AppOpt" "$MODP/bin/appopt/AppOpt-ebpf"
    sed -i \
        -e "s#/data/adb/nanhe_ovo#$D/data/adb/nanhe_ovo#g" \
        -e "s#/data/adb/modules#$D/data/adb/modules#g" \
        -e "s#/sdcard#$D/sdcard#g" \
        -e "s#/sys/#$D/sys/#g" \
        "$MODP/customize.sh" "$MODP/script/pathinfo.sh" "$MODP/script/libsysinfo.sh"
    # 与平台匹配的 CPU 拓扑夹具：安装期的拓扑指纹校验必须读测试根，不能读宿主 /sys
    mkdir -p "$D/sys/devices/system/cpu/cpufreq"
    case "$plat" in
        gs201)
            _mk_policy "$D" 0 1800000 '0 1 2 3'; _mk_policy "$D" 1 2400000 '4 5'; _mk_policy "$D" 2 2800000 '6 7' ;;
        mt6991)
            _mk_policy "$D" 0 2400000 '0 1 2 3'; _mk_policy "$D" 1 3300000 '4 5 6'; _mk_policy "$D" 2 3630000 '7' ;;
        *)
            _mk_policy "$D" 0 1800000 '0 1 2 3'; _mk_policy "$D" 1 2400000 '4 5'; _mk_policy "$D" 2 2800000 '6 7' ;;
    esac
    printf '%s\n' '0-7' > "$D/sys/devices/system/cpu/present"
    printf '#!/bin/sh\ncase "$1" in\n ro.product.cpu.abi) echo "%s";;\n ro.board.platform) echo "%s";;\n ro.product.board) echo "";;\n *) echo "";;\nesac\n' "$abi" "$plat" > "$D/bin/getprop"
    chmod +x "$D/bin/getprop"
}
run_install() { OUT=$(PATH="$INST/bin:$HOST_PATH" MODPATH="$INST/mod" "$SH" "$INST/mod/customize.sh" 2>&1); RC=$?; }

make_install "$INST" gs201 arm64-v8a "$INST/mod"
run_install
eq "arm64 + gs201 安装退出 0" "$RC" 0
eq "写入的配置与 gs201.json 一致" "same" "$(cmp -s "$INST/sdcard/Android/yc/uperf/uperf.json" "$MODULE/config/gs201.json" && echo same || echo diff)"
eq "平台配置名已记录" "$(cat "$INST/data/adb/nanhe_ovo/device_config.txt")" gs201
eq "分应用规则已就位" "same" "$(cmp -s "$INST/sdcard/Android/yc/uperf/perapp_powermode.txt" "$MODULE/config/perapp_powermode.txt" && echo same || echo diff)"
eq "默认模式已写入" "$(cat "$INST/sdcard/Android/yc/uperf/cur_powermode.txt")" balance
eq "安装后移除平台配置目录" "no" "$([ -d "$INST/mod/config" ] && echo yes || echo no)"
eq "ACE 跳过名单保留在模块根" "yes" "$([ -f "$INST/mod/thread_skip.list" ] && echo yes || echo no)"
has "安装提示包含 WebUI 指引" "$OUT" "打开 WebUI"

printf '\n'
make_install "$INST" mt6991 arm64-v8a "$INST/mod"
run_install
eq "Dimensity 9400 使用专有配置" "same" "$(cmp -s "$INST/sdcard/Android/yc/uperf/uperf.json" "$MODULE/config/mtd9400.json" && echo same || echo diff)"
eq "D9400 配置名已记录" "$(cat "$INST/data/adb/nanhe_ovo/device_config.txt")" mtd9400
has "D9400 配置含功耗模型" "$(cat "$MODULE/config/mtd9400.json")" '"typicalFreq": 3.63'

printf '\n'
make_install "$INST" mt8175 arm64-v8a "$INST/mod"
run_install
eq "映射名缺配置时回落到模板" "same" "$(cmp -s "$INST/sdcard/Android/yc/uperf/uperf.json" "$MODULE/config/template.json" && echo same || echo diff)"
eq "回落时记录 template" "$(cat "$INST/data/adb/nanhe_ovo/device_config.txt")" template
has "回落时有提示" "$OUT" "通用模板"

printf '\n'
make_install "$INST" nosuch arm64-v8a "$INST/mod"
run_install
# 属性完全不认识时按真实拓扑挑配置（4+4 @2.8GHz 正好命中 gs201），不再直接退模板
eq "未知平台按拓扑指纹选到配置" "same" "$(cmp -s "$INST/sdcard/Android/yc/uperf/uperf.json" "$MODULE/config/gs201.json" && echo same || echo diff)"
eq "未知平台记录来源为 topo" "$(cat "$INST/data/adb/nanhe_ovo/config_source.txt")" topo

printf '\n'
# 伪装机型：属性说 gs201（4+2+2 @1.8/2.4/2.8），实际是 4+3+1 @2.4/3.3/3.63
make_install "$INST" gs201 arm64-v8a "$INST/mod"
rm -rf "$INST/sys/devices/system/cpu/cpufreq"
_mk_policy "$INST" 0 2400000 '0 1 2 3'
_mk_policy "$INST" 1 3300000 '4 5 6'
_mk_policy "$INST" 2 3630000 '7'
run_install
eq "伪装机型按拓扑改用真实平台配置" "same" "$(cmp -s "$INST/sdcard/Android/yc/uperf/uperf.json" "$MODULE/config/mtd9400.json" && echo same || echo diff)"
eq "伪装机型配置名被纠正" "$(cat "$INST/data/adb/nanhe_ovo/device_config.txt")" mtd9400
eq "伪装机型记录来源为 topo" "$(cat "$INST/data/adb/nanhe_ovo/config_source.txt")" topo
has "伪装机型写日志说明" "$OUT" "与本机拓扑不符"

printf '\n'
make_install "$INST" gs201 armeabi-v7a "$INST/mod"
run_install
[ "$RC" != 0 ] && ok "非 arm64 拒绝安装" || bad "非 arm64 被接受"
has "提示需要 arm64" "$OUT" "需要 arm64"

printf '\n'
make_install "$INST" gs201 arm64-v8a "$INST/mod"
mkdir -p "$INST/sdcard/Android/yc/uperf"
printf '%s\n' old-config > "$INST/sdcard/Android/yc/uperf/uperf.json"
run_install
eq "升级时保留旧配置备份" "old-config" "$(cat "$INST/sdcard/Android/yc/uperf/uperf.json.bak")"

printf '\n'
make_install "$INST" gs201 arm64-v8a "$INST/mod"
rm -f "$INST/mod/cpu_profiles.tsv"
run_install
[ "$RC" != 0 ] && ok "缺少 CPU 表时拒绝安装" || bad "缺 CPU 表仍安装"
has "提示安装包不完整" "$OUT" "安装包不完整"

printf '\n'
make_install "$INST" gs201 arm64-v8a "$INST/mod"
rm -rf "$INST/mod/bin/appopt"
run_install
[ "$RC" != 0 ] && ok "缺少 AppOpt 引擎时拒绝安装" || bad "缺 AppOpt 仍安装"
has "提示缺少线程引擎" "$OUT" "线程引擎"

printf '\n'
make_install "$INST" gs201 arm64-v8a "$INST/mod"
rm -f "$INST/mod/webroot/index.html"
run_install
[ "$RC" != 0 ] && ok "缺少 WebUI 时拒绝安装" || bad "缺 WebUI 仍安装"

# 真机场景：KernelSU / APatch 解包不还原 zip 里的可执行位，文件以 0644 落盘
printf '\n'
make_install "$INST" gs201 arm64-v8a "$INST/mod"
find "$INST/mod" -type f -exec chmod 0644 {} \;
run_install
eq "解包丢失可执行位仍安装成功" "$RC" 0
eq "安装后 busybox 可执行" "yes" "$([ -x "$INST/mod/bin/busybox/busybox" ] && echo yes || echo no)"
eq "安装后 CPU 策略脚本可执行" "yes" "$([ -x "$INST/mod/script/cpu_policy.sh" ] && echo yes || echo no)"
eq "安装后线程引擎恢复 0755" "755" "$(stat -c %a "$INST/mod/bin/appopt/AppOpt")"
eq "安装后线程引擎可执行" "yes" "$([ -x "$INST/mod/bin/appopt/AppOpt" ] && echo yes || echo no)"
eq "安装后后端脚本可执行" "yes" "$([ -x "$INST/mod/script/control.sh" ] && echo yes || echo no)"

printf '\n'
make_install "$INST" gs201 arm64-v8a "$INST/mod"
: >"$INST/mod/cpu_profiles.tsv"
run_install
[ "$RC" != 0 ] && ok "空 CPU 表被拒绝" || bad "空 CPU 表仍安装"
has "提示安装包不完整" "$OUT" "安装包不完整"

# 旧版分应用模板迁移：旧 * performance 换成新模板，非内置自定义包保留
printf '\n'
make_install "$INST" gs201 arm64-v8a "$INST/mod"
mkdir -p "$INST/sdcard/Android/yc/uperf"
printf '%s\n' 'com.tencent.tmgp.sgame performance' '- powersave' '* performance' 'com.example.custom fast' > "$INST/sdcard/Android/yc/uperf/perapp_powermode.txt"
run_install
has "旧模板默认规则已迁移为 balance" "$(cat "$INST/sdcard/Android/yc/uperf/perapp_powermode.txt")" '* balance'
has "迁移后含三角洲 fast" "$(cat "$INST/sdcard/Android/yc/uperf/perapp_powermode.txt")" 'com.tencent.tmgp.dfm fast'
has "自定义包规则保留" "$(cat "$INST/sdcard/Android/yc/uperf/perapp_powermode.txt")" 'com.example.custom fast'
has "旧规则已备份" "yes" "$([ -f "$INST/sdcard/Android/yc/uperf/perapp_powermode.txt.bak" ] && echo yes || echo no)"

# 自研 CPU 策略独立运行：gs201 powersave 上限应压到真实 OPP
printf '\n'
make_install "$INST" gs201 arm64-v8a "$INST/mod"
run_install
printf '%s\n' gs201 > "$INST/data/adb/nanhe_ovo/device_config.txt"
for p in 0 1; do
    d="$INST/sys/devices/system/cpu/cpufreq/policy$p"
    printf '%s\n' 300000 > "$d/scaling_min_freq"
    printf '%s\n' 2800000 > "$d/scaling_max_freq"
done
printf '%s\n' '300000 600000 1200000 1800000' > "$INST/sys/devices/system/cpu/cpufreq/policy0/scaling_available_frequencies"
printf '%s\n' '710400 1200000 1800000 2400000 2803200' > "$INST/sys/devices/system/cpu/cpufreq/policy1/scaling_available_frequencies"
NANHE_SYSFS="$INST/sys/" NANHE_RUNTIME="$INST/data/adb/nanhe_ovo" NANHE_USER_PATH="$INST/sdcard/Android/yc/uperf" sh "$INST/mod/script/cpu_policy.sh" apply powersave >/dev/null 2>&1
eq "cpu_policy 写入 policy0 powersave 上限" "600000" "$(cat "$INST/sys/devices/system/cpu/cpufreq/policy0/scaling_max_freq")"
eq "cpu_policy 写入 policy1 powersave 上限" "710400" "$(cat "$INST/sys/devices/system/cpu/cpufreq/policy1/scaling_max_freq")"

########################################
# 4. 运行日志
########################################
printf '\n== 运行日志 ==\n'
run_ctl clearlog
eq "清空日志退出 0" "$RC" 0
eq "清空后日志文件已删除" "no" "$([ -e "$RR/log.txt" ] && echo yes || echo no)"
run_ctl logs
eq "空日志只返回 ok" "ok	logs" "$OUT"

run_ctl logline info page '页面开始记录'
eq "写日志退出 0" "$RC" 0
eq "写日志返回 ok" "ok	logline" "$OUT"
has "日志文件包含正文" "$(cat "$RR/log.txt")" "页面开始记录"
eq "日志级别为 info" "info" "$(awk -F'\t' 'END{print $2}' "$RR/log.txt")"
eq "日志标签为 page" "page" "$(awk -F'\t' 'END{print $3}' "$RR/log.txt")"

run_ctl logline error refresh '峰值写入失败'
eq "error 级别被接受" "error" "$(awk -F'\t' 'END{print $2}' "$RR/log.txt")"

run_ctl logline silly page 'x'
[ "$RC" != 0 ] && ok "非法日志级别被拒绝" || bad "接受了非法日志级别"
has "非法级别有提示" "$ERR" "invalid log level"
run_ctl logline info 'bad tag' x
[ "$RC" != 0 ] && ok "非法日志标签被拒绝" || bad "接受了非法日志标签"
has "非法标签有提示" "$ERR" "invalid log tag"
run_ctl logline info page ''
[ "$RC" != 0 ] && ok "空日志正文被拒绝" || bad "接受了空日志正文"

LONG=$(awk 'BEGIN{for(i=0;i<260;i++) printf "x"}')
run_ctl logline warn page "$LONG"
eq "超长正文截到 200 字" "200" "$(awk -F'\t' 'END{print length($4)}' "$RR/log.txt")"

# 日志文件是符号链接时既不写也不清空
mv "$RR/log.txt" "$WORK/log-real"
ln -s "$WORK/log-real" "$RR/log.txt"
run_ctl logs
[ "$RC" != 0 ] && ok "日志为符号链接时拒绝读取" || bad "读取了符号链接日志"
has "符号链接提示" "$ERR" "log file symlink refused"
run_ctl logline info page '不该写进去'
[ "$RC" = 0 ] && ok "符号链接时不写日志（静默跳过）" || bad "符号链接写入返回非 0"
hasnt "符号链接目标未被写入" "$(cat "$WORK/log-real")" "不该写进去"
run_ctl clearlog
[ "$RC" != 0 ] && ok "日志为符号链接时拒绝清空" || bad "清空了符号链接日志"
rm -f "$RR/log.txt"
mv "$WORK/log-real" "$RR/log.txt"

# 超过 200 行自动裁掉最早的
awk 'BEGIN{for(i=1;i<=205;i++) printf "2026-11-16 00:00:00\tinfo\told\t第 %d 条\n", i}' >> "$RR/log.txt"
run_ctl logline info page '触发裁剪'
eq "日志裁剪到 200 行" "200" "$(wc -l < "$RR/log.txt" | tr -d ' ')"
hasnt "最早的行已被裁掉" "$(cat "$RR/log.txt")" "第 1 条"
has "最新一行仍在" "$(cat "$RR/log.txt")" "触发裁剪"

# 读到异常状态时自动记录，且同一开机只记一次
run_ctl clearlog
: > "$FAKE/dumpsys_silent"
run_ctl status
has "读不到档位表时自动记日志" "$(cat "$RR/log.txt")" "未读到刷新率档位表"
run_ctl status
eq "同一问题不随轮询刷屏" "1" "$(grep -c '未读到刷新率档位表' "$RR/log.txt")"
# 读不到档位表时写入会放行，但也记一条 info
run_ctl refresh 90 on
eq "无档位表时 90Hz 放行" "$RC" 0
has "放行时记下 info" "$(cat "$RR/log.txt")" "未读到档位表，已放行 90Hz"
rm -f "$FAKE/dumpsys_silent"
# 有档位表时未声明档位被拒绝，命令失败自动记一条 error
run_ctl refresh 90 on
[ "$RC" != 0 ] && ok "未声明档位仍被拒绝" || bad "接受了未声明的 90Hz"
eq "命令失败记为 error" "error" "$(awk -F'\t' 'END{print $2}' "$RR/log.txt")"
has "错误原文进了日志" "$(cat "$RR/log.txt")" "90 Hz is not supported by this device"

# 开机脚本把刷新率动作写进同一份日志
has "refresh_apply 也写日志文件" "$(cat "$MODULE/script/refresh_apply.sh")" '>> "$RROOT/log.txt"'

printf '\n== 平台配置完整性（v1.4.0 全平台 crazy + 2026 新平台）==\n'
CONFIG_DIR="$MODULE/config"
[ -f "$CONFIG_DIR/mtd9600pro.json" ] && ok "mtd9600pro 配置存在" || bad "缺少 mtd9600pro.json"
has "9600 Pro 含 4.55GHz 模型点" "$(cat "$CONFIG_DIR/mtd9600pro.json")" "4.55"
[ -f "$CONFIG_DIR/mtd9600m.json" ] && ok "mtd9600m 配置存在" || bad "缺少 mtd9600m.json"
[ -f "$CONFIG_DIR/mtd9500s.json" ] && ok "mtd9500s 配置存在" || bad "缺少 mtd9500s.json"
[ -f "$CONFIG_DIR/mtd8500.json" ] && ok "mtd8500 配置存在" || bad "缺少 mtd8500.json"
has "8500 为 1+3+4 三簇" "$(cat "$CONFIG_DIR/mtd8500.json")" '"nr": 1'
[ -f "$CONFIG_DIR/sdm8e6.json" ] && ok "sdm8e6 配置存在" || bad "缺少 sdm8e6.json"
has "8E6 含 5.0GHz 模型点" "$(cat "$CONFIG_DIR/sdm8e6.json")" "5.0"
[ -f "$CONFIG_DIR/sdm8e6x.json" ] && ok "sdm8e6x 配置存在" || bad "缺少 sdm8e6x.json"
has "8E6x 含 5.01GHz 模型点" "$(cat "$CONFIG_DIR/sdm8e6x.json")" "5.01"
[ -f "$CONFIG_DIR/exynos2700.json" ] && ok "exynos2700 配置存在" || bad "缺少 exynos2700.json"
[ -f "$CONFIG_DIR/e2400.json" ] && ok "e2400 配置存在" || bad "缺少 e2400.json"
has "2400 为四簇结构（含 2 核 2.9GHz 组）" "$(cat "$CONFIG_DIR/e2400.json")" '"nr": 2'
[ -f "$CONFIG_DIR/sdm8elite.json" ] && ok "sdm8elite 配置存在" || bad "缺少 sdm8elite.json"
has "8 Elite 含 4.32GHz 模型点" "$(cat "$CONFIG_DIR/sdm8elite.json")" "4.32"
[ -f "$CONFIG_DIR/mtd9300.json" ] && ok "mtd9300 配置存在" || bad "缺少 mtd9300.json"
has "9300 含 3.25GHz 模型点" "$(cat "$CONFIG_DIR/mtd9300.json")" "3.25"
[ -f "$CONFIG_DIR/kirin9020.json" ] && ok "kirin9020 配置存在" || bad "缺少 kirin9020.json"
has "9020 含 2.5GHz 模型点" "$(cat "$CONFIG_DIR/kirin9020.json")" "2.5"
[ -f "$CONFIG_DIR/gs401.json" ] && ok "gs401 配置存在" || bad "缺少 gs401.json"
has "Tensor G4 含 3.1GHz 模型点" "$(cat "$CONFIG_DIR/gs401.json")" "3.1"
[ -f "$CONFIG_DIR/sp9832.json" ] && ok "sp9832 配置存在" || bad "缺少 sp9832.json"
has "9832 为四核单簇" "$(cat "$CONFIG_DIR/sp9832.json")" '"nr": 4'
[ -f "$CONFIG_DIR/mtd8400.json" ] && ok "mtd8400 配置存在" || bad "缺少 mtd8400.json"
CRAZY_MISS=0
for cf in "$CONFIG_DIR"/*.json; do
    grep -q '"crazy"' "$cf" || CRAZY_MISS=1
done
[ "$CRAZY_MISS" = 0 ] && ok "全部平台配置均含 crazy 超频模式" || bad "存在缺少 crazy 的配置"
if python3 -c '
import json,glob,sys
bad=[]
for f in glob.glob(sys.argv[1]+"/*.json"):
    try: json.load(open(f,encoding="utf-8"))
    except Exception: bad.append(f)
sys.exit(1 if bad else 0)' "$CONFIG_DIR"; then
    ok "全部平台配置 JSON 可解析"
else
    bad "存在无法解析的配置 JSON"
fi
has "mtd9400 超频档 DDR 保底 6.4G" "$(cat "$CONFIG_DIR/mtd9400.json")" "6400000000"
if python3 - "$CONFIG_DIR/sdm8elite.json" <<'PY'
import json, sys
c = json.load(open(sys.argv[1], encoding='utf-8'))
s = c['modules']['sched']
assert s['enable'] is True
assert s['cpumask']['c0'] == [0, 1]
assert s['cpumask']['c1'] == [2, 3, 4, 5]
assert s['cpumask']['c2'] == [6, 7]
assert all(s['affinity']['bg'][k] == 'c0' for k in ('bg', 'fg', 'idle', 'touch', 'boost'))
assert c['initials']['sysfs']['cpusetBg'] == '0-1'
assert c['initials']['sysfs']['cpusetSysBg'] == '0-1'
PY
then ok "8 Elite 低分组派活与三档簇掩码正确"; else bad "8 Elite 低分组配置不符合预期"; fi

printf '\n== v1.6.0 MTK Mali GPU 分模式窗口 ==\n'
MALI="$FAKE/sys/class/devfreq/mali"
mkdir -p "$MALI"
printf '%s\n' 300000000 > "$MALI/min_freq"
printf '%s\n' 1250000000 > "$MALI/max_freq"
printf '%s\n' '300000000 450000000 600000000 750000000 900000000 1050000000 1250000000' > "$MALI/available_frequencies"
printf '%s\n' 40 > "$MALI/upthreshold"
printf '%s\n' 10 > "$MALI/downdifferential"
printf '%s\n' 50 > "$MALI/polling_interval"
GP_RUN() { PATH="$FAKE/bin:$PATH" "$SH" "$FAKE/data/adb/modules/nanhe_ovo/script/gpu_profile.sh" "$1"; }
GP_RUN performance
eq "性能档选择不超过 75% 目标的真实 OPP" "900000000" "$(cat "$MALI/min_freq")"
eq "性能档不压低 GPU 上限" "1250000000" "$(cat "$MALI/max_freq")"
eq "性能档升压阈值" "85" "$(cat "$MALI/upthreshold")"
eq "性能档降频迟滞" "15" "$(cat "$MALI/downdifferential")"
eq "性能档采样周期" "32" "$(cat "$MALI/polling_interval")"
GP_RUN fast
eq "极速档选择真实高档下限" "1050000000" "$(cat "$MALI/min_freq")"
GP_RUN crazy
eq "超频档仍不超出真实 OPP 表" "1050000000" "$(cat "$MALI/min_freq")"
GP_RUN balance
eq "均衡档恢复开机 GPU 下限" "300000000" "$(cat "$MALI/min_freq")"
eq "均衡档恢复原升压阈值" "40" "$(cat "$MALI/upthreshold")"
eq "均衡档恢复原降频差值" "10" "$(cat "$MALI/downdifferential")"
eq "均衡档恢复原采样周期" "50" "$(cat "$MALI/polling_interval")"
GP_RUN invalid
eq "非法 GPU 模式静默跳过且不改动" "300000000" "$(cat "$MALI/min_freq")"
rm -f "$MALI/available_frequencies"
GP_RUN performance
eq "无 OPP 表时不构造频点" "300000000" "$(cat "$MALI/min_freq")"

printf '\n== 线程引擎（v1.7.0，AppOptR GPL-3.0）==\n'
[ -f "$MODULE/bin/appopt/AppOpt" ] && [ -s "$MODULE/bin/appopt/AppOpt" ] && ok "AppOpt 二进制已随模块分发" || bad "缺少 AppOpt 二进制"
[ -f "$MODULE/bin/appopt/AppOpt-ebpf" ] && ok "AppOpt-ebpf 已随模块分发" || bad "缺少 AppOpt-ebpf"
[ -f "$MODULE/appopt/LICENSE-GPL3.txt" ] && ok "GPL-3.0 许可证随包分发" || bad "缺少 GPL-3.0 许可证"
for p in powersave balance performance fast crazy; do
    [ -f "$MODULE/appopt/appopt_$p.conf" ] && ok "五档规则 $p 存在" || bad "缺少 appopt_$p.conf"
done
has "service.sh 拉起线程服务" "$(cat "$MODULE/service.sh")" "thread_svc.sh"
has "service.sh 拉起前台动态调度" "$(cat "$MODULE/service.sh")" "game_watch.sh"
has "service.sh 拉起温控闸门" "$(cat "$MODULE/service.sh")" "thermal_guard.sh"
has "ACE 跳过名单随包分发" "$(cat "$MODULE/thread_skip.list")" "com.tencent.tmgp.dfm"
has "uninstall.sh 清理线程引擎" "$(cat "$MODULE/uninstall.sh")" "/dev/cpuset/nanhe_opt"
has "NOTICE 标注 AppOptR 出处" "$(cat "$MODULE/NOTICE")" "gitee.com/sutoliu/AppOptR"

THR="$RR/thread"
: > "$FAKE/appopt.running"
run_ctl status
eq "线程引擎默认运行中（开机服务拉起）" "运行中" "$(printf '%s\n' "$OUT" | awk -F'\t' '$2=="thread"{print $3}')"
eq "线程开关默认 on" "on" "$(printf '%s\n' "$OUT" | awk -F'\t' '$2=="thread_manage"{print $3}')"
eq "线程档位随当前模式" "balance" "$(printf '%s\n' "$OUT" | awk -F'\t' '$2=="thread_profile"{print $3}')"
rm -f "$FAKE/appopt.running"

rm -f "$FAKE/appopt.invoked"
run_ctl thread on
eq "开启线程引擎退出 0" "$RC" 0
eq "开启返回 ok" "ok	thread	on" "$OUT"
eq "开启后无禁用标记" "no" "$([ -f "$RR/thread_disabled" ] && echo yes || echo no)"
eq "active.conf 已生成" "yes" "$([ -f "$THR/active.conf" ] && echo yes || echo no)"
has "档位规则并入 active.conf" "$(cat "$THR/active.conf")" "surfaceflinger=0-3,4-7"
hasnt "active.conf 不再残留语义核名" "$(cat "$THR/active.conf")" "=hp-core"
hasnt "active.conf 不再残留 e-core" "$(cat "$THR/active.conf")" "=e-core"
hasnt "active.conf 不再残留 hp2-core" "$(cat "$THR/active.conf")" "=hp2-core"
run_ctl mode fast
has "fast 主线程展开为双大核" "$(cat "$THR/active.conf")" "UnityMain=6-7"
has "fast 渲染线程展开为双大核" "$(cat "$THR/active.conf")" "RenderThread*=6-7"
run_ctl mode balance
i=0
while [ ! -s "$FAKE/appopt.invoked" ] && [ "$i" -lt 20 ]; do i=$((i + 1)); sleep 0.1; done
has "AppOpt 已被拉起" "$(cat "$FAKE/appopt.invoked" 2>/dev/null)" "-b nanhe_opt"
has "AppOpt 参数指向 active.conf" "$(cat "$FAKE/appopt.invoked" 2>/dev/null)" "-c $THR/active.conf"
run_ctl thread maybe
[ "$RC" != 0 ] && ok "非法线程开关参数被拒绝" || bad "非法参数被接受"

printf '\n== 线程规则（单应用绑定）==\n'
run_ctl threadrule com.example.game game
eq "绑定游戏预设退出 0" "$RC" 0
eq "绑定返回 ok" "ok	threadrule	com.example.game	game" "$OUT"
has "块头标记已写入" "$(cat "$THR/user.conf")" "# nanhe_threadrule pkg=com.example.game preset=game"
has "游戏主线程落在最高频核" "$(cat "$THR/user.conf")" "UnityMain=6-7"
has "渲染线程落在大簇" "$(cat "$THR/user.conf")" "RenderThread*=4-7"
has "worker 线程跨低簇与大簇" "$(cat "$THR/user.conf")" "Thread-*=0-3,4-7"
hasnt "user.conf 不残留语义核名" "$(cat "$THR/user.conf")" "hp-core"
eq "游戏预设无空掩码" "no" "$(grep -q '={\|= *{\|=$' "$THR/user.conf" && echo yes || echo no)"
has "规则已并入 active.conf" "$(cat "$THR/active.conf")" "nanhe_threadrule pkg=com.example.game"
run_ctl threadrules
eq "threadrules 退出 0" "$RC" 0
has "threadrules 返回块头" "$OUT" "# nanhe_threadrule pkg=com.example.game preset=game"
run_ctl threadrule com.example.game ui
eq "同一包更新预设" "$(grep -c 'nanhe_threadrule pkg=com.example.game' "$THR/user.conf")" 1
has "预设已更新为 ui" "$(cat "$THR/user.conf")" "preset=ui"
run_ctl threadrule com.example.game delete
eq "解除绑定退出 0" "$RC" 0
hasnt "块头已删除" "$(cat "$THR/user.conf")" "com.example.game"
hasnt "active.conf 同步删除" "$(cat "$THR/active.conf")" "nanhe_threadrule pkg=com.example.game"
run_ctl threadrule 'bad pkg' game
[ "$RC" != 0 ] && ok "非法包名被拒绝" || bad "非法包名被接受"
run_ctl threadrule com.example.game turbo
[ "$RC" != 0 ] && ok "非法预设被拒绝" || bad "非法预设被接受"
rm -f "$THR/user.conf"
ln -s /tmp/not-here "$THR/user.conf"
run_ctl threadrule com.example.game bg
[ "$RC" != 0 ] && ok "user.conf 为符号链接时拒绝" || bad "符号链接未被拒绝"
rm -f "$THR/user.conf"
run_ctl threadrules
eq "线程规则文件不存在时退出 0" "$RC" 0
eq "空线程规则输出为空" "" "$OUT"

printf '\n== ACE 游戏跳过线程绑定 ==\n'
run_ctl threadrule com.tencent.tmgp.dfm game
eq "三角洲绑定返回成功" "$RC" 0
has "三角洲返回 skipped" "$OUT" "ok	threadrule	com.tencent.tmgp.dfm	game	skipped"
has "三角洲提示 ACE 原因" "$ERR" "ACE 反作弊"
hasnt "三角洲未写入 user.conf" "$(cat "$THR/user.conf" 2>/dev/null)" "com.tencent.tmgp.dfm"
hasnt "三角洲未写入 active.conf" "$(cat "$THR/active.conf" 2>/dev/null)" "com.tencent.tmgp.dfm"
run_ctl threadrule com.tencent.tmgp.dfm delete
eq "三角洲删除规则成功" "$RC" 0
has "删除返回 ok" "$OUT" "ok	threadrule	com.tencent.tmgp.dfm	delete"

printf '\n== 拓扑展开（空掩码回归）==\n'
topo_case() { # $1=名称 $2="freq:cpus" 列表 $3=期望 "ALL|BG|REND|MAIN|SPIRE"
    TT="$FAKE/topo-$1"
    rm -rf "$TT"; mkdir -p "$TT/sys/devices/system/cpu/cpufreq"
    _n=0
    for _c in $2; do
        _p="$TT/sys/devices/system/cpu/cpufreq/policy$_n"
        mkdir -p "$_p"
        printf '%s\n' "${_c#*:}" | tr ',' ' ' > "$_p/related_cpus"
        printf '%s\n' "${_c%%:*}" > "$_p/cpuinfo_max_freq"
        _n=$((_n + 1))
    done
    printf '%s\n' '0-7' > "$TT/sys/devices/system/cpu/present"
    sed "s#/sys/#$TT/sys/#g" "$MODULE/script/libtopo.sh" > "$TT/libtopo.sh"
    _res=$( TOPO_FILE="$TT/topo.txt"; . "$TT/libtopo.sh"; topo_init
        printf '%s|%s|%s|%s|%s\n' "$TOPO_ALL" "$TOPO_BG" "$TOPO_REND" "$TOPO_MAIN" "$TOPO_SPIRE" )
    eq "拓扑 $1 展开结果" "$3" "$_res"
}
# 4+4：渲染给高簇，主线程最后一颗，后台低簇
topo_case 4p4 '1800000:0,1,2,3 2800000:4,5,6,7' '0-7|0-3|4-7|7|0'
# 2+6（骁龙 8 Elite）：2 颗 Prime + 6 颗性能核，渲染不能只给 Prime
topo_case 2p6 '2000000:0,1 3500000:2,3,4,5,6,7' '0-7|0-1|2-7|7|0'
# 单簇（8 颗同频）：全部核心都在同一组，不能出现空集
topo_case 1c '3000000:0,1,2,3,4,5,6,7' '0-7|0-3|0-7|0-7|0'
# 1+3+4 三簇：渲染取中间簇
topo_case 1p3p4 '1800000:0 2400000:1,2,3 3200000:4,5,6,7' '0-7|0|1-3|7|0'
# 2+4+2：高簇只有 2 颗，标记为尖顶族（渲染改走中间簇）
topo_case 2p4p2 '1800000:0,1 2400000:2,3,4,5 3200000:6,7' '0-7|0-1|2-5|7|1'

printf '\n== crazy 档保核与线程档位联动 ==\n'
run_ctl mode crazy
eq "进入 crazy 后默认不保核（min_cpus 保持基线）" "$(cat "$FAKE/sys/devices/system/cpu/cpu0/core_ctl/min_cpus")" "4"
eq "保核基线未写入（默认关闭）" "no" "$([ -f "$RR/corectl.aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee.tsv" ] && echo yes || echo no)"
run_ctl status
eq "线程档位随超频档切换" "crazy" "$(printf '%s\n' "$OUT" | awk -F'\t' '$2=="thread_profile"{print $3}')"
has "超频档渲染线程固定大核" "$(cat "$THR/active.conf")" "RenderThread*=7"
run_ctl mode balance
eq "退出 crazy 后恢复基线 min_cpus" "$(cat "$FAKE/sys/devices/system/cpu/cpu0/core_ctl/min_cpus")" "4"
run_ctl status
eq "线程档位随退出恢复 balance" "balance" "$(printf '%s\n' "$OUT" | awk -F'\t' '$2=="thread_profile"{print $3}')"

printf '\n== 线程总开关 ==\n'
run_ctl thread off
eq "关闭线程引擎退出 0" "$RC" 0
eq "禁用标记已写入" "yes" "$([ -f "$RR/thread_disabled" ] && echo yes || echo no)"
run_ctl status
eq "关闭后状态为已关闭" "已关闭" "$(printf '%s\n' "$OUT" | awk -F'\t' '$2=="thread"{print $3}')"
eq "关闭后开关为 off" "off" "$(printf '%s\n' "$OUT" | awk -F'\t' '$2=="thread_manage"{print $3}')"
run_ctl thread on
eq "重新开启退出 0" "$RC" 0
eq "重新开启后无禁用标记" "no" "$([ -f "$RR/thread_disabled" ] && echo yes || echo no)"
: > "$FAKE/appopt.running"
run_ctl status
eq "重新开启后状态恢复运行中" "$(printf '%s\n' "$OUT" | awk -F'\t' '$2=="thread"{print $3}')" "运行中"
rm -f "$FAKE/appopt.running"

########################################
# 汇总
########################################
printf '\n'
if [ "$F" = 0 ]; then echo "RESULT: 全部通过"; else echo "RESULT: 存在失败项"; fi
exit "$F"