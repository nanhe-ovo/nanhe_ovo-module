# 2020 后安卓移动端 SOC 线程调度方案（AppOptR 语义版）

> 版本：2026-11-19 推测稿。仅分析与方案设计，未写入任何模块。
> 依据：`gitee.com/sutoliu/AppOptR` 源码分析（拓扑三档检测、语义核、OR 合并、cpuset 子组、proc/eBPF 双模式）+ 已收集的 2020–2026 SOC 参数目录。
> 编号假设：CPU 编号按 cpufreq policy 升序（policy0=最低频簇），真机以 `related_cpus` 实测为准。

---

## 1. 方案原则（来自 AppOptR 源码语义）

1. **三档语义核**：AppOptR 按 `cpuinfo_max_freq` 升序分组——首组 `e-core`、末组 `hp-core`、中间合并 `p-core`。规则文件写语义名，跨平台不用改数字。
2. **OR 合并匹配**：命中同一包的线程规则会合并（并集）；无线程命中才走包级默认。因此**禁止重复包级规则**（Chase 配置里 12 组冲突规则在新语义下会并成 `0-7` 失效）。
3. **未命中线程走包级默认**：有线程规则的包必须写一条包级默认，否则未命中的线程会被放开到全部核心，去抢大核。
4. **位置与优先级分离**：只做亲和性，不改 nice/频率（与 AppOptR 一致）；优先级和调频交给 uperf 层。
5. **校验**：`cat /proc/<pid>/task/<tid>/status | grep Cpus_allowed_list`。

---

## 2. 通用规则模板（按拓扑族替换语义即可）

### 2.1 三簇标准族（4+3+1 / 3+4+1 / 1+3+4 / 4+2+2）

```text
# 游戏默认放在中核群，主线程独占大核
<game>=p-core
<game>{UnityMain}=hp-core
<game>{GameThread}=hp-core
<game>{UEGameThread}=hp-core
<game>{UnityGfxDeviceW}=p-core
<game>{RenderThread*}=p-core
<game>{RHIThread}=p-core
<game>{Thread-*}=p-core
<game>{Job.worker*}=p-core
<game>{FAsyncLoading}=e-core,p-core
<game>{AsyncReadManage}=e-core,p-core
<game>{binder:*}=p-core
<game>{NativeThread}=p-core
<game>{AudioTrack}=e-core
```

### 2.2 双簇族（6+2 / 4+4，无 p-core）

```text
<game>=e-core                     # 低频簇承担默认负载
<game>{UnityMain}=hp-core         # 大核给主线程
<game>{UnityGfxDeviceW}=hp-core   # 渲染与主线程共大核
<game>{RenderThread*}=hp-core
<game>{FAsyncLoading}=e-core
<game>{AudioTrack}=e-core
```

旗舰全大核 4+4（天玑 9300）例外：默认应用数字 `4-6`（大核群），主线程 `7`。

### 2.3 双簇 2+6（骁龙 8 Elite / 8E6，无小核）

```text
<game>=e-core                     # e-core 实际是 6 颗 Perf 大核
<game>{UnityMain}=hp-core         # 双 Prime 都给主线程
<game>{UnityGfxDeviceW}=e-core
<game>{RenderThread*}=e-core
<game>{FAsyncLoading}=e-core
<game>{AudioTrack}=e-core
```

### 2.4 单簇（天玑 8500，8×A725 同频）

语义核全部退化为单组（hp-core 为空集，写 hp-core 的规则会被解析跳过），**主线程必须用数字**：

```text
<game>=0-7
<game>{UnityMain}=7
<game>{UnityGfxDeviceW}=4-6
<game>{RenderThread*}=4-6
<game>{FAsyncLoading}=0-7
```

### 2.5 四档模式变体（按需切换）

| 角色 | 省电 | 均衡 | 性能 | 超频 |
| --- | --- | --- | --- | --- |
| 包级默认 | p-core | p-core | p-core,hp-core | 数字掩码（除主核外的中/大核） |
| MAIN | hp-core | hp-core | hp-core | hp-core 单核独占 |
| RENDER/WORKER | p-core | p-core | p-core,hp-core | p-core,hp-core |
| IO/ASYNC | e-core | e-core,p-core | e-core,p-core | e-core,p-core |
| AUDIO | e-core | e-core | e-core,p-core | e-core,p-core |
| 配合层 | — | — | 调频层性能档 | 调频层 crazy 档 + 保核 |

---

## 3. 2020 后主流 SOC 映射速查表

| 厂商 | 芯片 | 拓扑 | e-core | p-core | hp-core |
| --- | --- | --- | --- | --- | --- |
| 高通 | SD865/865+/870 | 4+3+1 | 0-3 | 4-6 | 7 |
| 高通 | SD888 | 4+3+1 | 0-3 | 4-6 | 7 |
| 高通 | SD778G/778G+ | 4+3+1 | 0-3 | 4-6 | 7 |
| 高通 | SD780G | 4+3+1 | 0-3 | 4-6 | 7 |
| 高通 | SD7G1 | 4+3+1 | 0-3 | 4-6 | 7 |
| 高通 | SD8G1 / 8+G1 | 4+3+1 | 0-3 | 4-6 | 7 |
| 高通 | SD7+G2 | 4+3+1 | 0-3 | 4-6 | 7 |
| 高通 | SD8G2 | 3+4+1 | 0-2 | 3-6 | 7 |
| 高通 | SD7+G3 | 3+4+1 | 0-2 | 3-6 | 7 |
| 高通 | SD8sG3 | 3+4+1 | 0-2 | 3-6 | 7 |
| 高通 | SD8G3 | 2+3+2+1 | 0-1 | 2-6 | 7 |
| 高通 | SD765G | 6+1+1 | 0-5 | 6 | 7 |
| 高通 | SD750G / 695 / 4G2 | 6+2 | 0-5 | — | 6-7 |
| 高通 | SD680 | 4+4 | 0-3 | — | 4-7 |
| 高通 | SD6G1 | 4+4 | 0-3 | — | 4-7 |
| 高通 | SD8Elite | 2+6 | 0-5 | — | 6-7 |
| 高通 | SD8E6（SM8950） | 2+6 | 0-5 | — | 6-7 |
| 高通 | SD8E6X（SM8975） | 2+3+3 | 0-2 | 3-5 | 6-7 |
| 联发科 | 天玑 1000 系 | 4+4 | 0-3 | — | 4-7 |
| 联发科 | 天玑 1100/1200 | 4+3+1 | 0-3 | 4-6 | 7 |
| 联发科 | 天玑 8100/8200 | 4+3+1 | 0-3 | 4-6 | 7 |
| 联发科 | 天玑 8300 | 4+3+1 | 0-3 | 4-6 | 7 |
| 联发科 | 天玑 9000 | 4+3+1 | 0-3 | 4-6 | 7 |
| 联发科 | 天玑 9200 | 4+3+1 | 0-3 | 4-6 | 7 |
| 联发科 | 天玑 9300 | 4+4 全大核 | 0-3 | — | 4-7 |
| 联发科 | 天玑 9400 | 1+3+4 | 0-3 | 4-6 | 7 |
| 联发科 | 天玑 8400 | 4+3+1 全A725 | 0-3 | 4-6 | 7 |
| 联发科 | 天玑 8500 | 8×A725 单簇 | 0-7 | — | — |
| 联发科 | 天玑 9500s | 1+3+4 | 0-3 | 4-6 | 7 |
| 联发科 | 天玑 9600M | 1+3+4 | 0-3 | 4-6 | 7 |
| 联发科 | 天玑 9600 Pro | 2+3+3 | 0-2 | 3-5 | 6-7 |
| 联发科 | 天玑 7050/6100+ | 6+2 | 0-5 | — | 6-7 |
| 联发科 | Helio G96/G99 | 6+2 | 0-5 | — | 6-7 |
| 海思 | 麒麟 990 | 4+2+2 | 0-3 | 4-5 | 6-7 |
| 海思 | 麒麟 9000 | 4+3+1 | 0-3 | 4-6 | 7 |
| 海思 | 麒麟 9000s/9010/9020 | 4+3+1 | 0-3 | 4-6 | 7 |
| 三星 | Exynos 2100 | 4+3+1 | 0-3 | 4-6 | 7 |
| 三星 | Exynos 2200 | 4+3+1 | 0-3 | 4-6 | 7 |
| 三星 | Exynos 2400 | 4+5+1（10核） | 0-3 | 4-8 | 9 |
| Google | Tensor G1 | 4+2+2 | 0-3 | 4-5 | 6-7 |
| Google | Tensor G2 | 4+2+2 | 0-3 | 4-5 | 6-7 |
| Google | Tensor G3 | 4+4+1（9核） | 0-3 | 4-7 | 8 |
| Google | Tensor G4 | 4+3+1 | 0-3 | 4-6 | 7 |
| 展锐 | T770 | 4+3+1 | 0-3 | 4-6 | 7 |
| 展锐 | T606/T616 | 6+2 | 0-5 | — | 6-7 |

---

## 4. 特殊形态处理

1. **双簇无中核（p-core 空）**：规则里不要写 `p-core`（空集规则被解析器跳过）。默认用 `e-core`，主线程/渲染用 `hp-core`；旗舰全大核（天玑 9300）默认改用数字 `4-6`。
2. **单簇（天玑 8500）**：`hp-core` 为空集，MAIN 必须写数字 `7`，其余 `4-6`、`0-7`。
3. **四簇（8 Gen 3）**：AppOptR 把两档中核合并成 `p-core`（2-6），与 Chase 数字规则恰好一致；需要细分两档中核时改数字（渲染 `2-4`、worker `5-6`）。
4. **九核/十核（Tensor G3、Exynos 2400）**：掩码 0-8 / 0-9，规则库不能沿用 8 核假设；AppOptR 支持到 1024 核，无兼容问题。
5. **全大核（8 Elite 2+6、天玑 9300 4+4）**：没有传统小核，"e-core" 只是低频簇的称呼。所谓「小核不调用」在这些平台是伪命题，低负载由低频簇承担即可。
6. **未命中的线程**：有线程规则的包必须写包级默认，否则未命名线程被放开到全部核心，会去抢大核（AppOptR 的 present_cpus 兜底）。
7. **fork 继承**：新线程先继承父线程亲和性，eBPF 模式靠 RENAME 事件纠偏、proc 模式靠扫描周期纠偏；线程名规则要覆盖常见的改名形态（`Thread-*`、`Job.worker*`）。

---

## 5. Chase 数字规则 → 语义规则的迁移对照

| 芯片 | Chase 原规则 | 问题 | 迁移结果 |
| --- | --- | --- | --- |
| 8 Gen 3 | 默认 2-6、主 7 | 正确 | `p-core` / `hp-core`（等价） |
| 8 Gen 2 / 7+G3 / 8sG3 | 默认 2-6 | 夹进 2 颗 A510 | 默认 `3-6`（即 p-core） |
| 8 Gen 1 / 888 / 865 / 778 / 7G1 | 默认 2-6 | 含 2 颗小核、少 1 颗中核 | 默认 `4-6`（p-core） |
| 8 Elite / 8E6 | 默认 2-6、主 7 | 浪费 2 颗 Perf、只用 1 颗 Prime | 默认 `0-5`（e-core）、主 `6-7`（hp-core） |
| 天玑 9300 | 默认 2-6 | 混入 A720 | 默认 `4-6`、主 `7` |
| 天玑 9400/8400/9000/9200 | 默认 2-6 | 含 2 颗小核 | 默认 `4-6`（p-core） |
| 天玑 8500 | 默认 2-6 | 单簇下乱切 | 默认 `0-7`、主 `7` |
| Exynos 2400 / Tensor G3 | 0-7 数字 | 超出 8 核范围 | 0-9 / 0-8 掩码 |

---

## 6. 验证与落地清单

1. 真机确认三档分组：`cat /sys/devices/system/cpu/cpufreq/policy*/related_cpus` + `cpuinfo_max_freq`，与本表对照，不一致以真机为准。
2. 规则库去重：一个包只保留一条包级默认；线程规则每种模式一条，避免 OR 合并意外放大。
3. 优先 eBPF 模式（内核有 BTF 时），无 BTF 自动回退 proc，两种模式结果一致。
4. 配合层：保核（core_ctl）只在游戏前台做；频率/GPU/DDR 由 uperf 层负责，不与线程层抢写。
5. 验收：主线程 Cpus_allowed_list 只含 hp-core；渲染线程稳定在 p-core；大核空闲时间下降；帧率曲线大卡顿次数下降。

---

*本文件为推测稿，未写入模块。数据来源：AppOptR 仓库源码、docs/uperf全平台调度策略.md、module/config/mtd9400.json。*
