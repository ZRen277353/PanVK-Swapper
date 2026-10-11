#!/usr/bin/env python3
"""下载 config/panvk-driver.json 里列出的 PanVK 驱动载荷并校验 SHA256。

输出:
  <out>/libvulkan_panvk-<name>.so   校验通过的驱动
  <out>/payloads.json               清单 (name/so/sha256/gpu_match/source)

只在 CI 里跑; 仓库不保存任何二进制。
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import struct
import subprocess
import sys
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CONFIG = ROOT / "config" / "panvk-driver.json"
NAME_RE = re.compile(r"^[a-z0-9][a-z0-9.-]*$")
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
EM_AARCH64 = 183


def load_payloads(path: Path) -> list[dict]:
    data = json.loads(path.read_text(encoding="utf-8"))
    payloads = data.get("payloads")
    if not isinstance(payloads, list) or not payloads:
        raise ValueError("panvk-driver.json must contain a non-empty payloads list")
    for entry in payloads:
        name = entry.get("name")
        if not isinstance(name, str) or not NAME_RE.fullmatch(name):
            raise ValueError(f"invalid payload name: {name!r}")
        if not isinstance(entry.get("url"), str) or not entry["url"]:
            raise ValueError(f"payload {name}: missing url")
        if not SHA256_RE.fullmatch(str(entry.get("sha256", ""))):
            raise ValueError(f"payload {name}: sha256 must be 64 lowercase hex chars")
    return payloads


def download(url: str, dest: Path) -> None:
    dest.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(
        ["curl", "-fsSL", "--retry", "3", "--retry-delay", "2", "-o", str(dest), url],
        check=True,
    )


def check_aarch64_shared_object(data: bytes, name: str) -> None:
    if data[:4] != b"\x7fELF":
        raise ValueError(f"payload {name}: not an ELF file")
    machine = struct.unpack_from("<H", data, 18)[0]
    e_type = struct.unpack_from("<H", data, 16)[0]
    if machine != EM_AARCH64:
        raise ValueError(f"payload {name}: e_machine={machine}, expected {EM_AARCH64} (aarch64)")
    if e_type != 3:  # ET_DYN
        raise ValueError(f"payload {name}: e_type={e_type}, expected 3 (shared object)")
    for marker in (b"vk_icdGetInstanceProcAddr", b"vk_icdNegotiateLoaderICDInterfaceVersion"):
        if marker not in data:
            raise ValueError(f"payload {name}: missing {marker.decode()} (not a Vulkan ICD)")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path, required=True, help="output directory")
    args = parser.parse_args(argv or sys.argv[1:])

    try:
        payloads = load_payloads(CONFIG)
    except (OSError, ValueError, json.JSONDecodeError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1

    args.out.mkdir(parents=True, exist_ok=True)
    manifest = []
    for entry in payloads:
        name = entry["name"]
        raw = args.out / f"{name}.download"
        try:
            download(entry["url"], raw)
            if entry.get("member"):
                with zipfile.ZipFile(raw) as archive:
                    data = archive.read(entry["member"])
            else:
                data = raw.read_bytes()
        except (subprocess.CalledProcessError, KeyError, zipfile.BadZipFile, OSError) as error:
            print(f"error: payload {name}: download/extract failed: {error}", file=sys.stderr)
            return 1
        finally:
            raw.unlink(missing_ok=True)

        digest = hashlib.sha256(data).hexdigest()
        if digest != entry["sha256"]:
            print(
                f"error: payload {name}: sha256 mismatch\n"
                f"       expected {entry['sha256']}\n"
                f"       actual   {digest}",
                file=sys.stderr,
            )
            return 1

        try:
            check_aarch64_shared_object(data, name)
        except ValueError as error:
            print(f"error: {error}", file=sys.stderr)
            return 1

        so_name = f"libvulkan_panvk-{name}.so"
        (args.out / so_name).write_bytes(data)
        manifest.append(
            {
                "name": name,
                "so": so_name,
                "sha256": digest,
                "gpu_match": entry.get("gpu_match", []),
                "source": entry.get("source", ""),
                "url": entry["url"],
            }
        )
        print(f"ok: {name} -> {so_name} ({len(data)} bytes, sha256 verified)")

    (args.out / "payloads.json").write_text(
        json.dumps(manifest, indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
