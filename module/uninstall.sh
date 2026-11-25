#!/system/bin/sh
# 卸载清理：保留用户的分应用规则，移除本模块生成的运行时数据与便携入口。
# 结构沿用 Uperf-Game-Turbo（Apache-2.0）。

USER_PATH=/sdcard/Android/yc/uperf
MODDIR=$(cd "$(dirname "$0")" 2>/dev/null && pwd)

wait_until_login() {
    while [ "$(getprop sys.boot_completed 2>/dev/null)" != "1" ]; do
        sleep 1
    done
    local test_file="/sdcard/Android/.PERMISSION_TEST"
    true >"$test_file" 2>/dev/null
    while [ ! -f "$test_file" ]; do
        true >"$test_file" 2>/dev/null
        sleep 1
    done
    rm -f "$test_file"
}

on_remove() {
    wait_until_login

    # 分应用规则是用户资产：先备份到 /sdcard，再重建目录
    if [ -f "$USER_PATH/perapp_powermode.txt" ]; then
        cp -f "$USER_PATH/perapp_powermode.txt" /sdcard/nanhe_ovo-perapp_powermode.txt 2>/dev/null
    fi
    rm -rf "$USER_PATH"
    mkdir -p "$USER_PATH" 2>/dev/null
    if [ -f /sdcard/nanhe_ovo-perapp_powermode.txt ]; then
        mv -f /sdcard/nanhe_ovo-perapp_powermode.txt "$USER_PATH/perapp_powermode.txt" 2>/dev/null
    fi

    # 只删除本模块写入的便携入口
    for f in /data/powercfg.sh /data/powercfg-base.sh; do
        if [ -f "$f" ] && grep -q 'nanhe_ovo' "$f" 2>/dev/null; then
            rm -f "$f"
        fi
    done

    # 还原本模块改动过的系统刷新率设置（原值在首次写入时记录）
    if [ -f /data/adb/nanhe_ovo/refresh_orig.txt ] && [ ! -L /data/adb/nanhe_ovo/refresh_orig.txt ]; then
        orig_peak=$(sed -n '1p' /data/adb/nanhe_ovo/refresh_orig.txt | awk -F "$(printf '\t')" '{print $1}')
        orig_min=$(sed -n '1p' /data/adb/nanhe_ovo/refresh_orig.txt | awk -F "$(printf '\t')" '{print $2}')
        case "$orig_peak" in
            ''|null) settings delete system peak_refresh_rate >/dev/null 2>&1 ;;
            *[!0-9.]*) ;;
            *) settings put system peak_refresh_rate "$orig_peak" >/dev/null 2>&1 ;;
        esac
        case "$orig_min" in
            ''|null) settings delete system min_refresh_rate >/dev/null 2>&1 ;;
            *[!0-9.]*) ;;
            *) settings put system min_refresh_rate "$orig_min" >/dev/null 2>&1 ;;
        esac
    fi

    # 停止前台动态调度与温控闸门，避免卸载后仍有子进程写节点
    [ -f "$MODDIR/script/game_watch.sh" ] && sh "$MODDIR/script/game_watch.sh" stop 2>/dev/null
    [ -f "$MODDIR/script/thermal_guard.sh" ] && sh "$MODDIR/script/thermal_guard.sh" stop 2>/dev/null

    # 停止线程引擎（AppOptR，GPL-3.0）并清理 cpuset 分组与运行时数据
    APPOpt_PID=$(pidof AppOpt 2>/dev/null)
    case "$APPOpt_PID" in ''|*[!0-9' ']*) ;; *) kill $APPOpt_PID 2>/dev/null;; esac
    if [ -d /dev/cpuset/nanhe_opt ]; then
        rmdir /dev/cpuset/nanhe_opt/* 2>/dev/null
        rmdir /dev/cpuset/nanhe_opt 2>/dev/null
    fi

    rm -rf /data/adb/nanhe_ovo
}

# 不阻塞开机流程
(on_remove &)
