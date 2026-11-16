#!/system/bin/sh
# 启动早期钩子：只做权限修复，不再写任何 disable 标记。
# 旧版曾在本阶段留 need_recuser 标记、下一次开机写 disable —— 那会在第二次开机把模块自己停掉，
# 与「模块运行后 SUSFS Guard 加载失败」的排查混在一起，属于必须去掉的副作用。

MODDIR=${0%/*}

# 解包时可能丢失可执行位：开机早期先补一次，避免 service.sh 阶段引擎起不来
chmod 0755 "$MODDIR/bin/uperf" "$MODDIR/bin/busybox/busybox" "$MODDIR"/script/*.sh 2>/dev/null

# 本模块不加载、不卸载任何内核模块，也不写 /proc/kallsyms / kptr_restrict / /proc/susfs_*：
# SUSFS Guard 之类 LKM 的加载窗口完全不受这里影响。
