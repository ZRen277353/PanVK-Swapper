#!/usr/bin/env python3
"""把校验过的驱动载荷铺进模块目录树, 并生成设备端要用的清单。

输入: fetch-drivers.py 产出的 <drivers>/payloads.json
输出 (写进 pkg/):
  system/lib64/libvulkan_panvk-<name>.so
  system/etc/panvk/icd.d/panvk-<name>.json      指向上面的 so
  system/etc/panvk/payloads.tsv                 name / so / json / gpu_match / source
"""

from __future__ import annotations

import argparse
import json
import shutil
import sys
from pathlib import Path

SYS_ETC = "/system/etc/panvk/icd.d"
SYS_LIB = "/system/lib64"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--drivers", type=Path, required=True, help="directory with payloads.json + *.so")
    parser.add_argument("--pkg", type=Path, required=True, help="module package directory to stage into")
    args = parser.parse_args(argv or sys.argv[1:])

    manifest_path = args.drivers / "payloads.json"
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        print(f"error: cannot read {manifest_path}: {error}", file=sys.stderr)
        return 1
    if not manifest:
        print("error: empty driver manifest", file=sys.stderr)
        return 1

    lib_dir = args.pkg / "system" / "lib64"
    icd_dir = args.pkg / "system" / "etc" / "panvk" / "icd.d"
    lib_dir.mkdir(parents=True, exist_ok=True)
    icd_dir.mkdir(parents=True, exist_ok=True)

    lines = []
    for entry in manifest:
        name = entry["name"]
        so_src = args.drivers / entry["so"]
        if not so_src.is_file():
            print(f"error: missing driver binary {so_src}", file=sys.stderr)
            return 1

        so_name = f"libvulkan_panvk-{name}.so"
        shutil.copyfile(so_src, lib_dir / so_name)

        icd_name = f"panvk-{name}.json"
        icd = {
            "file_format_version": "1.0.0",
            "ICD": {
                "library_path": f"{SYS_LIB}/{so_name}",
                "api_version": "1.2.0",
            },
        }
        (icd_dir / icd_name).write_text(json.dumps(icd, indent=4) + "\n", encoding="utf-8")

        gpu_match = ",".join(entry.get("gpu_match", []))
        source = entry.get("source", "").replace("\t", " ")
        lines.append("\t".join([name, f"{SYS_LIB}/{so_name}", f"{SYS_ETC}/{icd_name}", gpu_match, source]))
        print(f"staged: {name} -> {so_name} + {icd_name}")

    (args.pkg / "system" / "etc" / "panvk" / "payloads.tsv").write_text(
        "\n".join(lines) + "\n", encoding="utf-8"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
