#!/usr/bin/env python3
"""补齐 2020+ 移动端 SoC 的推测配置（v1.9.3）。

以现有同簇数/同平台的配置为模板，覆盖 meta、cpu.powerModel、cpuset 与 sched.cpumask。
所有数值来自 docs 中的《SOC调度与线程调度方案-20261121.md》，标注“推测”，需真机校准。
"""
import json
import os
import sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "module", "config")
AUTHOR = "南何ovo 推算（非官方调参表，需真机校准）"
TAG = "[推测,26.11.21]"


def pm(nr, eff, power, freq, sweet, plain, free):
    return {
        "efficiency": eff,
        "nr": nr,
        "typicalPower": power,
        "typicalFreq": freq,
        "sweetFreq": sweet,
        "plainFreq": plain,
        "freeFreq": free,
    }


def mask(start, end):
    return list(range(start, end + 1))


# name, 模板, powerModel(低→高), cpuset 五元组, cpumask 列表
SPECS = {
    "sdm870": dict(
        tpl="sdm865", name="Snapdragon 870" + TAG,
        pm=[pm(4, 180, 0.6, 1.80, 1.20, 0.90, 0.50), pm(3, 280, 1.3, 2.42, 1.50, 1.10, 0.70), pm(1, 290, 2.2, 3.20, 1.70, 1.20, 0.80)],
        cpuset=("0-7", "0-3,5-6", "0-3", "0-3", "0-6"),
        masks=[mask(0, 3), mask(4, 6), [7]],
    ),
    "sdm7g2": dict(
        tpl="sdm7g2p", name="Snapdragon 7 Gen 2 (SM7475)" + TAG,
        pm=[pm(4, 170, 0.6, 1.80, 1.20, 0.90, 0.50), pm(3, 270, 1.2, 2.49, 1.50, 1.10, 0.70), pm(1, 280, 1.9, 2.91, 1.60, 1.10, 0.70)],
        cpuset=("0-7", "0-3,5-6", "0-3", "0-3", "0-6"),
        masks=[mask(0, 3), mask(4, 6), [7]],
    ),
    "sdm7g3": dict(
        tpl="sdm7g2p", name="Snapdragon 7 Gen 3 (SM7550)" + TAG,
        pm=[pm(4, 175, 0.6, 1.80, 1.20, 0.90, 0.50), pm(3, 265, 1.2, 2.40, 1.50, 1.10, 0.70), pm(1, 275, 1.8, 2.63, 1.60, 1.10, 0.70)],
        cpuset=("0-7", "0-3,5-6", "0-3", "0-3", "0-6"),
        masks=[mask(0, 3), mask(4, 6), [7]],
    ),
    "e2500": dict(
        tpl="e2400", name="Exynos 2500 (S5E9955)" + TAG,
        pm=[pm(2, 180, 0.55, 1.80, 1.20, 0.90, 0.50), pm(5, 300, 1.35, 2.36, 1.50, 1.00, 0.60), pm(2, 320, 1.8, 2.74, 1.70, 1.10, 0.70), pm(1, 350, 2.6, 3.30, 1.90, 1.20, 0.80)],
        cpuset=("0-9", "0-2,4-8", "0-2", "0-2", "0-8"),
        masks=[mask(0, 1), mask(2, 6), mask(7, 8), [9]],
    ),
    "e2600": dict(
        tpl="e2400", name="Exynos 2600" + TAG,
        pm=[pm(6, 330, 2.0, 2.75, 1.80, 1.20, 0.80), pm(3, 360, 2.9, 3.25, 2.00, 1.30, 0.90), pm(1, 390, 3.6, 3.80, 2.20, 1.50, 0.90)],
        cpuset=("0-9", "0-5,7-8", "0-5", "0-5", "0-8"),
        masks=[mask(0, 5), mask(6, 8), [9]],
    ),
    "gs501": dict(
        tpl="gs401", name="Tensor G5 (gs501)" + TAG,
        pm=[pm(2, 200, 0.7, 2.25, 1.50, 1.00, 0.60), pm(5, 360, 2.0, 3.05, 1.90, 1.30, 0.80), pm(1, 400, 3.0, 3.78, 2.30, 1.50, 0.90)],
        cpuset=("0-7", "0-2,4-6", "0-2", "0-2", "0-6"),
        masks=[mask(0, 1), mask(2, 6), [7]],
    ),
    "kirin9030": dict(
        tpl="kirin9020", name="Kirin 9030" + TAG,
        pm=[pm(4, 180, 0.6, 1.60, 1.10, 0.80, 0.45), pm(4, 300, 1.4, 2.20, 1.50, 1.05, 0.65), pm(1, 340, 2.2, 2.95, 1.70, 1.15, 0.70)],
        cpuset=("0-11", "0-3,4-7,8-11", "0-3", "0-3", "0-7"),
        masks=[mask(0, 3), mask(4, 7), mask(8, 11)],
    ),
    "kirin9050": dict(
        tpl="kirin9020", name="Kirin 9050 Pro" + TAG,
        pm=[pm(4, 190, 0.65, 1.70, 1.15, 0.85, 0.45), pm(4, 310, 1.5, 2.30, 1.55, 1.10, 0.65), pm(1, 350, 2.3, 3.05, 1.75, 1.20, 0.75)],
        cpuset=("0-15", "0-3,4-7,8-11,12-15", "0-3", "0-3", "0-11"),
        masks=[mask(0, 3), mask(4, 7), mask(8, 11), mask(12, 15)],
    ),
    "mtd7300": dict(
        tpl="mtd9300", name="Dimensity 7300 (MT6880)" + TAG,
        pm=[pm(4, 180, 0.6, 2.00, 1.30, 0.90, 0.50), pm(4, 250, 1.1, 2.50, 1.60, 1.10, 0.70)],
        cpuset=("0-7", "0-5", "0-3", "0-3", "4-7"),
        masks=[mask(0, 3), mask(4, 7)],
    ),
    "mtd7400": dict(
        tpl="mtd9300", name="Dimensity 7400" + TAG,
        pm=[pm(4, 185, 0.62, 2.00, 1.30, 0.90, 0.50), pm(4, 260, 1.15, 2.60, 1.65, 1.10, 0.70)],
        cpuset=("0-7", "0-5", "0-3", "0-3", "4-7"),
        masks=[mask(0, 3), mask(4, 7)],
    ),
    "xring_o1": dict(
        tpl="sdm8g3", name="XRING O1" + TAG,
        pm=[pm(2, 175, 0.55, 1.80, 1.20, 0.90, 0.50), pm(2, 180, 0.58, 1.90, 1.25, 0.95, 0.50), pm(4, 340, 2.2, 3.40, 1.90, 1.25, 0.75), pm(2, 400, 3.2, 3.90, 2.20, 1.45, 0.90)],
        cpuset=("0-9", "0-1,4-7", "0-1", "0-1", "0-7"),
        masks=[mask(0, 1), mask(2, 5), mask(6, 7), mask(8, 9)],
    ),
    "xring_o3": dict(
        tpl="sdm8g3", name="XRING O3" + TAG,
        pm=[pm(4, 170, 0.55, 1.80, 1.20, 0.90, 0.50), pm(4, 280, 1.3, 2.60, 1.60, 1.10, 0.70), pm(2, 360, 2.4, 3.50, 1.95, 1.30, 0.80)],
        cpuset=("0-9", "0-3,4-7", "0-3", "0-3", "0-7"),
        masks=[mask(0, 3), mask(4, 7), mask(8, 9)],
    ),
}

SYSFS_KEYS = ("cpusetTa", "cpusetFg", "cpusetBg", "cpusetSysBg", "cpusetRe")


def build(cfg_name, spec):
    tpl_path = os.path.join(ROOT, spec["tpl"] + ".json")
    with open(tpl_path, encoding="utf-8") as f:
        data = json.load(f)
    data["meta"]["name"] = spec["name"]
    data["meta"]["author"] = AUTHOR
    data["modules"]["cpu"]["powerModel"] = spec["pm"]
    for key, value in zip(SYSFS_KEYS, spec["cpuset"]):
        data["initials"]["sysfs"][key] = value
    data["modules"]["sched"]["cpumask"] = {
        "all": list(range(0, max(max(m) for m in spec["masks"]) + 1)),
    }
    for i, m in enumerate(spec["masks"]):
        data["modules"]["sched"]["cpumask"]["c%d" % i] = m
    out = os.path.join(ROOT, cfg_name + ".json")
    with open(out, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
        f.write("\n")
    return out


def main():
    if not os.path.isdir(ROOT):
        sys.exit("config dir not found: " + ROOT)
    for name, spec in SPECS.items():
        path = build(name, spec)
        print("wrote %s (%d clusters)" % (os.path.basename(path), len(spec["pm"])))
    # 全量校验：所有 JSON 可解析，powerModel 的 nr 之和等于 cpumask.all 的核数
    bad = []
    for fn in sorted(os.listdir(ROOT)):
        if not fn.endswith(".json") or fn == "template.json":
            continue
        try:
            with open(os.path.join(ROOT, fn), encoding="utf-8") as f:
                d = json.load(f)
            total = sum(x["nr"] for x in d["modules"]["cpu"]["powerModel"])
            cores = len(d["modules"]["sched"]["cpumask"]["all"])
            # 麒麟 9030/9050 是超线程平台：powerModel 按物理核、cpuset 按逻辑核，允许前者更小。
            smt = fn.startswith("kirin9030") or fn.startswith("kirin9050")
            if total != cores and not (smt and total < cores):
                bad.append("%s: powerModel 核数 %d != cpumask %d" % (fn, total, cores))
        except Exception as exc:  # noqa: BLE001
            bad.append("%s: %s" % (fn, exc))
    print("checked %d json; mismatches %d" % (len([x for x in os.listdir(ROOT) if x.endswith(".json")]), len(bad)))
    for line in bad:
        print("  " + line)
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
