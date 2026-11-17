#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
生成 2020 年以来移动端 SoC 的 uperf 推测配置。

原则：
- 已有配置一律不覆盖（目标文件存在即跳过）。
- 以 config/template.json 为骨架，只覆盖 meta / cpu.powerModel / sched.cpumask /
  initials.sysfs 通用项；五模式 presets、调度规则、亲和性沿用模板。
- 功耗模型按公开规格（簇类型、核数、典型频率）推算，非官方调参表，需真机校准。
"""
import copy
import json
import os

BASE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CFG_DIR = os.path.join(BASE, "module", "config")
TEMPLATE = os.path.join(CFG_DIR, "template.json")

# 簇：eff=相对效率(A53@1.0G=100)，nr=核数，freq=典型频率 GHz，power=簇典型功耗 W
# vendor: mtk 写 ddrMin 节点与 /data/media/0 路径；其余沿用模板通用 cpuset 与 /sdcard 路径
CHIPS = {
    # ---- 补齐既有映射指向但缺文件的平台 ----
    "mtd6000": {
        "vendor": "mtk",
        "name": "Dimensity 6100+ (mt6835) [推测,26.11.17]",
        "clusters": [
            {"eff": 100, "nr": 6, "freq": 2.0, "power": 0.36},
            {"eff": 250, "nr": 2, "freq": 2.2, "power": 1.0},
        ],
    },
    "mtd930": {
        "vendor": "mtk",
        "name": "Dimensity 7050 (mt6855) [推测,26.11.17]",
        "clusters": [
            {"eff": 100, "nr": 6, "freq": 2.0, "power": 0.36},
            {"eff": 280, "nr": 2, "freq": 2.6, "power": 1.1},
        ],
    },
    "mtd1100": {
        "vendor": "mtk",
        "name": "Dimensity 1100 (mt6891) [推测,26.11.17]",
        "clusters": [
            {"eff": 100, "nr": 4, "freq": 2.0, "power": 0.36},
            {"eff": 300, "nr": 3, "freq": 2.2, "power": 1.2},
            {"eff": 340, "nr": 1, "freq": 2.6, "power": 1.6},
        ],
    },
    "mtd9300": {
        "vendor": "mtk",
        "name": "Dimensity 9300 (mt6989) [推测,26.11.17]",
        "clusters": [
            {"eff": 260, "nr": 4, "freq": 2.0, "power": 0.9},
            {"eff": 450, "nr": 4, "freq": 3.25, "power": 2.4},
        ],
    },
    "mtg96": {
        "vendor": "mtk",
        "name": "Helio G96 (mt6827) [推测,26.11.17]",
        "clusters": [
            {"eff": 100, "nr": 6, "freq": 1.6, "power": 0.30},
            {"eff": 230, "nr": 2, "freq": 2.05, "power": 0.9},
        ],
    },
    "kirin990": {
        "vendor": "kirin",
        "name": "Kirin 990 [推测,26.11.17]",
        "clusters": [
            {"eff": 100, "nr": 4, "freq": 1.86, "power": 0.35},
            {"eff": 200, "nr": 2, "freq": 2.09, "power": 0.9},
            {"eff": 240, "nr": 2, "freq": 2.36, "power": 1.2},
        ],
    },
    "kirin9000": {
        "vendor": "kirin",
        "name": "Kirin 9000 [推测,26.11.17]",
        "clusters": [
            {"eff": 100, "nr": 4, "freq": 2.05, "power": 0.36},
            {"eff": 250, "nr": 3, "freq": 2.54, "power": 1.3},
            {"eff": 360, "nr": 1, "freq": 3.13, "power": 1.8},
        ],
    },
    "kirin9000s": {
        "vendor": "kirin",
        "name": "Kirin 9000S [推测,26.11.17]",
        "clusters": [
            {"eff": 120, "nr": 4, "freq": 1.53, "power": 0.40},
            {"eff": 300, "nr": 3, "freq": 2.15, "power": 1.2},
            {"eff": 380, "nr": 1, "freq": 2.62, "power": 1.6},
        ],
    },
    "kirin9010": {
        "vendor": "kirin",
        "name": "Kirin 9010 [推测,26.11.17]",
        "clusters": [
            {"eff": 120, "nr": 4, "freq": 1.55, "power": 0.40},
            {"eff": 300, "nr": 3, "freq": 2.18, "power": 1.25},
            {"eff": 380, "nr": 1, "freq": 2.30, "power": 1.5},
        ],
    },
    "kirin9020": {
        "vendor": "kirin",
        "name": "Kirin 9020 [推测,26.11.17]",
        "clusters": [
            {"eff": 120, "nr": 4, "freq": 1.60, "power": 0.40},
            {"eff": 300, "nr": 3, "freq": 2.15, "power": 1.2},
            {"eff": 380, "nr": 1, "freq": 2.50, "power": 1.55},
        ],
    },
    "e1080": {
        "vendor": "exynos",
        "name": "Exynos 1080 [推测,26.11.17]",
        "clusters": [
            {"eff": 100, "nr": 4, "freq": 2.0, "power": 0.36},
            {"eff": 280, "nr": 3, "freq": 2.5, "power": 1.2},
            {"eff": 320, "nr": 1, "freq": 2.6, "power": 1.5},
        ],
    },
    "e1480": {
        "vendor": "exynos",
        "name": "Exynos 1480 [推测,26.11.17]",
        "clusters": [
            {"eff": 100, "nr": 4, "freq": 2.0, "power": 0.36},
            {"eff": 280, "nr": 4, "freq": 2.75, "power": 1.3},
        ],
    },
    "e1580": {
        "vendor": "exynos",
        "name": "Exynos 1580 [推测,26.11.17]",
        "clusters": [
            {"eff": 100, "nr": 4, "freq": 2.0, "power": 0.36},
            {"eff": 300, "nr": 3, "freq": 2.6, "power": 1.3},
            {"eff": 350, "nr": 1, "freq": 2.9, "power": 1.7},
        ],
    },
    "e2400": {
        "vendor": "exynos",
        "name": "Exynos 2400 [推测,26.11.17]",
        "clusters": [
            {"eff": 130, "nr": 4, "freq": 1.95, "power": 0.45},
            {"eff": 300, "nr": 5, "freq": 2.9, "power": 1.5},
            {"eff": 480, "nr": 1, "freq": 3.2, "power": 2.0},
        ],
    },
    "gs401": {
        "vendor": "tensor",
        "name": "Tensor G4 (comet) [推测,26.11.17]",
        "clusters": [
            {"eff": 130, "nr": 4, "freq": 1.95, "power": 0.45},
            {"eff": 300, "nr": 3, "freq": 2.6, "power": 1.3},
            {"eff": 480, "nr": 1, "freq": 3.1, "power": 1.9},
        ],
    },
    "sdm8sgen3": {
        "vendor": "qcom",
        "name": "Snapdragon 8s Gen 3 (sm8635) [推测,26.11.17]",
        "clusters": [
            {"eff": 130, "nr": 3, "freq": 1.95, "power": 0.45},
            {"eff": 300, "nr": 4, "freq": 2.8, "power": 1.4},
            {"eff": 480, "nr": 1, "freq": 3.0, "power": 1.9},
        ],
    },
    "sdm8elite": {
        "vendor": "qcom",
        "name": "Snapdragon 8 Elite (sun/sm8755) [推测,26.11.17]",
        "clusters": [
            {"eff": 320, "nr": 6, "freq": 3.53, "power": 1.8},
            {"eff": 460, "nr": 2, "freq": 4.32, "power": 2.6},
        ],
    },
    "sdm7g2p": {
        "vendor": "qcom",
        "name": "Snapdragon 7+ Gen 2 (sm7475) [推测,26.11.17]",
        "clusters": [
            {"eff": 130, "nr": 4, "freq": 1.9, "power": 0.45},
            {"eff": 300, "nr": 3, "freq": 2.49, "power": 1.25},
            {"eff": 400, "nr": 1, "freq": 2.91, "power": 1.7},
        ],
    },
    "sdm6g1": {
        "vendor": "qcom",
        "name": "Snapdragon 6 Gen 1 (sm6450) [推测,26.11.17]",
        "clusters": [
            {"eff": 100, "nr": 4, "freq": 1.8, "power": 0.32},
            {"eff": 260, "nr": 4, "freq": 2.2, "power": 1.0},
        ],
    },
    "mtd7050": {
        "vendor": "mtk",
        "name": "Dimensity 7050 [推测,26.11.17]",
        "clusters": [
            {"eff": 100, "nr": 6, "freq": 2.0, "power": 0.36},
            {"eff": 280, "nr": 2, "freq": 2.6, "power": 1.1},
        ],
    },
    "mtd8400": {
        "vendor": "mtk",
        "name": "Dimensity 8400 [推测,26.11.17]",
        "clusters": [
            {"eff": 260, "nr": 4, "freq": 2.63, "power": 1.1},
            {"eff": 330, "nr": 3, "freq": 3.0, "power": 1.5},
            {"eff": 380, "nr": 1, "freq": 3.25, "power": 1.8},
        ],
    },
    "t310": {
        "vendor": "unisoc",
        "name": "Unisoc T310 (ums312) [推测,26.11.17]",
        "clusters": [
            {"eff": 100, "nr": 4, "freq": 1.6, "power": 0.25},
            {"eff": 160, "nr": 4, "freq": 2.0, "power": 0.6},
        ],
    },
    "sp9832": {
        "vendor": "unisoc",
        "name": "Spreadtrum SC9832E (sp9832e) [推测,26.11.17]",
        "clusters": [
            {"eff": 100, "nr": 8, "freq": 1.6, "power": 0.40},
        ],
    },
}


def cluster_mask(clusters):
    """按簇顺序生成 Linux CPU 编号掩码：c0 小核 / c1 中核 / c2 大核。"""
    total = sum(c["nr"] for c in clusters)
    all_cpus = list(range(total))
    masks = {"all": all_cpus}
    start = 0
    groups = []
    for c in clusters:
        groups.append(list(range(start, start + c["nr"])))
        start += c["nr"]
    if len(groups) == 1:
        masks["c0"] = groups[0]
        masks["c1"] = groups[0]
        masks["c2"] = groups[0]
    elif len(groups) == 2:
        masks["c0"] = groups[0]
        masks["c1"] = groups[1]
        masks["c2"] = groups[1]
    else:
        masks["c0"] = groups[0]
        masks["c1"] = groups[1]
        masks["c2"] = groups[2]
    return masks


# 档位分层：initial cpu 功耗上限 / 余量标尺对齐既有配置
# flagship 参照 sdm8g2/g3/8e6；entry 参照入门 A53/A75 平台；mid 为模板通用档
TIER_INI = {
    "flagship": {"slowLimitPower": 4.0, "fastLimitPower": 8.0, "fastLimitCapacity": 12.0, "margin": 0.18, "burst": 0.0},
    "mid":      {"slowLimitPower": 3.0, "fastLimitPower": 6.0, "fastLimitCapacity": 10.0, "margin": 0.25, "burst": 0.0},
    "entry":    {"slowLimitPower": 2.0, "fastLimitPower": 4.0, "fastLimitCapacity": 6.0,  "margin": 0.20, "burst": 0.0},
}

TIERS = {
    # 旗舰：X4 / Oryon / A77@3.1+ / 全大核 X4
    "sdm8elite": "flagship",
    "sdm8sgen3": "flagship",
    "gs401": "flagship",
    "e2400": "flagship",
    "mtd9300": "flagship",
    "mtd8400": "flagship",
    "kirin9000": "flagship",
    # 入门：A53/A75 展锐平台
    "t310": "entry",
    "sp9832": "entry",
    # 其余默认 mid
}


def power_model(clusters):
    model = []
    for c in clusters:
        f = c["freq"]
        model.append({
            "efficiency": c["eff"],
            "nr": c["nr"],
            "typicalPower": c["power"],
            "typicalFreq": f,
            "sweetFreq": round(f * 0.75, 2),
            "plainFreq": round(f * 0.55, 2),
            "freeFreq": round(f * 0.30, 2),
        })
    return model


def build(spec, name):
    with open(TEMPLATE, encoding="utf-8") as fh:
        cfg = copy.deepcopy(json.load(fh))
    cfg["meta"]["name"] = spec["name"]
    cfg["meta"]["author"] = "南何ovo 推算（非官方调参表，需真机校准）"

    if spec["vendor"] == "mtk":
        cfg["modules"]["switcher"]["switchInode"] = "/data/media/0/Android/yc/uperf/cur_powermode.txt"
        cfg["modules"]["switcher"]["perapp"] = "/data/media/0/Android/yc/uperf/perapp_powermode.txt"
        cfg["modules"]["sysfs"]["knob"]["ddrMin"] = "/sys/class/devfreq/mtk-dvfsrc-devfreq/userspace/set_freq"
    else:
        cfg["modules"]["sysfs"]["knob"].pop("ddrMin", None)

    cfg["modules"]["cpu"]["powerModel"] = power_model(spec["clusters"])
    cfg["modules"]["sched"]["enable"] = False
    cfg["modules"]["sched"]["cpumask"] = cluster_mask(spec["clusters"])

    tier = TIERS.get(name, "mid")
    ini = cfg["initials"]["cpu"]
    for k, v in TIER_INI[tier].items():
        ini[k] = v

    total = sum(c["nr"] for c in spec["clusters"])
    last = total - 1
    cfg["initials"]["sysfs"]["cpusetTa"] = "0-%d" % last
    cfg["initials"]["sysfs"]["cpusetFg"] = "0-%d" % last
    cfg["initials"]["sysfs"]["cpusetBg"] = "0-%d" % (last // 2)
    cfg["initials"]["sysfs"]["cpusetSysBg"] = "0-%d" % (last // 2)
    cfg["initials"]["sysfs"]["cpusetRe"] = "0-%d" % max(last - 1, 0)
    cfg["initials"]["sysfs"].pop("ddrMin", None)
    return cfg


def main():
    force = os.environ.get("FORCE", "") == "1"
    created, skipped, refreshed, guarded = [], [], [], []
    for name, spec in CHIPS.items():
        out = os.path.join(CFG_DIR, name + ".json")
        if os.path.exists(out):
            if not force:
                skipped.append(name)
                continue
            # 覆写保护：只允许刷新本脚本生成的推测件，上游既有配置一律不动
            try:
                old = json.load(open(out, encoding="utf-8"))
                if "推算" not in old.get("meta", {}).get("author", ""):
                    guarded.append(name)
                    continue
            except Exception:
                guarded.append(name)
                continue
            refreshed.append(name)
        else:
            created.append(name)
        cfg = build(spec, name)
        with open(out, "w", encoding="utf-8", newline="\n") as fh:
            json.dump(cfg, fh, ensure_ascii=False, indent=4)
            fh.write("\n")
    print("created:", len(created), " ".join(created))
    print("refreshed:", len(refreshed), " ".join(refreshed))
    print("skipped (已存在，未改动):", len(skipped), " ".join(skipped))
    print("guarded (上游既有配置，受保护未动):", len(guarded), " ".join(guarded))


if __name__ == "__main__":
    main()
