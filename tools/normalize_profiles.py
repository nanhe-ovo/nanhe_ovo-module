#!/usr/bin/env python3
"""把全量 SoC 配置的 performance/fast 功率墙归一成有限、可解释的档位。

背景：v1.9.5 的 111 份配置里，大量 performance/fast 写成 999（等于不限制），
部分配置的 fastLimitCapacity 是 360。实际运行时 Uperf 会先把整机功率预算放开，
再靠内核/硬件最后一层硬夹，表现就是大核拉满、DDR 高位、温度上来后突然掉帧。

本工具按 modules.cpu.powerModel 的 nr*typicalPower 估算峰值功耗，再分档设置：
    peak <= 4W    2.0 / 4.0 / 16
    peak <= 8W    2.5 / 5.0 / 16
    peak <= 12W   3.0 / 6.0 / 24
    peak <= 16W   4.0 / 8.0 / 36
    peak <= 20W   4.5 / 9.0 / 36
    peak <= 25W   6.0 / 11.0 / 48
    peak > 25W    7.5 / 13.0 / 48
并给缺失字段的配置补上同样的显式值，避免运行时回落到 initials。
"""
import glob
import json
import os
import sys

ROOT = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "module", "config")
DDR_MAX = 5_500_000_000


def peak_power(cfg):
    model = cfg.get("modules", {}).get("cpu", {}).get("powerModel", [])
    total = 0.0
    for item in model:
        if not isinstance(item, dict):
            continue
        try:
            total += float(item.get("nr", 0)) * float(item.get("typicalPower", 0))
        except (TypeError, ValueError):
            pass
    return total


def tier(peak):
    if peak <= 0:
        return (3.0, 6.0, 16.0)
    if peak <= 4:
        return (2.0, 4.0, 16.0)
    if peak <= 8:
        return (2.5, 5.0, 16.0)
    if peak <= 12:
        return (3.0, 6.0, 24.0)
    if peak <= 16:
        return (4.0, 8.0, 36.0)
    if peak <= 20:
        return (4.5, 9.0, 36.0)
    if peak <= 25:
        return (6.0, 11.0, 48.0)
    return (7.5, 13.0, 48.0)


def main():
    changed = []
    for path in sorted(glob.glob(os.path.join(ROOT, "*.json"))):
        name = os.path.basename(path)
        with open(path, "r", encoding="utf-8") as handle:
            cfg = json.load(handle)
        peak = peak_power(cfg)
        slow, fast, cap = tier(peak)
        before = json.dumps(cfg, ensure_ascii=False, sort_keys=True)

        presets = cfg.setdefault("presets", {})
        for mode in ("performance", "fast"):
            block = presets.setdefault(mode, {})
            star = block.setdefault("*", {})
            star["cpu.slowLimitPower"] = round(slow, 1)
            star["cpu.fastLimitPower"] = round(fast, 1)
            star["cpu.fastLimitCapacity"] = round(cap, 1)
            star.setdefault("cpu.margin", 0.4)

        # DDR 下限只保留 5.5GB/s 以内的值；再高会让内存/主板区域持续发热。
        for mode in ("performance", "fast"):
            star = presets.get(mode, {}).get("*", {})
            raw = star.get("sysfs.ddrMin")
            if raw is None:
                continue
            try:
                value = int(str(raw))
            except (TypeError, ValueError):
                continue
            if value > DDR_MAX:
                star["sysfs.ddrMin"] = str(DDR_MAX)

        after = json.dumps(cfg, ensure_ascii=False, sort_keys=True)
        if before != after:
            # 保留原文件的缩进风格（上游配置有 2 空格也有 4 空格），避免整文件重排。
            indent = 2
            try:
                with open(path, encoding="utf-8") as sample_handle:
                    sample = sample_handle.read().splitlines()
                for line in sample[1:]:
                    if line.startswith("    "):
                        indent = 4
                        break
                    if line.startswith("  "):
                        indent = 2
                        break
            except OSError:
                pass
            with open(path, "w", encoding="utf-8") as handle:
                json.dump(cfg, handle, indent=indent, ensure_ascii=False)
                handle.write("\n")
            changed.append((name, peak, slow, fast, cap))

    print("normalized %d config(s)" % len(changed))
    for name, peak, slow, fast, cap in changed:
        print("  %-22s peak=%5.1fW  slow=%4.1f fast=%4.1f cap=%4.1f" % (name, peak, slow, fast, cap))
    return 0


if __name__ == "__main__":
    sys.exit(main())
