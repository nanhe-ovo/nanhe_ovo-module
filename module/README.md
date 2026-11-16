# 南何ovo

基于 [Uperf-Game-Turbo](https://github.com/yinwanxi/Uperf-Game-Turbo) 的性能调度模块（Magisk / KernelSU / APatch 通用可刷入 zip），内置一套 Miuix 观感的本地 WebUI（绿色「工作中」状态卡、纯白大圆角卡、底部悬浮液态玻璃胶囊导航）：切换全局性能模式、为单个应用绑定调度策略、直接控制 CPU / GPU 频率区间、调节屏幕刷新率，关于页展示机型与系统信息，并带一份自动记录的运行日志。

- 模块 ID：`nanhe_ovo`
- 版本：`v1.3.1`（versionCode `20261121`）
- 引擎：uperf（来自 Uperf-Game-Turbo，Apache-2.0）
- WebUI：纯本地 HTML/CSS/JS，无远程资源，不联网

## 安装

1. 确认设备为 **arm64**（模块内置的 uperf 与 busybox 只有 aarch64 版本）。
2. 在管理器里刷入 `nanhe_ovo-v1.3.1-20261121.zip`：Magisk → 模块 → 从本地安装；KernelSU / APatch → 模块 → 安装。
3. 重启。
4. 打开面板：KernelSU / APatch 管理器 → 模块 → 南何ovo → 打开 WebUI。
   Magisk 本体没有模块 WebUI，可用 KsuWebUIStandalone 等工具打开 `/data/adb/modules/nanhe_ovo/webroot/index.html`。

安装时会自动匹配 `ro.board.platform` / `ro.product.board` 对应的平台配置；匹配不到时回落到通用模板 `template.json`，面板会显示实际使用的配置名。

安装器在读取任何文件之前会先统一权限（`chown 0:0` + `chmod 0755`）。这一点是必需的：KernelSU / APatch 解包模块时不会还原 zip 里记录的可执行位，`bin/uperf`、`bin/busybox/busybox` 会以 0644 落盘。旧版本把「可执行位检查」放在了授权之前，于是在这类管理器上会误判成「模块内缺少 bin/uperf」并中止安装。现在顺序反过来了，并且补了三层兜底：

- 引擎缺失时先从本模块旧安装（`/data/adb/modules/nanhe_ovo/bin/uperf`）取回；
- 仍缺失且管理器提供了 `$ZIPFILE`，就按条目重新解出 `bin/`；
- `post-fs-data.sh`、`initsvc.sh`、`uperf_start()` 在运行前各自再 `chmod 0755` 一次，防止模块目录权限在重启后被改回。

## 面板能做什么

| 页面 | 能力 |
| --- | --- |
| 总览 | 当前模式、可用模式列表（来自 `uperf.json` 的 `presets`）、CPU/GPU 实时频率、引擎运行状态、系统调优开关 |
| 频率与显示 | 每个 CPU 策略 / GPU 节点的最低–最高频率，只能选设备上报的频率表；屏幕刷新率（30–240Hz，设备声明过的档位可选，未声明的置灰；读不到档位表时放开全部档位）；「强制取消静止降频」开关；一键恢复本次开机原始边界 |
| 应用 | 默认规则 `*`、熄屏规则 `-`、任意已安装应用的调度策略（保存 / 删除） |
| 关于 | 版本、机型与系统信息（设备 / 系统 / 硬件 / 内存 RAM / 内部存储 / 屏幕 / 电池）、运行日志（自动记录，可刷新 / 清空）、来源与许可、能力边界 |

模式切换、规则写入都保持目标文件 inode 不变（写临时文件后覆盖内容），这样 uperf 的 inotify 能立即感知。每次写入前会留 `.bak`，写入后逐字校验回读，失败自动回滚。

## 界面：Miuix 观感 + 只在底栏的液态玻璃

- 浅灰底（`#f1f2f4`）+ 纯白 28px 圆角卡片，卡片不再铺 `backdrop-filter`，也没有玻璃伪元素；
- 首屏左右分栏：左侧绿色「工作中」状态卡（状态标签、根方案、模式与版本、右侧圆形对勾水印），右侧两枚统计卡（已绑定应用规则 / 可调频率节点）；下面一张白卡按「标签在上、值在下」的竖排列出运行状态（Root 方案、当前模式、模块版本、调度引擎、SUSFS 状态、频率基线、系统调优、平台配置）；
- 状态卡的标签是**自动读到的 Root 方案**：KernelSU 的 LKM 形态显示 `LKM`，内核内置的 KernelSU 显示 `GKI`，`APatch`、`Magisk` 各自显示，读不到才是「未知」；
- 状态完全由后端 `status` 驱动：`info.uperf=运行中` 才是「工作中」，读不到就显示「待机」，只读演示显示「只读演示」，不做假成功；
- 底栏是唯一保留玻璃的区域：悬浮胶囊 `position: fixed`，离底边 14px（另加 `env(safe-area-inset-bottom)`），宽度 `min(430px, 100% - 26px)`，`border-radius: 999px`；
- 底栏按 Glass Bottom Bar 教程组合：`vibrancy`（`saturate(240%)`）+ `blur(22px)` + `lens(16px, 32px)` 的上下折射带 + **半透白 surface（顶部 50% → 中部 34% → 底部 42%）**，左右各 2px 红/青色散，滚动时能看到下面卡片透过玻璃；
- 底栏会动：当前页一枚圆形玻璃镜片（`.nav-lens`，带独立高光弧与色散内边），切换页面沿四格滑过去（`cubic-bezier(.34,1.32,.42,1)`）；页面滚动时按滚动速度给底栏加轻微倾斜 / 横向拉伸 / 下沉（`--nav-skew` / `--nav-stretch` / `--nav-drop`），停下后弹簧回位，镜面高光同时随滚动偏移；
- 视觉要素参考 [Kyant0/AndroidLiquidGlass](https://github.com/Kyant0/AndroidLiquidGlass)（Apache-2.0），但本面板是纯 CSS 近似：真正的逐像素折射需要 Shader / RenderEffect，Chromium 的 `backdrop-filter` 做不到，所以这里是「模糊 + 饱和度 + 边缘色散 + 镜面高光」的组合，不是像素级折射；
- 不引入任何外部资源；WebView 不支持 `backdrop-filter` 时（`@supports not`）把底栏回退成不透明胶囊，深色模式另有一套玻璃令牌。

## 命令行 / 便携入口

```sh
# 切换模式
sh /data/powercfg.sh balance

# 面板后端也可直接调用
sh /data/adb/modules/nanhe_ovo/script/control.sh status
sh /data/adb/modules/nanhe_ovo/script/control.sh mode performance
sh /data/adb/modules/nanhe_ovo/script/control.sh rule com.example.game fast
sh /data/adb/modules/nanhe_ovo/script/control.sh rule com.example.game delete
sh /data/adb/modules/nanhe_ovo/script/control.sh freq cpu-policy0 300000 1800000
sh /data/adb/modules/nanhe_ovo/script/control.sh restore
sh /data/adb/modules/nanhe_ovo/script/control.sh tune off
sh /data/adb/modules/nanhe_ovo/script/control.sh refresh 120 on
sh /data/adb/modules/nanhe_ovo/script/control.sh deviceinfo
```

分应用规则文件：`/sdcard/Android/yc/uperf/perapp_powermode.txt`，模式文件：`/sdcard/Android/yc/uperf/cur_powermode.txt`。

## 系统调优开关

默认开启，开机时执行 uperf 上游的 `powercfg_once.sh` / `platform_special.sh` / `miui_migt.sh`（压平厂商调度、处理温控进程等）。

在面板关闭后只启动 uperf 引擎本身，不再改动厂商调度进程；改动**下次开机生效**。开关状态存于 `/data/adb/nanhe_ovo/tune_disabled`（存在即关闭）。

## 屏幕刷新率与开机锁 60Hz

面板通过系统设置的 `peak_refresh_rate` / `min_refresh_rate` 控制刷新率，不写厂商私有节点：

- **档位只取设备真正声明过的值**。后端把 `dumpsys display` 与 `dumpsys SurfaceFlinger` 两份输出一起交给同一个解析器（不再二选一），同时认 `fps=`、`refreshRate=`、`renderFrameRate=`、`framerate=`、`mRefreshRate=`、`vsyncPeriod=`（纳秒，按 `1e9 / period` 换算）和 `1880x3008@120.0Hz` 这类写法，取整、限 20–300、去重，再与候选档位 `30 48 60 72 90 120 144 165 180 240` 求交集。
- **读不到档位表时不整块禁用**。`status` 会额外输出 `refresh_known 0|1`：`1` 表示解析到了档位表，`0` 表示这次一个档位都没读到。读到表时档位取交集，没声明的档位在前端置灰、不可点，后端也会用 `<HZ> Hz is not supported by this device` 拒绝；读不到表时 `refresh_supported` 直接返回全部 10 档，界面提示「已放开全部档位供你尝试」，写入不再被拒——宁可让系统忽略一次写入（值保持不变），也不因为一次解析失败把整页锁死。
- **界面与后端双重校验**。前端把不支持的档位渲染成置灰、带删除线且不可点击的按钮；即使绕过前端直接调用命令，后端也会在拿到档位表的前提下拒绝未声明的档位。
- **强制取消静止降频**。打开后除了写 `peak_refresh_rate`，还会把 `min_refresh_rate` 钉到同一档位，画面静止、熄屏回来时系统不会把刷新率降回 60Hz；关闭则删除 `min_refresh_rate`，交回系统动态调节。写下限失败时会把上限还原成原值并报错，不留半改状态。
- **开机自动重写（修开机锁 60Hz）**。`service.sh` 会在 `initsvc.sh` 之后调用 `script/refresh_apply.sh`：等 `sys.boot_completed=1`，读 `/data/adb/nanhe_ovo/refresh.txt`（`refresh_pin` 表示是否钉下限），应用后 `sleep 6`、`sleep 10` 各补写一次，抵消系统在开机与解锁阶段的静默回落。**首次开机没有保存目标时**，有档位表就取本机最高档并默认开启下限锁定，这就是「开机锁 60Hz」的修法；之后以面板里最后一次选择为准。
- **读不到档位表时沿用当前值**。开机脚本若解析不到任何档位，不再凭空猜一个最高档（可能给出屏幕不支持的 240Hz），而是沿用 `refresh_current()` 读到的系统当前值，并记录一行「未读到档位表，沿用当前刷新率 XHz」；连当前值也读不到才跳过。任何异常都以 `exit 0` 结束，绝不影响开机。

相关状态文件：`/data/adb/nanhe_ovo/refresh.txt`（目标 Hz）、`refresh_pin`（存在即钉下限）、`refresh_orig.txt`（首次写入前的系统原值，卸载时用于还原）。

## 关于页的机型信息

`control.sh deviceinfo` 只读采集，按固定分段输出 `kv <section> <label> <value>`，前端按「设备信息 / 系统信息 / 硬件 / 内存 RAM / 内部存储 / 屏幕 / 电池」渲染成卡片列表：

| 分段 | 来源 |
| --- | --- |
| 设备信息 | `ro.product.brand` / `model` / `manufacturer` / `device`、`ro.build.fingerprint` |
| 系统信息 | `ro.build.version.release` / `sdk` / `security_patch`、`ro.boot.slot_suffix`、`getenforce`、`ro.build.id`、`uname -r` |
| 硬件 | `ro.product.cpu.abi` / `abilist`、`/sys/devices/system/cpu/possible`、`ro.hardware`、`ro.product.board`、`/sys/class/thermal` |
| 内存 RAM / 内部存储 | `/proc/meminfo`、`df -k /data`（一律换算成 GB，两位小数） |
| 屏幕 | `wm size` / `wm density`，另附当前刷新率 |
| 电池 | `dumpsys battery` 的 `level` / `temperature` / `health` / `status` / `technology`，充电功率由电压电流换算 |

取不到的字段统一显示「未知」，命令本身不会失败，因此机型信息读不出来时面板仍能正常工作（只多一条提示）。

## 运行日志

模块自带一份运行日志，出问题时不需要你抓 logcat：

- 文件：`/data/adb/nanhe_ovo/log.txt`，每行 `时间 <TAB> 级别 <TAB> 标签 <TAB> 正文`，级别只有 `info` / `warn` / `error`；最多保留 200 行，超出裁掉最早的。
- 自动记录：任何 `control.sh` 命令失败（错误原文一起写入）、`status` 里读不到刷新率档位表或当前刷新率、本次开机没有频率基线、`uperf.json` 缺失、应用包名枚举报错、开机 `refresh_apply.sh` 的每一次取档与写入结果。
- 去重：同一开机内同一类诊断只记一次（标记文件在 `/data/adb/nanhe_ovo/.log_once/<boot_id>_<key>`），轮询 `status` 不会刷屏；日志文件是符号链接时既不读也不写。
- 页面：关于页底部「运行日志」卡片列出最近 60 条（完整 200 条在后端），可「刷新日志」「清空日志」；页面自己发现的问题（档位表缺失、应用列表为空、机型信息为空、操作失败）也会通过 `control.sh logline` 写进同一份日志。
- 隐私：日志只写在本机，不联网、不上传；卸载时随运行时目录一起删除。

## 已知限制（请先读）

1. **频率限制可能被 uperf 覆盖**。uperf 在模式切换时会重写同一批 `scaling_min_freq` / `scaling_max_freq` / `min_freq` / `max_freq`。面板的频率写入是对内核节点的即时写入并立即回读校验，但不保证在 uperf 切换状态后仍然保持；需要稳定值时应结合模式选择，而不是只靠手动区间。
2. **不提供频率持久化**。重启后回到各模式自己的调度结果，`restore` 也只针对「本次开机」记录的原始边界。
3. **GPU 节点因机型而异**。只有同时可读可写、且在 `/sys/class/devfreq`、`/sys/class/kgsl` 下被发现、名字包含 gpu/mali/kgsl 的节点才会出现；部分机型 GPU 频率由内核驱动锁定，面板会显示「没有可用频率表，禁止写入」。
4. **模板兜底不是精确适配**。未匹配到平台配置时使用 `template.json`，频率档位可能与本机不完全一致，调度效果因机而异。
5. **不做温控关闭**。本模块不实现「关闭温控」之类的取舍；关闭系统调优时也不会去停厂商进程。
6. **需要 Root 且需要 callback 桥接**。Root 不可用或管理器没有 KernelSU 官方 callback 接口时，面板进入只读演示，不会伪造写入成功。
7. **与其它 uperf 类模块冲突**。同时安装会互相改写频率与规则；安装脚本只提示，不会删除任何其它模块。
8. **刷新率档位来自 `dumpsys` 文本解析**。`dumpsys display` / `dumpsys SurfaceFlinger` 的格式随厂商与系统版本变化；现在同时识别 `fps=`、`refreshRate=`、`vsyncPeriod=`、`NN Hz` 等写法，仍解析不到时不会再把整块控件禁用，而是放开全部 30–240Hz 让你尝试（`refresh_known=0` 会显示在状态里）。若某个档位写入后系统仍保持原值，说明该档确实不受支持；把 `dumpsys display | head -n 40` 的输出发回来可以补上对应写法。
9. **刷新率与厂商标注值可能不同**。这里写的是系统允许的上下限，不是屏幕硬件标称值；部分机型还要看「显示刷新率」系统开关或开发者选项的覆盖，模块不会去改这些开关。
10. **首次开机会默认取最高档并钉住下限**。这是为了直接把「开机锁 60Hz」解掉，代价是耗电与发热略高于自动调节；不想要时在面板里选一个较低档位或关掉「强制取消静止降频」，之后开机会按新值重写。
11. **刷新率的持久化依赖开机脚本**。面板写入是即时生效，重启后由 `service.sh` 里的 `refresh_apply.sh` 重写；若管理器禁止模块开机自启或你手动禁用了模块服务，重启后就会回到系统自己的策略。

## 卸载

在管理器里卸载即可。`uninstall.sh` 会：

- 把分应用规则备份到 `/sdcard/nanhe_ovo-perapp_powermode.txt` 后重建 `/sdcard/Android/yc/uperf`，避免丢失用户规则；
- 只删除本模块写入的 `/data/powercfg.sh` / `/data/powercfg-base.sh`（带 `nanhe_ovo` 标记的才删）；
- 按 `/data/adb/nanhe_ovo/refresh_orig.txt` 记录的原值还原 `peak_refresh_rate` / `min_refresh_rate`（原本没有该键就删除），不把改过的刷新率留给系统；
- 删除运行时目录 `/data/adb/nanhe_ovo`。

## 目录结构

```
nanhe_ovo/
├── module.prop              模块信息
├── customize.sh             安装：架构校验、平台配置匹配、写用户配置、权限与 SELinux
├── post-fs-data.sh          两次开机中断即自动禁用，避免开机循环
├── service.sh               开机服务，转交 script/initsvc.sh，随后应用屏幕刷新率
├── uninstall.sh             卸载清理（含刷新率原值还原）
├── system.prop              引擎需要的属性
├── bin/uperf                uperf 引擎（aarch64）
├── bin/busybox/busybox      busybox（aarch64）
├── config/*.json            66 个平台配置 + template.json
├── script/
│   ├── control.sh           WebUI 后端（status/freq/rule/mode/restore/tune/refresh/deviceinfo）
│   ├── refresh_apply.sh     开机应用刷新率（等开机完成、补写三次、失败不影响开机）
│   ├── initsvc.sh           启动流程（受 tune 开关控制）
│   ├── pathinfo.sh / lib*.sh / powercfg_*.sh / platform_special.sh / miui_migt.sh
├── webroot/                 面板（index.html / style.css / core.js / app.js）
├── system/vendor/*          引擎用的 vendor 覆盖文件
├── META-INF/                刷入入口
├── LICENSE / NOTICE         上游许可与声明
└── README.md
```

## 来源与许可

调度引擎、平台配置、启动脚本与 `system/vendor` 覆盖文件来自 **Uperf-Game-Turbo**（作者 Matt Yang / 吟惋兮），Apache License 2.0，原始声明保留在 `LICENSE` 与 `NOTICE`。

本模块的改动部分：

- 新增 `script/control.sh`（WebUI 后端）与 `webroot/` 全套面板；
- 新增 `customize.sh`（平台配置匹配 + `template.json` 兜底 + 冲突提示）；
- `initsvc.sh` 增加系统调优开关与 `/data/powercfg.sh` 占用保护；
- 新增 `script/refresh_apply.sh`（开机刷新率应用），`control.sh` 增加 `refresh` / `deviceinfo` 命令；
- 面板增加刷新率档位、强制取消静止降频开关与机型信息卡片；
- v1.3.1 首页改为左右分栏（状态卡 + 两枚统计卡），运行状态改成竖排「标签 / 值」；状态标签自动显示 Root 方案（LKM / GKI / APatch / Magisk）；
- v1.3.1 底栏玻璃更透：白渐变降到 50% / 34% / 42%，模糊升到 22px，滚动时能看到下面卡片透上来；
- v1.3.0 面板重组为 Miuix 观感（绿色「工作中」状态卡 + 统计卡 + 运行状态表），液态玻璃只保留底栏，玻璃镜片改为圆形并加强边缘色散；
- v1.3.0 `status` 增加 `info susfs`，SUSFS Guard 已装未加载时自动记一条 `warn susfs`；
- v1.3.0 删掉 `post-fs-data.sh` 里的 `need_recuser` / `disable` 标记逻辑：旧逻辑会在第二次开机把模块自己停掉；
- 刷新率档位解析扩展到多种 `dumpsys` 写法，新增 `refresh_known`，读不到档位表时放开全部档位、开机沿用当前值；
- `uninstall.sh` 增加规则备份、入口标记清理与刷新率原值还原。

Miuix 风格是小米 HyperOS 的视觉语言。本面板是**独立实现**的 HTML/CSS/JS，并非原生 Miuix，与 Miuix、Xiaomi 无隶属或官方关系。
