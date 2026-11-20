#!/usr/bin/env python3
# 线程预设批量校正（v1.9.1）
# 1) 包级默认改为 all-core：全大核 / 2 簇平台上不再把 4 颗中核闲置。
# 2) worker 线程改为 e-core,p-core：让小核（尖顶族）或中簇（全大核）分担，
#    避免所有线程挤在大核上。
# 3) powersave / balance 的渲染规则收回到 p-core。
# 只做文本替换，保持原有注释与排版。
import io
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent / "module" / "appopt"

PKG_DEFAULT = re.compile(r"(?m)^([^#=\s][^=]*)=(?:p-core,hp-core|p-core|hp-core)([ \t]*\{)?$")
WORKER = re.compile(r"(?m)^(\s*(?:Thread-\*|Job\.worker\*|TaskGraphNP\*)=)(?:p-core,hp-core|p-core)$")
ASYNC = re.compile(r"(?m)^(\s*FAsyncLoading=)(?:e-core,p-core|p-core,hp-core)$")


def tune(path: Path, mode: str) -> tuple[int, int, int]:
    text = path.read_text(encoding="utf-8")
    n_pkg = len(PKG_DEFAULT.findall(text))
    text = PKG_DEFAULT.sub(lambda m: f"{m.group(1)}=all-core{m.group(2) or ''}", text)
    n_worker = len(WORKER.findall(text))
    text = WORKER.sub(lambda m: f"{m.group(1)}e-core,p-core", text)
    n_async = len(ASYNC.findall(text))
    text = ASYNC.sub(lambda m: f"{m.group(1)}e-core", text)
    if mode in ("powersave", "balance"):
        text = re.sub(r"^(\s*RenderThread\*=)(?:p-core,hp-core)$",
                      lambda m: f"{m.group(1)}p-core", text, flags=re.M)
    path.write_text(text, encoding="utf-8", newline="\n")
    return n_pkg, n_worker, n_async


def main() -> int:
    if not ROOT.is_dir():
        print(f"appopt 目录不存在: {ROOT}", file=sys.stderr)
        return 1
    for name in ("powersave", "balance", "performance", "fast", "crazy"):
        p = ROOT / f"appopt_{name}.conf"
        if not p.is_file():
            print(f"跳过缺失文件 {p.name}")
            continue
        np, nw, na = tune(p, name)
        print(f"{p.name}: 包级默认 {np} 行, worker {nw} 行, 异步加载 {na} 行")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
