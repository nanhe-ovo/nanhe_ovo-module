#!/usr/bin/env python3
"""从 module/config/*.json 生成运行期 CPU 策略表。

设计边界：
- JSON 仍是唯一配置源；这里只把 powerModel 与模式功率墙折算成「每簇上限」。
- 不在构建期猜测硬件频率表；运行期 cpu_policy.sh 会按
  scaling_available_frequencies 选不高于目标值的真实 OPP。
- crazy 档写 0 表示「运行期取 cpuinfo_max_freq」，不把 999 带进任何节点。
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CONFIG = ROOT / "module" / "config"
OUT = ROOT / "module" / "cpu_profiles.tsv"

MODES = ("powersave", "balance", "performance", "fast", "crazy")
# P ∝ f² 的简化功耗模型；取平方根把功率预算摊到每簇频率上限。
POWER_EXP = 2.0


def mode_budget(data: dict, mode: str):
    """返回该模式的 CPU 功率预算（W）；crazy 返回 None 表示不设上限。"""
    if mode == "crazy":
        return None
    block = (data.get("presets", {}).get(mode, {}) or {}).get("*", {}) or {}
    key = "cpu.fastLimitPower" if mode in ("performance", "fast") else "cpu.slowLimitPower"
    value = block.get(key, (data.get("initials", {}).get("cpu", {}) or {}).get(key))
    try:
        budget = float(value)
    except (TypeError, ValueError):
        return None
    if budget <= 0 or budget >= 999:
        return None
    return budget


def cluster_list(data: dict):
    cpu = (data.get("modules", {}).get("cpu", {}) or {})
    masks = (data.get("modules", {}).get("sched", {}) or {}).get("cpumask", {}) or {}
    models = cpu.get("powerModel") or []
    out = []
    for idx, model in enumerate(models):
        try:
            typical = float(model["typicalFreq"])
            typical_power = float(model["typicalPower"])
            nr = int(model.get("nr", 1))
        except (KeyError, TypeError, ValueError):
            continue
        if typical <= 0 or typical_power <= 0 or nr <= 0:
            continue
        cpus = masks.get(f"c{idx}") or masks.get(f"cluster{idx}") or []
        first = min(int(x) for x in cpus) if cpus else -1
        out.append({
            "idx": idx,
            "first": first,
            "nr": nr,
            "typical": typical,
            "typical_power": typical_power,
            "free": float(model.get("freeFreq", 0) or 0),
            "sweet": float(model.get("sweetFreq", 0) or 0),
        })
    return out


def cap_for(clusters, budget: float):
    """按总功耗墙求统一比例，返回每簇目标频率（GHz）。"""
    total = sum(c["nr"] * c["typical_power"] for c in clusters)
    if total <= 0:
        return None
    ratio = (budget / total) ** (1.0 / POWER_EXP)
    ratio = max(0.05, min(1.0, ratio))
    return [c["typical"] * ratio for c in clusters]


def rows_for(name: str, data: dict):
    clusters = cluster_list(data)
    if not clusters:
        return []
    rows = []
    for mode in MODES:
        budget = mode_budget(data, mode)
        if mode == "crazy":
            caps = [0.0 for _ in clusters]
        else:
            if budget is None:
                continue
            caps = cap_for(clusters, budget)
            if caps is None:
                continue
        for cluster, cap in zip(clusters, caps):
            if mode == "crazy":
                max_khz = 0
            else:
                # 低档不要低于配置里的 freeFreq；性能档也不要超过 typicalFreq。
                floor = cluster["free"] if mode in ("powersave", "balance") else 0
                if mode == "balance" and cluster["sweet"] > 0:
                    cap = min(cap, cluster["sweet"])
                cap = max(cap, floor)
                cap = min(cap, cluster["typical"])
                max_khz = max(1, int(round(cap * 1_000_000)))
            rows.append((name, mode, cluster["idx"], cluster["first"], max_khz))
    return rows


def main() -> int:
    all_rows = []
    missing = []
    for path in sorted(CONFIG.glob("*.json")):
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError) as exc:
            print(f"[FAIL] {path.name}: {exc}", file=sys.stderr)
            return 1
        rows = rows_for(path.stem, data)
        if not rows:
            missing.append(path.name)
            continue
        all_rows.extend(rows)

    lines = [
        "# 由 tools/gen_cpu_profiles.py 从 module/config/*.json 生成，请勿手改。",
        "# soc\tmode\tcluster\tfirst_cpu\tmax_khz\t（max_khz=0 表示运行期取 cpuinfo_max_freq）",
    ]
    lines.extend("\t".join(str(x) for x in row) for row in all_rows)
    OUT.write_text("\n".join(lines) + "\n", encoding="utf-8", newline="\n")

    modes = sorted({row[1] for row in all_rows})
    print(f"CPU 策略表：{len(all_rows)} 行，{len({row[0] for row in all_rows})} 个平台，模式 {', '.join(modes)}")
    if missing:
        print("跳过无功耗模型的配置：" + ", ".join(missing))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
