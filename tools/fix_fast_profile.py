#!/usr/bin/env python3
# 修复 fast 档的功率墙倒挂（v1.9.1）
#
# 现象：部分平台配置里 fast（极速）档的 cpu.slowLimitPower / cpu.fastLimitPower
# 只有 2.5W，低于 performance 档的 10W；cpu.fastLimitCapacity 写成 0。
# 结果：选「极速」反而比「性能」更受限，全大核 / 2+6 平台核心上不了线，游戏持续降频。
#
# 修复原则（保守）：只在 fast 档确实弱于 performance 档时才抬升，
# 目标值取 performance 档的功率墙，并解除算力容量限制；已经是 999 的配置不动。
#
# 用法：python tools/fix_fast_profile.py [--dry-run]
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent / "module" / "config"


def num(v) -> float:
    try:
        return float(v)
    except (TypeError, ValueError):
        return 0.0


def edit_fast_block(path: Path, dry: bool) -> str | None:
    data = json.loads(path.read_text(encoding="utf-8"))
    presets = data.get("presets", {})
    fast = (presets.get("fast") or {}).get("*") or {}
    perf = (presets.get("performance") or {}).get("*") or {}
    if "cpu.fastLimitPower" not in fast or "cpu.fastLimitPower" not in perf:
        return None

    f_fast = num(fast.get("cpu.fastLimitPower"))
    p_fast = num(perf.get("cpu.fastLimitPower"))
    f_cap = num(fast.get("cpu.fastLimitCapacity"))
    if f_fast >= p_fast and f_cap != 0.0:
        return None

    target_slow = perf.get("cpu.slowLimitPower", 10.0)
    target_fast = p_fast
    target_cap = max(num(perf.get("cpu.fastLimitCapacity")), 360.0)

    text = path.read_text(encoding="utf-8")
    lines = text.splitlines(keepends=True)
    bounds = None
    for i, line in enumerate(lines):
        if line.strip() == '"fast": {':
            indent = len(line) - len(line.lstrip())
            for j in range(i + 1, len(lines)):
                if lines[j].strip() == "}" and (len(lines[j]) - len(lines[j].lstrip())) == indent:
                    bounds = (i, j)
                    break
        if bounds:
            break
    if not bounds:
        return None

    start, end = bounds
    body = "".join(lines[start + 1 : end])
    body = body.replace(
        '"cpu.slowLimitPower": %s' % json.dumps(num(fast.get("cpu.slowLimitPower"))),
        '"cpu.slowLimitPower": %s' % json.dumps(float(target_slow)),
    ) if num(fast.get("cpu.slowLimitPower")) < num(target_slow) else body
    body = body.replace(
        '"cpu.fastLimitPower": %s' % json.dumps(f_fast),
        '"cpu.fastLimitPower": %s' % json.dumps(float(target_fast)),
    )
    if f_cap == 0.0:
        body = body.replace('"cpu.fastLimitCapacity": 0.0', '"cpu.fastLimitCapacity": %s' % json.dumps(float(target_cap)))

    new_text = "".join(lines[: start + 1]) + body + "".join(lines[end:])
    json.loads(new_text)  # 语法自检

    # 只有真的变了才写
    if new_text == text:
        return None
    if not dry:
        path.write_text(new_text, encoding="utf-8", newline="\n")
    return f"fast {f_fast:g}W -> {float(target_fast):g}W, cap {f_cap:g} -> {target_cap:g}"


def main() -> int:
    dry = "--dry-run" in sys.argv
    changed = 0
    for p in sorted(ROOT.glob("*.json")):
        try:
            note = edit_fast_block(p, dry)
        except json.JSONDecodeError as e:
            print(f"语法错误，跳过 {p.name}: {e}", file=sys.stderr)
            continue
        if note:
            changed += 1
            print(f"{'would fix' if dry else 'fixed'} {p.name}: {note}")
    print(f"共 {changed} 个配置文件")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
