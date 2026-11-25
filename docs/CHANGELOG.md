# 更新日志

## v1.11.0（2026-11-25）

这一版先把“调度到底有没有生效”拆开：去掉内嵌 uperf 二进制，保留 JSON 功耗配置，用构建期生成的频率表驱动自研 CPU 策略；同时修掉旧版分应用规则在覆盖升级后不迁移的问题。

- **去除内嵌 Uperf**：删除 `bin/uperf` 与 `libuperf.sh`，`initsvc.sh` 不再启动 uperf；`uperf.json` / `perapp_powermode.txt` 只作为配置数据保留，不再依赖 inotify 决策。`NOTICE` 保留上游 Apache-2.0 声明。
- **自研 CPU 策略层**：新增 `script/cpu_policy.sh`，读取 `cpu_profiles.tsv`，按 `scaling_available_frequencies` 选不超过目标值的最高真实 OPP 写 `scaling_max_freq`；`crazy` 的 0 表示运行期取 `cpuinfo_max_freq`，不再把 `999` 写进节点。`template` 无功耗模型时按硬件峰值 60%–100% 兜底。
- **构建期生成表**：新增 `tools/gen_cpu_profiles.py`，从 111 份 JSON 的 `powerModel` 与模式功率墙按 \(P \propto f^2\) 生成每簇上限；`tools/build.py` 每次打包前重生成并校验，表缺失、模式不全、仍带 `bin/uperf` 都直接失败。
- **轻量前台检测**：`game_watch.sh` 从每 2 秒两次 `dumpsys` 改为每 4 秒扫 top-app cpuset 的 `/proc/<pid>/cmdline`；识别到 `game.list` 游戏才切 `fast`，退出回 `balance`，灭屏切 `powersave`。top-app 不可读时才降级为最多 20 秒一次 `dumpsys`。
- **分应用规则迁移**：`customize.sh` 检测旧版 `* performance` 模板，备份后合并为新模板（48 款游戏 `fast`、`- powersave`、`* balance`），保留不在新模板中的自定义包；解决覆盖升级后三角洲仍落到旧 6W 预算的问题。
- **温控基线重置**：`thermal_guard.sh` 检测到模式变化时丢弃上一模式的旧上限，避免 `fast` 被 `balance` 的旧基线夹住；温控分档与回差逻辑保留。
- **WebUI 悬浮底栏**：底栏改为离底边 16px 的实色 Miuix 胶囊，当前页浅蓝高亮；移除液态玻璃、`backdrop-filter`、折射/色散/镜片滑动与滚动形变，卡片仍保持实色大圆角。
- **版本**：`v1.11.0` / `202611257`。

> 帧率记录（Redmi K Pad / D9400 / 三角洲 6m8s）：平均 134.5 FPS、1% Low 85、5% Low 109.4、jank 0.94%，四次大卡顿约间隔 92–94 秒。该记录同时显示 CPU 常压 1.6/2.0GHz、CPU 70–100%、GPU 700–900MHz、峰值约 90°C。旧版日志中游戏开始没有切 `fast`，说明前台链路没有生效；本版先修链路与旧规则迁移，但 92 秒周期卡顿仍需 `game_watch.log`、`thermal_guard.log` 与 `logcat` 继续确认是否为 ACE 扫描或系统后台任务。

## v1.10.0（2026-11-25）

这次不是继续放宽功率墙，而是把“游戏前台才拉起调度、退场就回落”的动态链路补上，并修掉三处会让帧率忽高忽低的默认配置。

- **游戏前台动态调度**：新增 `game_watch.sh`，每 2 秒读 `dumpsys activity` / `dumpsys power`；游戏进前台按 `perapp_powermode.txt` 拉起 `fast`，非游戏回 `balance`，灭屏切 `powersave`。模式变化时同步重生成 AppOptR 的 `active.conf`、应用 GPU 窗口和 DDR 上限，解决“Uperf 已经切 perapp，线程规则还停在全局档位”的错配。
- **不再让未配置应用也走 performance**：`perapp_powermode.txt` 的默认 `*` 从 `performance` 改为 `balance`，48 款内置游戏显式 `fast`；待机/桌面不再先把整机功率预算拉满。
- **线程布局修复**：新增语义核 `hp2-core`，映射到最高频簇最后两颗；`appopt_fast` 的 Unity 主线程、Gfx、RenderThread、GameThread、RHIThread 从单 `hp-core` 改为双大核，`appopt_performance/balance` 的主线程也改为双大核。worker / Job / Thread 仍分散到小核与中核，避免“大核拉满、小核不动”。
- **三角洲闪退**：根因是 ACE 反作弊会枚举线程并校验 cpuset/线程亲和性，旧版虽对 `cmd_threadrule` 做了 ACE 兼容，但内置 `appopt_*` 仍会给 `com.tencent.tmgp.dfm` 建包级 cpuset。v1.10.0 新增 `thread_skip.list`，DFM/DFM CE 整包跳过 AppOptR 规则；WebUI 绑定时返回 `skipped` 并在后端提示“ACE 校验线程亲和性，已跳过绑定，仅保留 Uperf 功率模式”。
- **全 SOC 功率墙归一**：111 份配置的 `performance/fast` 全部改为有限值，按 `modules.cpu.powerModel` 的 `nr*typicalPower` 峰值分 2.0/4.0 到 7.5/13.0 W 七档，`fastLimitCapacity` 从 360 压到 16–48；补齐 7 份缺 `cpu.*LimitPower` 的配置。`tools/build.py` 门禁禁止 `999`、`fastLimitCapacity > 60`、`ddrMin > 5.5GB/s`。
- **骁龙 GPU 窗口**：`gpu_profile.sh` 新增 kgsl 分支，按模式设置 `devfreq` 上下限与 `min/default_pwrlevel`；`platform_special.sh` 不再把 `min_pwrlevel` 钉到最低档、不再把 `throttling` 写成 0，恢复 `throttling=1`，避免 GPU 长期低频或热控完全失效。
- **DDR 上限**：新增 `ddr_profile.sh`，按模式把 MTK `bus_dcvs` 与通用 devfreq 的 DDR/总线 `max_freq` 压到硬件峰值的 45%–90%（fast 82%、balance 65%），不再长期 100%。
- **平滑温控**：新增 `thermal_guard.sh`，按模式分档（powersave 66/70/75/80、balance 70/75/80/85、fast/performance/crazy 74/79/84/88°C），3°C 回差、5 秒一 tick，升温每次最多降一档（约 15%），降温连续 3 tick 才回升；在硬件 LMH 硬夹之前先压住尖峰，避免“温度一上来直接掉一大截”。
- **卸载清理**：`uninstall.sh` 先停 `game_watch` / `thermal_guard`，再停 AppOptR，避免卸载后残留进程继续写节点。

> 仍需真机验证：不同厂商的 `dumpsys activity` 文本、kgsl 节点命名、MTK bus_dcvs 子目录可能有差异；脚本读不到时只跳过，不会伪造写入。三角洲闪退若仍复现，请抓 `logcat` 中 ACE 相关行与 `/data/adb/nanhe_ovo/log.txt`。

## v1.9.5（2026-11-21）

- 全量 110 份 SoC 配置逐款联网比对厂商公开规格（三星、高通、联发科、海思、紫光展锐、小米玄戒发布会数据），修正 22 份频率 / 簇结构 / 核数偏差。
- 修正簇结构级错误：
  - 玄戒 O3：改为全大核 2×4.35 + 4×3.68 + 4×3.15（原按大中小三丛标定）。
  - 紫光 T310 改为 1×2.0 A75 + 3×1.8 A55 四核；SC9832E 改为四核 A53 @1.4 GHz（原均按 8 核标定）。
  - 麒麟 9030 改为 8 核 1×2.75 + 3×2.27 + 4×1.72（超线程 cpumask 按 12 线程分组）；麒麟 9050 Pro 改为 9 核四丛集 1×3.1 + 2×2.7 + 4×2.2 + 2×1.75。
  - Exynos 2400 改为 4 簇 1×3.2 + 2×2.9 + 3×2.6 + 4×1.95；天玑 8500 改为 1+3+4 三簇（1×3.4 + 3×3.2 + 4×2.2）。
- 修正频率标定错误：
  - 骁龙 8 Gen 3：3 核组 2.90→3.15、2 核组 3.15→2.96、小核 2.30→2.27。
  - Exynos 1080 超大核 2.6→2.8、中核 2.5→2.6；麒麟 990 统一按 5G 版 2×2.86 + 2×2.36 + 4×1.95。
  - 天玑 1100 改回 4×2.6 + 4×2.0 两簇；天玑 7200/7200-Ultra 6 核组 2.5→2.0；天玑 8300 改 4×3.35 A715 + 4×2.2 A510；天玑 930 2.6→2.2。
  - Helio G96 小核 1.6→2.0；骁龙 7+ Gen 2 小核 1.9→1.8；骁龙 8+ Gen 1 小核 1.8→2.0、中核 2.7→2.75；骁龙 8s Gen 3 小核 1.95→2.0。
  - Tensor G3 三簇重标：1×2.91 + 4×2.37 + 4×1.7。
  - 紫光 T618 小核 1.8→2.0；T710 小核 1.9→1.8；T770 小核 1.8→2.0、中核 2.0→2.2。
- 簇数 / 核数发生变化的配置同步修正 `sched.cpumask` 组数与 `typicalPower/sweetFreq/plainFreq/freeFreq`；典型功耗为同架构相近频率组的经验插值，建议真机功耗校准。
- 核对正确未改：Exynos 1580/2500/2600、Tensor G4/G5、麒麟 9000/9000S/9010/9020、天玑 6100+/7050/7300/7400/8400/9000/9200/9300/9300+/9400/9500/9600M/9600 Pro、骁龙 8 Gen 2/8 Elite/8 Elite Gen 6/8 Elite Extreme Gen 6、玄戒 O1 等。

## v1.9.4（2026-11-21）

- 按真机 topo 校准天玑 9500：簇结构 1+3+4 不变，最高 / 中 / 小簇典型频率改为 4.21 / 3.50 / 2.70 GHz（原 3.73 / 2.90 / 2.60），typicalPower 同步重标为 4.2 / 2.9 / 1.25 W；前台 cpuset 改为 `0-3,4-7`，不再跳过 cpu3。
- 重写天玑 9300：由 4+4 改为真机 1+3+4（0-3 @ 2.0 GHz / 4-6 @ 2.85 GHz / 7 @ 3.25 GHz）；新增 `mtd9300plus` 独立配置（最高核 3.40 GHz）。9300 与 9300+ 按实测 policy 最高频自动区分，不再共用两簇模型。
- `topo_config_ok()` 增加簇数校验：powerModel 组数必须等于实测 policy 数，超线程平台按 cpumask 逻辑核豁免；配置与真机簇结构不符时不再静默通过。
- crazy 档上限写入支持双接口：优先写标准 `scaling_max_freq`，被内核拒绝或回读不符时自动改走 MTK 用户上限接口（`/proc/ppm/policy/hard_userlimit_max_cpu_freq`、`/proc/cpufreq/cpufreq_limits`）；成功写入的 cluster 记录在 `boost_ppm`，恢复基线时逐条写 0 释放。
- 日志区分两个接口的失败原因并保留 stderr 摘要；boost 汇总行说明实际使用的接口顺序。

## v1.9.3（2026-11-21）

- 补全 2020+ 移动端 SoC 推测配置：新增 sdm870、sdm7g2、sdm7g3、Exynos 2500/2600、Tensor G5、麒麟 9030/9050、天玑 7300/7400、玄戒 O1/O3 共 12 份；全量 110 份配置做核数与 cpumask 一致性校验，修复 Exynos 2700 的簇序与 cpumask 缺失。
- 刷入识别增加第三路：`ro.board.platform` / `ro.product.board` 都未匹配时，用 `ro.soc.model` 精确映射（SM8250-AC→870、MT6995→9600 Pro、MT6994→9600M、MT6993→9500、S5E9955→2500 等）；天玑 9500/9500s、9600M、9600 Pro 分别指向独立配置，不再共用同一份规则。
- 首页状态卡移除 Root 方案展示，只显示「模块」工作状态（引擎运行中 / 线程运行中 / 未运行）；运行信息列表不再列出 Root 方案。
- 修复绑定第二个游戏线程预设失败：删除块时不再丢弃其它游戏的块头注释，目标块以 `}` 结束而不是依赖下一个块头，避免裸块累积导致后续绑定互相覆盖。
- 修复三角洲行动闪退：ACE 兼容模式下只下发包级 cpuset（排除最高频簇），不改线程亲和性；可通过 `/data/adb/nanhe_ovo/ace_compat_off` 关闭兼容、恢复完整规则。
- 降低整机功耗：游戏包级 cpuset 与日常应用规则默认排除最高频簇；crazy 档 core_ctl 保核改为默认关闭，需要满核常开时创建 `corectl_pin_enabled` 开关。
- 修复真机日志暴露的后端缺陷：cleanup 与 cpuset 清理不再受 `set -f` 影响；init 在加锁与建工作目录失败时输出真实 errno；锁冲突短暂重试；写 cpufreq 前恢复所有者可写，解决 Uperf 0444 锁导致的 Permission denied；boost 错误重定向顺序修正，stderr 能落盘。
- SUSFS LKM 兼容：检测到 SUSFS 后跳过 miui_migt 的 bind mount / umount 与 chmod 000，避免污染挂载命名空间导致 SUSFS 注入或隐藏失效；模块自身仍不加载/卸载任何 .ko，也不写 kallsyms 与 /proc/susfs_*。
- 测试与构建：新增配置生成器 `tools/gen_missing_configs.py`，打包前做全量 JSON 一致性检查。

## v1.9.2（2026-11-21）

- 应用页改为「游戏」页：只列 `game.list` 内的游戏并显示中文名（内置 47 款，副标题保留包名），非游戏应用不再出现在列表中；搜索同时匹配游戏名与包名。
- 线程分配按真实 CPU 拓扑：新增拓扑探测，在生成规则前把 e-core / p-core / hp-core / all-core 展开成确定的核编号；2 簇（4+4、2+6）与单簇（同频 8 核）平台不再产生空掩码。
- 修复线程优化后游戏启动闪退：上游引擎拿到空语义核集合时会把基础 cpuset 的 cpus 写成空，游戏线程被塞进没有 CPU 的 cgroup，表现为启动卡死/闪退；展开成数字掩码后不会再有空集。
- 修复全大核芯片与骁龙小核不参与：线程预设的包级默认与 worker 规则改为全核 / 跨簇，A510 一类小核重新参与调度；骁龙 2+6 不再把 0-5 整段当作能效核只给音频。
- 修复 fast（极速）档功率墙倒挂：24 个平台配置的 fast 档原为 2.5W、算力容量 0，比 performance 档更受限，现对齐 performance 的功率墙并解除容量限制；原本已是 999（不限制）的配置保持不动。
- 修复伪装机型后调度不生效：安装时用真实核数与各簇频率复核属性选中的配置，不符则按拓扑指纹在同核数配置里选最接近的一份，来源写入 `config_source.txt`，日志给出提示。
- 测试补齐拓扑展开（4+4 / 2+6 / 单簇 / 1+3+4 / 2+4+2）、三列游戏清单、伪装机型改选与 fast 档配置检查。

## v1.9.0（2026-11-20）

- 应用页只展示第三方应用，系统应用不再列出；命中内置游戏名单的应用置顶并标注「游戏」。
- 修复线程规则文件不存在时后端误判失败；修复状态解析因单条频率数据异常拒收整包状态；补齐刷新率管理开关的前端命令白名单；超频写入失败给出可读的错误原因。
- 首次读取状态即尽力生成开机频率基线，restore 不再依赖先手动改过频率；后端残留锁按死进程自动清理。
- 更新方式改为管理器模块仓库通道：由 KernelSU / APatch 等管理器在模块页提示并安装新版本，移除面板内的联网云检查与下载落地逻辑。

## v1.8.0（2026-11-19）

- 面板内云更新：检查 GitHub Release、校验大小与 SHA256，暂存包开机落地。
