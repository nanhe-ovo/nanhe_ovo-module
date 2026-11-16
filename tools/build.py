#!/usr/bin/env python3
"""打包 南何ovo：模块 zip（可刷入）与源码 zip。可复现：固定时间戳、排序、固定权限。"""
import os
import re
import sys
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MODULE = ROOT / "module"
DIST = ROOT / "dist"
STAMP = (2026, 11, 22, 0, 0, 0)
VERSION = "v1.3.2"
BUILD = "20261122"
ZIP_NAME = f"nanhe_ovo-{VERSION}-{BUILD}.zip"
SRC_NAME = f"nanhe_ovo-src-{VERSION}.zip"

TEXT_EXT = {".sh", ".prop", ".md", ".json", ".txt", ".html", ".css", ".js", ".cjs", ".py", ".xml"}
EXEC_FILES = {"bin/uperf", "bin/busybox/busybox", "META-INF/com/google/android/update-binary"}


def payload(path: Path) -> bytes:
    """文本文件统一写 LF；二进制原样写入。"""
    data = path.read_bytes()
    if path.suffix.lower() in TEXT_EXT:
        return data.replace(b"\r\n", b"\n")
    return data


def mode_for(rel: str) -> int:
    if rel in EXEC_FILES:
        return 0o755
    if rel.endswith(".sh"):
        return 0o755
    return 0o644


def check_text(rel: str) -> None:
    path = MODULE / rel
    if path.suffix.lower() not in TEXT_EXT:
        return
    data = path.read_bytes()
    if data.startswith(b"\xef\xbb\xbf"):
        raise SystemExit(f"[FAIL] {rel} 带 UTF-8 BOM")
    if b"\r\n" in data:
        raise SystemExit(f"[FAIL] {rel} 含 CRLF，必须是 LF")
    if rel.endswith(".sh") and not data.startswith(b"#!/system/bin/sh"):
        raise SystemExit(f"[FAIL] {rel} 缺少 #!/system/bin/sh")


def collect(extra_roots=None, include_module=True):
    entries = []
    if include_module:
        for path in sorted(MODULE.rglob("*")):
            if path.is_dir():
                continue
            rel = path.relative_to(MODULE).as_posix()
            entries.append((rel, path, mode_for(rel)))
    if extra_roots:
        for base, prefix, skip in extra_roots:
            for path in sorted(Path(base).rglob("*")):
                if path.is_dir() or any(part in skip for part in path.relative_to(base).parts):
                    continue
                rel = (Path(prefix) / path.relative_to(base)).as_posix()
                entries.append((rel, path, mode_for(path.relative_to(base).as_posix())))
    return entries


def write_zip(target: Path, entries):
    target.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(target, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as zf:
        for rel, path, mode in entries:
            info = zipfile.ZipInfo(rel, date_time=STAMP)
            info.external_attr = (mode | 0o100000) << 16
            info.create_system = 3
            info.compress_type = zipfile.ZIP_DEFLATED
            zf.writestr(info, payload(path))
    return target


def verify(zip_path: Path):
    problems = []
    with zipfile.ZipFile(zip_path) as zf:
        names = zf.namelist()
        if "module.prop" not in names:
            problems.append("缺少 module.prop")
        if "customize.sh" not in names:
            problems.append("缺少 customize.sh")
        if not any(n.startswith("META-INF/com/google/android/") for n in names):
            problems.append("缺少 META-INF 刷入入口")
        for n in names:
            info = zf.getinfo(n)
            mode = (info.external_attr >> 16) & 0o777
            if info.is_dir():
                continue
            if mode not in (0o644, 0o755):
                problems.append(f"{n} 权限异常 {oct(mode)}")
            if n.endswith(".sh") and mode != 0o755:
                problems.append(f"{n} 脚本不是 755")
        props = zf.read("module.prop").decode("utf-8")
        for key in ("id=", "name=", "version=", "versionCode=", "author=", "description="):
            if key not in props:
                problems.append(f"module.prop 缺少 {key}")
        if "id=nanhe_ovo" not in props:
            problems.append("module.prop 的 id 不是 nanhe_ovo")
    return problems


def main():
    DIST.mkdir(parents=True, exist_ok=True)
    entries = collect()
    problems = []
    for rel, _, _ in entries:
        check_text(rel)
    for rel in ("tests/shell/run-tests.sh",):
        path = ROOT / rel
        data = path.read_bytes()
        if data.startswith(b"\xef\xbb\xbf") or b"\r\n" in data:
            raise SystemExit(f"[FAIL] {rel} 必须是 UTF-8 无 BOM 且 LF 换行")
        if not data.startswith(b"#!/usr/bin/env bash"):
            raise SystemExit(f"[FAIL] {rel} 缺少 shebang")
    sizes = sum(p.stat().st_size for _, p, _ in entries)
    print(f"模块文件 {len(entries)} 个，未压缩 {sizes // 1024} KB")

    module_zip = write_zip(DIST / ZIP_NAME, entries)
    problems += verify(module_zip)

    src_entries = collect([(MODULE, "nanhe_ovo/module", ()), (ROOT / "tests", "nanhe_ovo/tests", ("__pycache__", "shell/tmp")),
                           (ROOT / "tools", "nanhe_ovo/tools", ("__pycache__",))], include_module=False)
    src_entries += [(f"nanhe_ovo/{n}", ROOT / n, 0o644) for n in ("README.md", "package.json") if (ROOT / n).exists()]
    src_zip = write_zip(DIST / SRC_NAME, src_entries)

    cfg_count = len(list((MODULE / "config").glob("*.json")))
    print(f"平台配置 {cfg_count} 个")
    for p in (module_zip, src_zip):
        print(f"输出 {p.name}  {p.stat().st_size // 1024} KB")
    if problems:
        for p in problems:
            print("[FAIL]", p)
        sys.exit(1)
    print("PASS 打包校验：入口、module.prop、权限全部正常")


if __name__ == "__main__":
    main()
