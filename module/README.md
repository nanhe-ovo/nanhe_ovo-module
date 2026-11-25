# 南何ovo

Magisk / KernelSU / APatch 通用的性能调度模块：**自研表驱动 CPU 策略 + AppOptR 线程调度 + Miuix 观感 WebUI**。v1.11.0 起不再内置或启动 uperf 二进制，CPU 配置继续保留在 JSON 中，构建时生成每簇频率上限表，运行期由 `cpu_policy.sh` 直接写标准 cpufreq 节点。

- 模块 ID：`nanhe_ovo`
- 版本：`v1.11.0`（versionCode `202611257`）
- CPU 策略：`script/cpu_policy.sh` + `cpu_profiles.tsv`
- 线程引擎：AppOptR（GPL-3.0，SutoLiu）
- 配置数据：Uperf-Game-Turbo 功耗模型（Apache-2.0，仅作 JSON 数据源）
- WebUI：纯本地 HTML/CSS/JS，无远程资源，不联网

## 工作方式

1. 安装器按 `ro.board.platform` / `ro.product.board` / `ro.soc.model` 匹配 SoC 配置，并用真实核数、簇频率复核；伪装机型时会按拓扑指纹改选正确配置。
2. `tools/gen_cpu_profiles.py` 读取 `module/config/*.json` 的 `powerModel` 和模式功率墙，按 \(P \propto f^2\) 折算成每簇上限，写入 `module/cpu_profiles.tsv`。`template.json` 没有功耗模型，不生成表，运行期用硬件峰值的温和比例兜底。
3. 开机 `initsvc.sh` 先让 `control.sh status` 记录本次开机原始频率边界，再调用 `cpu_policy.sh apply <mode>`；后者按 `scaling_available_frequencies` 选不超过目标值的最高真实 OPP，写 `scaling_max_freq`，并把 `scaling_min_freq` 限制在目标以下。
4. `game_watch.sh` 每 4 秒读一次 top-app cpuset 的 `/proc/<pid>/cmdline`，识别到 `game.list` 中的游戏才切 `fast`；退出游戏回 `balance`，灭屏切 `powersave`。只有 top-app 节点不可读时才降级为最多 20 秒一次的 `dumpsys`，不再每 2 秒跑两次 `dumpsys`。
5. 模式切换同时更新 GPU 窗口、DDR 上限、AppOptR 线程档位；温控闸门检测到模式变化会丢弃上一模式的旧基线，避免把 `fast` 夹在 `balance` 的旧上限上。

`/sdcard/Android/yc/uperf/uperf.json` 和 `perapp_powermode.txt` 路径保留，目的是兼容已有配置与用户规则；它们现在只是配置数据，不再驱动 uperf 进程。

## 安装

1. 设备需要 **arm64**（模块内 busybox 与 AppOptR 为 aarch64）。
2. 管理器刷入 `nanhe_ovo-v1.11.0-20261125.zip`。
3. 重启后打开 WebUI：KernelSU / APatch → 模块 → 南何ovo → 打开 WebUI；Magisk 可用 KsuWebUIStandalone 打开 `/data/adb/modules/nanhe_ovo/webroot/index.html`。
4. 升级用户会备份旧 `uperf.json`，并迁移旧版分应用规则：新模板为 48 款游戏 `fast`、`- powersave`、`* balance`，旧模板的 `* performance` 会被替换，自定义包名保留。

## 面板能力

| 页面 | 能力 |
| --- | --- |
| 总览 | 当前模式、模式列表、CPU/GPU 实时频率、CPU 策略接管状态、系统调优开关、线程调度开关 |
| 频率与显示 | CPU / GPU 节点区间、刷新率档位与管理开关、恢复本次开机原始边界 |
| 应用 | 默认规则、熄屏规则、内置游戏名单；单游戏可绑定线程预设，ACE 游戏自动跳过 |
| 关于 | 版本、机型与系统信息、运行日志、来源与许可、能力边界 |

模式切换、规则写入保持目标文件 inode 不变，写前留 `.bak`，写后逐字校验回读，失败回滚。

## CPU 策略与游戏帧率

- 不再依赖 `uperf` 的 inotify 决策；模式切换由 `control.sh` / `game_watch.sh` 显式调用 `cpu_policy.sh`。
- 三角洲行动等 `game.list` 游戏默认 `fast`；v1.10 旧模板的 `* performance` 会在升级时迁移掉，避免游戏被旧的 6W 预算覆盖。
- 前台识别从每 2 秒两次 `dumpsys` 改为 top-app cpuset 扫描，降低轮询开销与小卡顿。
- 温控仍按温度分档限频，但模式切换时重置旧基线；不会为了提高帧率关闭温控。
- 帧率记录里的约 92 秒周期卡顿不能只靠调度解释，仍需 `game_watch.log`、`thermal_guard.log`、`logcat` 继续区分 ACE 扫描、系统后台任务与热控档位切换。

## 命令行

```sh
sh /data/powercfg.sh balance
sh /data/adb/modules/nanhe_ovo/script/control.sh status
sh /data/adb/modules/nanhe_ovo/script/control.sh mode performance
sh /data/adb/modules/nanhe_ovo/script/control.sh rule com.example.game fast
sh /data/adb/modules/nanhe_ovo/script/control.sh rule com.example.game delete
sh /data/adb/modules/nanhe_ovo/script/control.sh freq cpu-policy0 300000 1800000
sh /data/adb/modules/nanhe_ovo/script/control.sh restore
sh /data/adb/modules/nanhe_ovo/script/control.sh tune off
sh /data/adb/modules/nanhe_ovo/script/control.sh thread on
sh /data/adb/modules/nanhe_ovo/script/control.sh thread off
sh /data/adb/modules/nanhe_ovo/script/control.sh threadrule com.example.game game
sh /data/adb/modules/nanhe_ovo/script/control.sh threadrule com.example.game delete
sh /data/adb/modules/nanhe_ovo/script/control.sh refresh 120 on
sh /data/adb/modules/nanhe_ovo/script/control.sh refresh_manage off
```

CPU 策略也可单独调用：

```sh
sh /data/adb/modules/nanhe_ovo/script/cpu_policy.sh apply fast
sh /data/adb/modules/nanhe_ovo/script/cpu_policy.sh status
```

## 系统调优开关

默认开启，开机执行 `powercfg_once.sh` / `platform_special.sh` / `miui_migt.sh`（压平厂商调度、处理温控进程等）。关闭后仍会应用自研 CPU 策略，但不再改动厂商进程；改动下次开机生效。开关状态存于 `/data/adb/nanhe_ovo/tune_disabled`。

## 界面：Miuix 实色悬浮底栏

- 浅灰底、纯白 28px 圆角卡片、绿色状态卡；
- 底栏是离底边 16px 的实色悬浮胶囊，纯白 / 深色卡片色、1px 描边、轻投影；当前页用浅蓝胶囊高亮；
- 已移除液态玻璃、`backdrop-filter`、折射带、色散和镜片滑动；页面滚动不再给底栏加形变；
- 纯本地 HTML/CSS/JS，不引入外部资源。

## 线程调度（AppOptR）

AppOptR（SutoLiu，GPL-3.0）在进程创建和线程改名时把线程放进 `/dev/cpuset` 分组，不改频率、不改优先级。生成规则前，`libtopo.sh` 把 e-core / p-core / hp-core / hp2-core 展开成确定核编号，避免 2 簇或单簇平台产生空 cpuset。ACE 反作弊游戏在 `thread_skip.list` 中整包跳过，避免线程亲和性校验导致闪退。

## 已知边界

- 只使用标准 `cpufreq` 节点；厂商 PPM / 私有温控仍可能覆盖，写失败会记入 `cpu_policy.log`，不会伪造成功。
- 没有功耗模型的 `template` 平台使用硬件峰值 60%–100% 的通用上限，效果不等同于专有配置。
- 手动频率写入可能被下一次模式切换覆盖；需要稳定值请结合模式选择。
- 与其它会改写 CPU 频率的模块同时安装仍可能互相覆盖；安装器只提示，不删除其它模块。
- 不关闭温控，不保证所有 GPU / DDR 节点可写。

## 目录

```
module/
├── module.prop
├── customize.sh
├── service.sh / post-fs-data.sh / uninstall.sh
├── cpu_profiles.tsv          构建期生成的每簇上限表
├── config/*.json             111 份 SoC 功耗模型与预设（安装后移除）
├── script/
│   ├── cpu_policy.sh         自研 CPU 策略层
│   ├── control.sh            WebUI 后端
│   ├── game_watch.sh         轻量前台检测
│   ├── thermal_guard.sh      平滑温控闸门
│   ├── gpu_profile.sh / ddr_profile.sh
│   └── libthread.sh / libtopo.sh / thread_svc.sh
├── appopt/                   AppOptR 规则与许可证
├── bin/busybox/              便携 busybox
└── webroot/                  Miuix WebUI
```

## 许可

- 本项目代码：见 `LICENSE`（Apache-2.0）。
- Uperf-Game-Turbo 的配置数据与启动脚本骨架：Apache-2.0，声明见 `NOTICE`。
- AppOptR：GPL-3.0，许可证全文见 `appopt/LICENSE-GPL3.txt`。
- busybox：GPL-2.0，声明见 `NOTICE`。

本项目为独立实现，与 Miuix、Xiaomi 无隶属或官方关系。
