#!/system/bin/sh
# 开机服务：等待系统启动完成并解锁后应用 CPU 策略。
# 启动骨架沿用 Uperf-Game-Turbo（Apache-2.0），v1.11.0 起不再启动 uperf 二进制。

MODDIR=${0%/*}

sh "$MODDIR/script/initsvc.sh"

# 解锁后应用屏幕刷新率：抵消部分机型开机锁 60Hz 与静止回落
sh "$MODDIR/script/refresh_apply.sh"

# 线程调度引擎：AppOptR（SutoLiu，GPL-3.0，https://gitee.com/sutoliu/AppOptR）
sh "$MODDIR/script/thread_svc.sh"

# 前台感知：游戏进前台 fast，退出 balance，灭屏 powersave；同时启动平滑温控闸门。
sh "$MODDIR/script/game_watch.sh" start
sh "$MODDIR/script/thermal_guard.sh" start
