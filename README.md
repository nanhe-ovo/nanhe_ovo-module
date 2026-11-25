# 南何ovo · 性能调度

Magisk / KernelSU / APatch 通用的 Android 性能调度模块。v1.11.0 起不再内置或启动 uperf 二进制：CPU 配置继续保存在 JSON 中，构建期生成 `cpu_profiles.tsv`，运行期由自研 `cpu_policy.sh` 优先写标准 cpufreq 节点，被厂商拒绝时走 MTK PPM 兜底；线程调度仍由 AppOptR 负责。

- 版本：`v1.12.0`（versionCode `202611259`）
- 模块 id：`nanhe_ovo`
- 刷入包：`nanhe_ovo-v1.12.0-20261125.zip`（见 Release 页）
- 要求：**arm64** 设备；需要支持模块 WebUI 的管理器与 Root

## v1.12.0 性能优先温控修复

REDMI K Pad / 天玑 9400 的 35m36s《三角洲行动》记录里，游戏内约 94% 的时间被 `thermal_guard` 压在 2/3 档；per-app 规则又把三角洲固定成 `fast`，用户选择的 `crazy` 实际没有进游戏；CPU7 上限还出现偶发写入失败。本版按性能优先重做温控与 CPU 上限链路。

- **温控阈值延后**：`fast/performance` 从 74/79/84/88℃ 改为 84/88/92/95℃，档位上限从 85/70/55/40% 改为 90/80/70/55%；`crazy` 单独使用 84/88/92/95℃ 与 95/88/78/60%，给超频模式更宽的稳态区间。
- **温控上限只降不升**：每档目标取 `min(硬件峰值×百分比, 当前模式基线)`；`fast` 基线低于 90% 时，1/2 档不会把已压好的上限反向抬回。
- **模式切换基线**：切换模式时丢弃旧 `thermal_base`，留一个 tick 给 `cpu_policy` 写完新上限；启动时不再恢复上次遗留基线，避免覆盖当前模式。
- **CPU7 写入兜底**：标准 `scaling_max_freq` 被拒绝后自动尝试 MTK PPM / `cpufreq_limits`，用 `boost_ppm` 记录并在下一次模式应用前释放；写节点前 `chmod 0666`，模式应用加 mkdir 并发锁。
- **三角洲默认 Crazy**：`com.tencent.tmgp.dfm` 与 `.ce` 从 `fast` 改为 `crazy`；升级时旧 DFM fast 规则自动迁移，自定义包保留。

## 这一版做了什么

- **去除内嵌 Uperf**：删除 `bin/uperf` 与 `libuperf.sh`；`uperf.json` / `perapp_powermode.txt` 只作为配置数据保留，不再依赖 uperf 进程。
- **自研表驱动 CPU 策略**：`tools/gen_cpu_profiles.py` 从 111 份 SoC 配置的 `powerModel` 与模式功率墙生成每簇上限表；`cpu_policy.sh` 选择不超过目标值的最高真实 OPP，优先写 `scaling_max_freq`，失败走 MTK PPM。`crazy` 的 0 表示运行期取 `cpuinfo_max_freq`。
- **轻量前台调度**：`game_watch.sh` 每 4 秒扫 top-app cpuset 的 `/proc/<pid>/cmdline`，游戏进前台按 per-app 规则切模式（三角洲 `crazy`，其余默认 `fast`），退出回 `balance`，灭屏 `powersave`；不再每 2 秒跑两次 `dumpsys`。
- **分应用规则迁移**：覆盖升级时把旧版 `* performance` 模板合并为新模板（46 款游戏 `fast`、三角洲与 CE `crazy`、`- powersave`、`* balance`），保留自定义包名。
- **温控基线重置**：模式切换时丢弃上一模式的旧上限，启动时重新应用当前模式，避免 `fast` 被旧基线夹住。
- **WebUI**：底栏改为离底边 16px 的实色 Miuix 悬浮胶囊，当前页浅蓝高亮；移除液态玻璃、背景模糊、折射/色散/镜片滑动。页面纯本地，不联网。

完整说明见 [`module/README.md`](module/README.md)，版本记录见 [`docs/CHANGELOG.md`](docs/CHANGELOG.md)，短公告见 [`docs/更新公告-v1.12.0.md`](docs/更新公告-v1.12.0.md)。

## 安装

1. 在管理器里刷入 `dist/nanhe_ovo-v1.12.0-20261125.zip`。
2. 重启。
3. KernelSU / APatch → 模块 → 南何ovo → 打开 WebUI；Magisk 可用 KsuWebUIStandalone 打开 `/data/adb/modules/nanhe_ovo/webroot/index.html`。

升级用户会备份旧 `uperf.json`，并迁移旧版分应用规则；首次进入建议查看总览页的 CPU 策略接管状态与运行日志。

## 仓库结构

```
module/                模块本体（打包内容）
├── cpu_profiles.tsv   构建期生成的每簇上限表
├── config/*.json      111 份 SoC 功耗模型与预设
├── script/            cpu_policy / control / game_watch / thermal_guard 等
├── appopt/            AppOptR 规则与 GPL-3.0 许可证
├── webroot/           Miuix WebUI
└── README.md          模块使用与边界说明
tools/                 构建、配置生成与校验脚本
tests/                 shell / core / 渲染回归
docs/                  更新日志与公告
dist/                  构建产物（本地生成，不随源码提交）
```

## 构建与测试

```sh
python3 tools/gen_cpu_profiles.py
bash tests/shell/run-tests.sh
node tests/core.test.cjs
python3 tools/build.py
```

`tools/build.py` 会在打包前重生成 CPU 表，并校验：表存在且模式完整、每份有 `powerModel` 的配置都有对应行、模块内不再含 `bin/uperf` 或 `libuperf.sh`、zip 包含 `cpu_policy.sh` 与 `cpu_profiles.tsv`。

## 边界

- 只使用标准 `cpufreq` 节点；厂商 PPM / 私有温控仍可能覆盖，写失败会记录到 `cpu_policy.log`，不会伪造成功。
- `template` 无功耗模型时使用硬件峰值 60%–100% 的通用上限，效果不等同于专有配置。
- 手动频率写入可能被下一次模式切换覆盖；需要稳定值请结合模式选择。
- 不关闭温控，不保证所有 GPU / DDR 节点可写。
- v1.12 的性能优先曲线依据 K Pad 35m36s 记录调整；仍需真机 `game_watch.log` / `thermal_guard.log` / `cpu_policy.log` 复核 84℃ 以上的档位与 CPU7 写入。

## 许可

- 本项目代码：Apache-2.0，见 `LICENSE`。
- Uperf-Game-Turbo 的配置数据与启动脚本骨架：Apache-2.0，声明见 `NOTICE`；当前包不再包含 uperf 可执行文件。
- AppOptR：GPL-3.0，见 `module/appopt/LICENSE-GPL3.txt`。
- busybox：GPL-2.0，声明见 `NOTICE`。

本项目为独立实现，与 Miuix、Xiaomi 无隶属或官方关系。
