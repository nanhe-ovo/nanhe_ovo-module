#!/system/bin/sh
# 线程引擎开机服务（引擎：AppOptR，作者 SutoLiu，GPL-3.0，https://gitee.com/sutoliu/AppOptR）
# 流程：用户开关关闭则直接退出；否则按当前性能模式生成 active.conf 并拉起守护进程。

MODDIR=$(cd "$(dirname "$0")/.." && pwd)
. "$MODDIR/script/libthread.sh"

[ ! -f "$THREAD_DISABLED" ] || exit 0

# service.sh 里 initsvc 已等过 sys.boot_completed 与解锁，这里只做兜底等待
i=0
while [ "$(getprop sys.boot_completed)" != "1" ] && [ "$i" -lt 10 ]; do
    i=$((i + 1))
    sleep 3
done

# 部分管理器解包会丢可执行位，运行前统一修复
chmod 0755 "$MODDIR/bin/appopt/AppOpt" "$MODDIR/bin/appopt/AppOpt-ebpf" 2>/dev/null

MODE=$(cat /sdcard/Android/yc/uperf/cur_powermode.txt 2>/dev/null)
case "$MODE" in ''|*[!a-z0-9_]*) MODE=balance;; esac

thread_gen_conf "$MODE"
thread_start
