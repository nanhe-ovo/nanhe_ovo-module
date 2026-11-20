#!/system/bin/sh
# CPU 拓扑探测与线程角色展开（南何ovo）
# 只读探测，不写任何 sysfs 节点。
#
# 背景：线程引擎 AppOptR 按「频率分组」判核：首组 e-core、末组 hp-core、中间 p-core。
# 这在 2 簇（4+4 / 2+6）与单簇（8 颗同频）平台上会让 p-core 或 hp-core 变成空集；
# 空集会一路传到 cpuset 目录名，把基础 cpuset 的 cpus 写成空，游戏线程被塞进无 CPU
# 的 cgroup，表现为启动即卡死/闪退。因此本库在生成规则前先把语义核翻译成确定的数字掩码。
#
# 对外变量（topo_init 之后可用）：
#   TOPO_ALL   全部存在核心
#   TOPO_BG    最低频簇（后台/音频/IO），最多 4 颗
#   TOPO_REND  渲染组：尖顶族(>=3簇)取中间簇；2 簇取最高频簇；1 簇取全部
#   TOPO_MAIN  主线程：最高频簇的最后一颗；1 簇取全部

TOPO_FILE=${TOPO_FILE:-/data/adb/nanhe_ovo/topo.txt}

# 读 policy 的 related_cpus 与 cpuinfo_max_freq，按频率升序输出 "freq<TAB>cpus"
# 注意：control.sh 全局 set -f，这里不能用 glob，只能按编号逐个探测。
topo_scan_raw() {
    _ti=0
    while [ "$_ti" -lt 32 ]; do
        _d="/sys/devices/system/cpu/cpufreq/policy$_ti"
        _ti=$((_ti + 1))
        [ -d "$_d" ] || continue
        _f=$(cat "$_d/cpuinfo_max_freq" 2>/dev/null)
        _c=$(cat "$_d/related_cpus" 2>/dev/null)
        case "$_f" in ''|*[!0-9]*) continue;; esac
        [ -n "$_c" ] || continue
        printf '%s\t%s\n' "$_f" "$_c"
    done
}

# present 列表兜底：0-7 这类范围串可直接作为掩码
topo_present() {
    _p=$(cat /sys/devices/system/cpu/present 2>/dev/null)
    case "$_p" in ''|*[!0-9,-]*) _p=0-7;; esac
    printf '%s' "$_p"
}

topo_init() {
    TOPO_ALL=$(topo_present)
    TOPO_BG=$TOPO_ALL
    TOPO_REND=$TOPO_ALL
    TOPO_MAIN=$TOPO_ALL

    _tf=${TOPO_FILE%/*}
    mkdir -p "$_tf" 2>/dev/null
    topo_scan_raw | sort -n > "$TOPO_FILE" 2>/dev/null
    [ -s "$TOPO_FILE" ] || return 0

    eval "$(awk -v all="$TOPO_ALL" '
        function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
        function rng(s,   n,a,i,k,out,first,lo,hi,cur,t) {
            n = split(s, a, " ")
            for (i = 1; i <= n; i++)
                for (k = i + 1; k <= n; k++)
                    if (a[k] + 0 < a[i] + 0) { t = a[i]; a[i] = a[k]; a[k] = t }
            out = ""; first = 1; lo = -1; hi = -1
            for (i = 1; i <= n; i++) {
                cur = a[i] + 0
                if (lo < 0) { lo = cur; hi = cur }
                else if (cur == hi + 1) { hi = cur }
                else { out = out (first ? "" : ",") lo (hi > lo ? "-" hi : ""); first = 0; lo = cur; hi = cur }
            }
            if (lo >= 0) out = out (first ? "" : ",") lo (hi > lo ? "-" hi : "")
            return out
        }
        function firstn(s, k,   n,a,i,out,cnt) {
            n = split(s, a, " "); out = ""; cnt = 0
            for (i = 1; i <= n && cnt < k; i++) { out = out (cnt ? " " : "") a[i]; cnt++ }
            return out
        }
        function lastone(s,   n,a,i,m) {
            n = split(s, a, " "); m = -1
            for (i = 1; i <= n; i++) if (a[i] + 0 > m) m = a[i] + 0
            return m ""
        }
        # 取簇内最后 k 颗（related_cpus 按编号升序），返回逗号串
        function lastn(s, k,   n,a,i,out,cnt) {
            n = split(s, a, " "); out = ""; cnt = 0
            for (i = n; i >= 1 && cnt < k; i--) { out = a[i] (out == "" ? "" : " ") out; cnt++ }
            return out
        }
        {
            n++
            freq[n] = $1 + 0
            cpus[n] = ""
            for (i = 2; i <= NF; i++) cpus[n] = cpus[n] (i > 2 ? " " : "") $i
        }
        END {
            if (n == 0) {
                print "TOPO_BG=" all; print "TOPO_REND=" all; print "TOPO_MAIN=" all
                print "TOPO_MAIN2=" all; print "TOPO_GAME=" all
                exit
            }
            low = cpus[1]; high = cpus[n]
            nlow = split(low, la, " "); nhigh = split(high, ha, " ")
            if (n == 1) { rend = all }
            else if (n == 2) { rend = (nlow > nhigh) ? low : high }
            else {
                mid = ""
                for (i = 2; i < n; i++) mid = mid (mid == "" ? "" : " ") cpus[i]
                rend = mid
            }
            game = ""
            for (i = 1; i < n; i++) game = game (game == "" ? "" : " ") cpus[i]
            print "TOPO_BG=" rng(firstn(low, 4))
            if (n == 1) { print "TOPO_REND=" all; print "TOPO_MAIN=" all }
            else { print "TOPO_REND=" rng(rend); print "TOPO_MAIN=" rng(lastone(high)) }
            # 游戏主线程：最高簇最后两颗；最高簇只有一颗时补上一簇最后一颗（避免单核跑满）
            if (n == 1) { print "TOPO_MAIN2=" all }
            else if (nhigh >= 2) { print "TOPO_MAIN2=" rng(lastn(high, 2)) }
            else { print "TOPO_MAIN2=" rng(lastn(high, 1) " " lastone(cpus[n - 1])) }
            # 游戏包级 cpuset：排除最高频簇（超大核），其余核心给全部游戏线程
            print "TOPO_GAME=" rng(game == "" ? all : game)
            print "TOPO_SPIRE=" ((n >= 2 && nhigh <= 2) ? 1 : 0)
        }' "$TOPO_FILE")"
    return 0
}

# 语义核 → 数字掩码；未识别原样返回
topo_role() {
    case "$1" in
        e-core)   printf '%s' "${TOPO_BG:-0-7}" ;;
        p-core)   printf '%s' "${TOPO_REND:-0-7}" ;;
        hp-core)  printf '%s' "${TOPO_MAIN:-0-7}" ;;
        all-core) printf '%s' "${TOPO_ALL:-0-7}" ;;
        *)        printf '%s' "$1" ;;
    esac
}

# 把一行 "left=spec[ {]" 的 spec 展开为数字；空结果回退 all-core。
# 用法：topo_expand_line "包名=p-core,hp-core {" "描述"；
# 实则由 topo_expand_stream 批量处理，单行逻辑内联在 awk 中。
