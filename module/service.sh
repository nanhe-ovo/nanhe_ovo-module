#!/system/bin/sh
# 开机服务：等待系统启动完成并解锁后启动 uperf 引擎。
# 启动流程沿用 Uperf-Game-Turbo（Apache-2.0）。

MODDIR=${0%/*}

sh "$MODDIR/script/initsvc.sh"

# 解锁后应用屏幕刷新率：抵消部分机型开机锁 60Hz 与静止回落
sh "$MODDIR/script/refresh_apply.sh"
