# Uperf 运行原理（读上游仓库后整理）

上游仓库：<https://github.com/yinwanxi/Uperf-Game-Turbo>（作者 Matt Yang / 吟惋兮，Apache-2.0，当前 `1.51 based on uperf 904`）。
仓库里没有 C++ 源码，只有 `magisk/bin/uperf`（预编译二进制）、`config/*.json`（60+ 平台配置）、`magisk/script/*.sh`（安装与开机脚本）。下面按「事件 → 决策 → 写入」三层拆。

## 一、它到底是什么

一句话：**一个住在 Native 层的用户态性能控制器，用 sysfs 复刻并扩展内核态 boost 框架的能力**。

- 没有 Java 层、不依赖 Android 框架，只有一个 `uperf` 进程 + JSON 配置；
- 不改内核、不刷第三方内核、不需要重编译框架，Android 6.0+ / arm64 通吃；
- 启动方式：`uperf /sdcard/Android/yc/uperf/uperf.json -o uperf_log.txt`，启动后把自己放进 `background` cpuset，避免和前台抢 CPU。

传统方案（高通 CAF Boost、libperfmgr）是「Java 层发 Hint → Native 服务收 Hint → 改 sysfs」，Uperf 把发 Hint 的那一半也自己做掉了，所以没有框架依赖。

## 二、第一层：场景识别（它凭什么知道现在该升频）

| 事件源 | 手段 | 产出 |
| --- | --- | --- |
| 触摸 | 直接读 `/dev/input` 设备，解析触摸屏报点 | 点击 / 滑动 / 长按；用末端速度推算滑动还会持续多久 |
| 瞬时重负载 | 主动轮询各核利用率与频率 | 系统负载 = Σ efficiency(i)·load(i)·freq(i)，超过 `heavyLoad` 进重负载，低于 `idleLoad` 退出 |
| APP 切换 / 解锁 | 监听 cpuset 分组与 ActivityManager 活动 | `amSwitch`：提前把前台进程搬到大核，迁移延迟约降 100ms |
| 息屏 | 监听 wakelock 更新（Native 层收不到息屏广播） | `standby` 待机动作 |
| 渲染 | 注入 SurfaceFlinger（SfAnalysis） | 渲染开始 / 提交滞后 / 渲染结束；滞后时立刻拉频，结束后 66ms 内收频 |
| 模式切换 | inotify 监听 `/sdcard/Android/yc/uperf/cur_powermode.txt` 与 `perapp_powermode.txt` | 切换 power mode / 按 App 绑定模式 |
| 系统动画、亮屏 | 额外 Hint | `SsAnim`、`WakeUp` |

重负载有「防抖」：上一次 HeavyLoad 结束后要空闲 1 秒、且 `requestBurstSlack` 时间内没有新请求，才允许再进 —— 避免游戏这种持续高负载一直被按在耗电模式。

## 三、第二层：决策（Hint → action → 参数）

配置结构（v3）：

```json
meta / modules{switcher,atrace,log,input,sfanalysis,cpu,sysfs,sched} / initials / presets
```

- `modules.switcher.hintDuration`：每种 Hint 的默认时长（touch 4s、trigger 0.03s、gesture 0.1s…）；
- 每个 power mode（balance / powersave / performance / fast）× 每种场景键（`*` / `idle` / `touch` / `trigger` / `gesture` / `junk` / `switch`）覆盖一组参数；
- 生效优先级：`initials` 打底 → `presets[mode]["*"]` 覆盖 → `presets[mode][scene]` 再覆盖。

CPU 侧的核心是**功耗模型 + 性能需求-容量模型**，不是简单「拉满」：

```json
"powerModel": [
  { "efficiency": 480, "nr": 1, "typicalPower": 3.8,
    "typicalFreq": 3.3, "sweetFreq": 2.0, "plainFreq": 1.6, "freeFreq": 0.8 }
]
```

- `efficiency`：同频性能（A53@1.0G = 100 为基准）；
- `nr`：该簇核心数；`typicalPower` / `typicalFreq`：该簇的功耗-频率参考点；
- `sweetFreq` / `plainFreq` / `freeFreq`：功耗拐点、普通档、空闲档。

调度参数按场景改写：`latencyTime`（提前多久升频）、`margin`（性能余量）、`burst`（突发加权）、`slowLimitPower` / `fastLimitPower`（慢/快路径功耗上限）、`fastLimitCapacity`、`predictThd`、`limitEfficiency`（低负载时限低频段效率）、`guideCap`（按容量引导）、采样周期 `baseSampleTime` / `baseSlackTime`。

设计取舍：schedutil 固定留 25% 余量，高频段能耗比差、低频段波动大。Uperf 改成**低负载留大余量（低频段能耗比差别小）、高负载留小余量（高频段每档都贵）**，所以体感更稳、峰值功耗更低。

除 CPU 外，同一套 action 还能写：`sysfs.ddrMin`（如 `/sys/class/devfreq/mtk-dvfsrc-devfreq/userspace/set_freq`）、LLCC/L3、cpuset 分组、core_ctl 上下限、GPU devfreq、以及任意自定义 sysfs 节点（UFS 节能开关这类也能挂）。

## 四、第三层：写入（怎么落到 sysfs）

写入器（knob 的 `type`）：

- `string`：等价 `echo val > path`；
- `percluster`：用 `platform/clusterCpuId` 替换路径里的 `%d`，值用逗号分隔；
- `percpu`：按 `platform/efficiency` 的长度生成 CPU 序号；
- `cpufreq`：值 ×100000（kHz），带「先降 max 再降 min / 先升 min 再升 max」的失败重试，避免 min>max 写失败；
- `cgroup_procs`：按进程名把关键进程放进指定 cgroup（不去重，因为线程会变）；
- `uxaffinity`：切换 App 时扫描顶层 App 的线程，把 UI 线程钉到大核（EAS 各平台 schedtune 表现不一，直接设亲和性最通用）。

两个降低开销的细节：

1. **差异写入**：切换 action 时和上一次的值比对，相同就不写，减少 sysfs 往返；
2. **配置热加载**：JSON 改动后 fork 新进程加载，新配置非法就保留旧进程继续跑。

## 五、外围归一化（让 uperf 成为唯一决策者）

`powercfg_once.sh` 在开机时先把系统「清场」，否则多个 boost 会互相打架：

- schedtune / uclamp 全部归零；
- 关掉 msm_thermal、各家热插拔（intelli_plug / blu_plug / zen_decision…）、core_ctl；
- 关掉高通 cpu_boost、msm_performance、walt input_boost；联发科 PPM 的强制限制策略按需关；
- devfreq 的上限放开到 9999MHz，交给 uperf 自己限；
- cpuset 重排：surfaceflinger / system_server / netd 进前台，媒体与显示相关线程下放后台；
- 所有核心 online，避免热插拔引入额外延迟。

## 六、功耗与延迟的账

- 自身开销：轻负载轮询约 0.4–0.6ms / 100ms（A55@1.0G），基本可忽略；
- 代价：用户态写 sysfs 有延迟，所以它必须「提前」——触摸按下就升、渲染滞后就升，而不是等卡了再升；
- 待机：减少唤醒核心数 + 保守升频参数，主要靠减少唤醒时长比例省电。

## 七、和我们模块的关系

南何ovo 的 `module/` 就是「uperf 二进制 + 平台配置 + 安装/控制脚本 + WebUI」的包装：

- 面板写 `cur_powermode.txt` 切模式，写 `perapp_powermode.txt` 做分 App；
- `customize.sh` 按 `ro.board.platform` 选 `config/*.json`，选不到回退 `template.json`；
- `template.json` 的 `cpu.powerModel` 是空数组 —— **空模型 = uperf 不接管频率**，这是 D9400 那次锯齿的根因；
- 面板的「频率」页改的是 `scaling_min/max_freq` 边界，属于在 uperf 决策之外叠加的一层限制。

## 八、边界与坑

- SfAnalysis 靠注入 SurfaceFlinger，失败时功能缺失但不影响主流程（日志里没有 `Sfanalysis connected` 即为失败）；
- 平台配置是「调参产物」，同一 SoC 不同厂商的 devfreq/cpuset 节点不一样，直接套用会写空；
- 关温控不是必须的，只有被限到 1.4GHz 这类硬限制才需要动；
- 它只控制性能释放，后台计算量本身大时救不了续航。
