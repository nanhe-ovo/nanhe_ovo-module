#!/system/bin/sh
#
# Copyright (C) 2021-2022 Matt Yang & yinwanxi
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distriywxuted on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

###############################
# Platform info functions
###############################

# $1:"4.14" return:string_in_version
match_linux_version() {
    echo "$(cat /proc/version | grep -i "$1")"
}

get_socid() {
    if [ -f /sys/devices/soc0/soc_id ]; then
        echo "$(cat /sys/devices/soc0/soc_id)"
    else
        echo "$(cat /sys/devices/system/soc/soc0/id)"
    fi
}

get_nr_core() {
    echo "$(cat /proc/stat | grep cpu[0-9] | wc -l)"
}

# $1:cpuid
get_maxfreq() {
    echo "$(cat "/sys/devices/system/cpu/cpu$1/cpufreq/cpuinfo_max_freq")"
}

get_socname() {
    echo "$(cat "/sys/devices/soc0/machine"| tr '[A-Z]' '[a-z]')"
}

is_aarch64() {
    if [ "$(getprop ro.product.cpu.abi)" == "arm64-v8a" ]; then
        echo "true"
    else
        echo "false"
    fi
}

is_eas() {
    if [ "$(grep sched /sys/devices/system/cpu/cpu0/cpufreq/scaling_available_governors)" != "" ]; then
        echo "true"
    else
        echo "false"
    fi
}

is_mtk() {
    if [ "$(getprop | grep ro.mtk)" != "" ]; then
        echo "true"
    else
        echo "false"
    fi
}

miui_check(){
if [ "$(printf '%s\n' "90" "$(getprop ro.miui.ui.version.name)" | sort -V | head -n1)" = "90" ]; then
  echo "true"
else
  echo "false"
fi
}

_get_sm6150_type() {
    case "$(get_socid)" in
    365 | 366) echo "sdm730" ;;
    355 | 369) echo "sdm675" ;;
    esac
}

_get_sdm76x_type() {
    if [ "$(get_maxfreq 7)" -gt 2300000 ]; then
        echo "sdm765"
    else
        echo "sdm750"
    fi
}

_get_lahaina_type() {
    if [ "$(get_maxfreq 7)" -gt 2600000 ]; then
        echo "sdm888"
    else
        if [ "$(get_maxfreq 4)" -gt 2300000 ]; then
            echo "sdm778"
        else
            echo "sdm780"
        fi
    fi
}

_get_taro_type() {
    if [ "$(get_socname)" == cape ] || [ "$(get_socname)" == capep ] || [ "$(get_socname)" == ukee ] || [ "$(get_socname)" == ukeep ]; then
        echo "sdm8g1+"
    else
        if [ "$(get_socname)" == waipio ] || [ "$(get_socname)" == waipiop ]; then
            echo "sdm8g1"
        else
            echo "sdm7g1"
        fi
    fi
}

_get_pinekala_type() {
    if [ "$(get_maxfreq 7)" -gt 3000000 ]; then
        echo "sdm8g3"
        else
        echo "sdm7+g3"
    fi
}

_get_kalama_type() {
    if [ "$(get_maxfreq 7)" -gt 3300000 ]; then
        echo "sdm8cxg2"
        else
        echo "sdm8g2"
    fi
}

_get_kona_type() {
    # kona 同时承载 865 / 865+ / 870；只有 870 的 ro.soc.model 带 AC 后缀。
    case "$(getprop ro.soc.model 2>/dev/null)" in
        SM8250-AC|SM8250AC|sm8250-ac) echo "sdm870" ;;
        *) echo "sdm865" ;;
    esac
}

_get_xring_type() {
    case "$(getprop ro.soc.model 2>/dev/null)" in
        *O3*|*o3*) echo "xring_o3" ;;
        *) echo "xring_o1" ;;
    esac
}

# $1:board_name
get_config_name() {    case "$1" in
    "pineapple") echo "$(_get_pinekala_type)" ;;
    "kalama") echo "$(_get_kalama_type)" ;;
    "taro") echo "$(_get_taro_type)" ;;
    "lahaina") echo "$(_get_lahaina_type)" ;;
    "shima") echo "$(_get_lahaina_type)" ;;
    "yupik") echo "sdm7g2p" ;;
    "sm7475") echo "sdm7g2p" ;;
    "sm7550") echo "sdm7g3" ;;  # Snapdragon 7 Gen 3
    "sun") echo "sdm8elite" ;;
    "sm8755") echo "sdm8elite" ;;
    "manila") echo "sdm8sgen3" ;;
    "sm8635") echo "sdm8sgen3" ;;
    "sm6450") echo "sdm6g1" ;;
    "kona") echo "$(_get_kona_type)" ;;
    "msmnile") echo "sdm855" ;; # 855, 860
    "sdm845") echo "sdm845" ;;
    "lito") echo "$(_get_sdm76x_type)" ;;
    "sm6150") echo "$(_get_sm6150_type)" ;;
    "holi") echo "sdm695" ;;
    "xring") echo "$(_get_xring_type)" ;;  # 玄戒 O1 / O3
    "sdm710") echo "sdm710" ;;
    "msm8939") echo "sdm616" ;;
    "msm8916") echo "sdm616" ;;
    "MSM8916") echo "sdm616" ;;
    "sky") echo "sdm4g2" ;;
    "parrot") echo "sdm4g2" ;;
    "msm8937") echo "sdm439" ;;
    "msm8953") echo "sdm625" ;;    # 625
    "msm8953pro") echo "sdm625" ;; # 626
    "msm8952Pro") echo "sdm653" ;; #653
    "msm8952") echo "sdm653" ;; #652
    "msm8976SG") echo "sdm653" ;; #653
    "sdm660") echo "sdm660" ;;
    "sdm636") echo "sdm660" ;;
    "trinket") echo "sdm665" ;; # sdm665
    "bengal") echo "sdm680" ;;  # sdm662
    "msm8956") echo "sdm653" ;;
    "msm8998") echo "sdm835" ;;
    "msm8996") echo "sdm820" ;;
    "msm8909") echo "sdm210" ;;
    "msm8996pro") echo "sdm820" ;;
    "s5e9925") echo "e2200" ;;
    "exynos2100") echo "e2100" ;;
    "erd8835") echo "e1380" ;;
    "universal9925") echo "e2200" ;;
    "exynos1080") echo "e1080" ;;
    "exynos990") echo "e990" ;;
    "universal1080") echo "e1080" ;;
    "universal1480") echo "e1480" ;;
    "universal1580") echo "e1580" ;;
    "universal2400") echo "e2400" ;;
    "s5e9955") echo "e2500" ;;  # Exynos 2500
    "s5e9965") echo "e2600" ;;  # Exynos 2600（型号待真机核对）
    "universal990") echo "e990" ;;
    "universal5420") echo "e5420" ;;
    "universal9825") echo "e9820" ;;
    "universal9820") echo "e9820" ;;
    "universal9810") echo "e9810" ;;
    "universal8895") echo "e8895" ;;
    "universal8890") echo "e8890" ;;
    "universal7420") echo "e7420" ;;
    "mt6580") echo "mt6580" ;;
    "mt6765") echo "mtp35" ;; # Helio P35(mt6765)/G35(mt6765g)/G37(mt6765h)
    "mt6768") echo "mtg80" ;; # Helio P65(mt6768)/G70(mt6769v)/G80(mt6769t)/G85(mt6769z)
    "mt6771") echo "mtp70" ;;
    "mt8175") echo "mt8173" ;;
    "mt6779") echo "mtp90" ;;
    "mt6789") echo "mtg99" ;;
    "mt6785") echo "mtg90t" ;;
    "Infinix-X6827") echo "mtg96" ;;
    "mt6827") echo "mtg96" ;;
    "mt6795") echo "mtx10" ;;
    "mt6797") echo "mtx20" ;;
    "mt6833") echo "mtd720" ;;
    "mt6833p") echo "mtd720" ;; # Dimensity 810
    "mt6833v") echo "mtd720" ;; # Dimensity 810
    "mt6835") echo "mtd6000" ;;
    "mt6853") echo "mtd720" ;;
    "mt6873") echo "mtd820" ;;
    "mt6875") echo "mtd820" ;;
    "mt6877") echo "mtd920" ;;
    "mt6855") echo "mtd930" ;;
    "cancunf") echo "mtd930" ;;
    "mt6885") echo "mtd1000" ;;
    "mt6886") echo "mtd7000" ;;
    "mt6889") echo "mtd1000" ;;
    "mt6891") echo "mtd1100" ;;
    "mt6893") echo "mtd1200" ;;
    "mt6895") echo "mtd8100" ;;
    "mt6897") echo "mtd8300" ;;
    "mt6983") echo "mtd9000" ;;
    "mt6985") echo "mtd9200" ;;
    "mt6989") echo "mtd9300" ;;
    "mt6899") echo "mtd8400" ;;
    "mt6991") echo "mtd9400" ;;
    "mt6993") echo "mtd9500s" ;;  # Dimensity 9500 / 9500s
    "mt6994") echo "mtd9600m" ;;   # Dimensity 9600M
    "mt6995") echo "mtd9600pro" ;; # Dimensity 9600 Pro（2+3+3）
    "mt6880") echo "mtd7300" ;;    # Dimensity 7300
    "gs101") echo "gs101" ;;
    "gs201") echo "gs201" ;;
    "cheetah") echo "gs201" ;;
    "husky") echo "gs301" ;;
    "zuma") echo "gs301" ;;
    "shiba") echo "gs301" ;;
    "comet") echo "gs401" ;;
    "gs501") echo "gs501" ;;   # Tensor G5
    "laguna") echo "gs501" ;;  # Tensor G5 平台代号
    "PRL") echo "kirin65x" ;;
    "BLN") echo "kirin65x" ;;
    "hi6250") echo "kirin65x" ;;
    "kirin655") echo "kirin65x" ;;
    "kirin658") echo "kirin65x" ;;
    "kirin659") echo "kirin65x" ;;
    "MAR") echo "kirin710" ;;
    "INE") echo "kirin710" ;;
    "ANE") echo "kirin710" ;;
    "JSN") echo "kirin710" ;;
    "kirin710") echo "kirin710" ;;
    "JKM-AL20") echo "kirin710" ;;
    "STF") echo "kirin960" ;;
    "HWI") echo "kirin960" ;;
    "kirin960") echo "kirin960" ;;
    "hi3660") echo "kirin960" ;;
    "CMR") echo "kirin960" ;;
    "BKL") echo "kirin970" ;;
    "ALP") echo "kirin970" ;;
    "COR") echo "kirin970" ;;
    "kirin970") echo "kirin970" ;;
    "ELE") echo "kirin980" ;;
    "kirin980") echo "kirin980" ;;
    "kirin990") echo "kirin990" ;;
    "LIO-AL00") echo "kirin990" ;;
    "OXP-AN00") echo "kirin990" ;;
    "ANA-AN00") echo "kirin990" ;;
    "ELS-AN10") echo "kirin990" ;;
    "EBG-AN00") echo "kirin990" ;;
    "TAS-AN00") echo "kirin990" ;;
    "LIO-AN00P") echo "kirin990" ;;
    "OXF-AN00") echo "kirin990" ;;
    "OCE-AL50") echo "kirin990" ;;
    "SCMR-W09") echo "kirin990" ;;
    "TAH-AN00m") echo "kirin990" ;;
    "kirin9000") echo "kirin9000" ;;
    "JAD") echo "kirin9000" ;;
    "kirin9000s") echo "kirin9000s" ;;
    "kirin9010") echo "kirin9010" ;;
    "kirin9020") echo "kirin9020" ;;
    "kirin9030") echo "kirin9030" ;;
    "kirin9050") echo "kirin9050" ;;
    "hi3650") echo "kirin955" ;;
    "FRD") echo "kirin955" ;;
    "EVA-TL00") echo "kirin955" ;;
    "kirin955") echo "kirin955" ;;
    "sp9863a") echo "sp9863" ;;
    "ums312") echo "t310" ;;
    "ums9230") echo "t606" ;;
    "ums512") echo "t618" ;;
    "ud710") echo "t710" ;;
    "ums9620") echo "t770" ;;
    "sp9832e") echo "sp9832" ;;
    "ums312_2h10") echo "t310" ;;
    "ums9230_1h10") echo "t606" ;;
    "ums512_1h10") echo "t618" ;;
    "ud710_7h10") echo "t710" ;;
    "ums9620_2h10") echo "t770" ;;
    "sp9832e_1h10") echo "sp9832" ;;
    "sp9863a_1h10") echo "sp9863" ;;
    *) echo "unsupported" ;;
    esac
}

# $1: ro.soc.model；按型号精确映射，绕开伪装机型或平台属性缺失
get_config_name_by_model() {
    _bm=$(printf '%s' "$1" | tr 'a-z' 'A-Z')
    case "$_bm" in
        SM8250-AC|SM8250AC) echo sdm870 ;;
        SM8250) echo sdm865 ;;
        SM7475*) echo sdm7g2p ;;
        SM7550) echo sdm7g3 ;;
        SM7675*) echo sdm7+g3 ;;
        S5E9955) echo e2500 ;;
        S5E9965) echo e2600 ;;
        MT6993*) echo mtd9500s ;;
        MT6994*) echo mtd9600m ;;
        MT6995*) echo mtd9600pro ;;
        MT6991*) echo mtd9400 ;;
        MT6989*) echo mtd9300 ;;
        MT6880*) echo mtd7300 ;;
        GS501*|LAGUNA*) echo gs501 ;;
        XRING*O3*) echo xring_o3 ;;
        XRING*) echo xring_o1 ;;
        *) echo unsupported ;;
    esac
}

# 配置里 cpumask.all 的核数（超线程平台用它兜底比对）
config_cpumask_nr() {
    awk '/"all": \[/ { gsub(/[^0-9,]/,""); n = split($0, a, ","); print n; exit }' "$1" 2>/dev/null
}

#############################################################
# 拓扑指纹（用于伪装机型场景）
#############################################################

# 实际核数：按 /sys/devices/system/cpu/present 统计
topo_nr_core() {
    _tn=$(cat /sys/devices/system/cpu/present 2>/dev/null)
    printf '%s\n' "$_tn" | awk -F, '{n=0; for(i=1;i<=NF;i++){if($i ~ /-/){split($i,a,"-"); n+=a[2]-a[1]+1} else n++}} END{print n+0}'
}

# 所有 policy 的最高频（kHz）
topo_max_freq() {
    _tm=
    for _td in /sys/devices/system/cpu/cpufreq/policy*; do
        [ -d "$_td" ] || continue
        _tf=$(cat "$_td/cpuinfo_max_freq" 2>/dev/null)
        case "$_tf" in ''|*[!0-9]*) continue;; esac
        if [ -z "$_tm" ] || [ "$_tf" -gt "$_tm" ]; then _tm=$_tf; fi
    done
    printf '%s' "${_tm:-0}"
}

# 配置文件的核数（powerModel 的 nr 之和）
config_nr() {
    awk -F': *' '/"nr"/ {gsub(/[^0-9].*/,"",$2); s+=$2} END{print s+0}' "$1" 2>/dev/null
}

# 配置文件的最高 typicalFreq（GHz → kHz）
config_top_freq() {
    awk -F': *' '/"typicalFreq"/ {
        gsub(/[^0-9.].*/,"",$2); if($2+0>m)m=$2+0
    } END{printf "%d", m*1000000}' "$1" 2>/dev/null
}

# 实测各簇最高频（kHz，升序，空格分隔）；control.sh 有 set -f，不能用 glob
topo_freq_list() {
    _ti=0
    while [ "$_ti" -lt 32 ]; do
        _td="/sys/devices/system/cpu/cpufreq/policy$_ti"
        _ti=$((_ti + 1))
        [ -d "$_td" ] || continue
        _tf=$(cat "$_td/cpuinfo_max_freq" 2>/dev/null)
        case "$_tf" in ''|*[!0-9]*) continue;; esac
        printf '%s\n' "$_tf"
    done | sort -n | tr '\n' ' '
}

# 配置文件的各簇典型频率（kHz，升序，空格分隔）
config_freq_list() {
    awk -F': *' '/"typicalFreq"/ {
        gsub(/[^0-9.].*/,"",$2); if ($2 + 0 > 0) printf "%d\n", $2 * 1000000
    }' "$1" 2>/dev/null | sort -n | tr '\n' ' '
}

# 两组频率向量的距离（kHz 差绝对值之和，簇数不同加惩罚）
freq_dist() {
    awk -v a="$1" -v b="$2" 'BEGIN {
        na = split(a, x, " "); nb = split(b, y, " ")
        if (na == 0 || nb == 0) { print 2000000000; exit }
        m = (na < nb ? na : nb); s = 0
        for (i = 1; i <= m; i++) s += (x[i] + 0 > y[i] + 0 ? x[i] - y[i] : y[i] - x[i])
        s += (na > nb ? na - nb : nb - na) * 1000000
        print s
    }'
}

# 校验属性选中的配置是否与真实拓扑相符；不符返回 1
# $1: 配置名  $2: 配置目录
topo_config_ok() {
    _oc="$2/$1.json"
    [ -f "$_oc" ] || return 1
    _on=$(topo_nr_core); _om=$(topo_max_freq)
    _cn=$(config_nr "$_oc")
    _ca=$(config_cpumask_nr "$_oc")
    [ "$_cn" -gt 0 ] || return 1
    # 普通平台按 powerModel 核数；超线程平台（powerModel 按物理核）按 cpumask 逻辑核
    [ "$_on" -eq "$_cn" ] || [ "$_on" -eq "$_ca" ] || return 1
    [ "$_om" -gt 0 ] || return 1
    _ol=$(topo_freq_list); _cl=$(config_freq_list "$_oc")
    _nsp=$(printf '%s' "$_ol" | wc -w | tr -d ' ')
    [ "$_nsp" -gt 0 ] || return 1
    _od=$(freq_dist "$_ol" "$_cl")
    # 逐簇频率差的平均值不超过 20% 才算同一平台
    [ $(( _od * 100 )) -le $(( _om * 20 * _nsp )) ] || return 1
    return 0
}

# 按真实拓扑挑距离最小的同核数配置；无候选时输出空
# $1: 配置目录
topo_pick_config() {
    _pn=$(topo_nr_core)
    _pl=$(topo_freq_list)
    _pbest= _pscore=
    for _pf in "$1"/*.json; do
        [ -f "$_pf" ] || continue
        _pcn=$(config_nr "$_pf")
        [ "$_pcn" -gt 0 ] || continue
        [ "$_pcn" -eq "$_pn" ] || continue
        _pdf=$(freq_dist "$_pl" "$(config_freq_list "$_pf")")
        if [ -z "$_pscore" ] || [ "$_pdf" -lt "$_pscore" ]; then
            _pbest=$_pf
            _pscore=$_pdf
        fi
    done
    [ -n "$_pbest" ] && basename "$_pbest" .json
}

###############################
# SUSFS compatibility probe
###############################
# SUSFS / SUSFS Guard 是否已加载。只读探测，不写任何节点。
# 用途：SUSFS 依赖 mount namespace 隐藏路径；本模块在 SUSFS 环境下必须避开
# bind mount / umount / chmod 000 这类挂载与权限改写，否则会让 LKM 注入或隐藏失效。
susfs_active() {
    [ -e /proc/susfs_path ] && return 0
    [ -d /sys/module/susfs_guard_lkm ] && return 0
    [ -d /sys/module/susfs4ksu ] && return 0
    [ -d /sys/module/ksu_susfs ] && return 0
    [ -d /sys/module/susfs ] && return 0
    return 1
}
