#!/usr/bin/env python3
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
text = (ROOT / "components.lock.yaml").read_text("utf-8")
required = ("schema", "image", "protocol", "studio", "agent", "drivers", "robotd", "robotd_manifest_sha256")
missing = [key for key in required if not re.search(rf"^{key}:\s*\S+", text, re.MULTILINE)]
if missing:
    raise SystemExit(f"components.lock.yaml 缺少：{', '.join(missing)}")
version = (ROOT / "VERSION").read_text("utf-8").strip()
locked = re.search(r"^image:\s*(\S+)", text, re.MULTILINE).group(1)
if version != locked:
    raise SystemExit(f"镜像版本不一致：VERSION={version}, lock={locked}")
if '--release' in sys.argv:
    robot = re.search(r'^robotd:\s*(\S+)', text, re.MULTILINE).group(1)
    sha = re.search(r'^robotd_manifest_sha256:\s*(\S+)', text, re.MULTILINE).group(1)
    if not re.fullmatch(r'\d+\.\d+\.\d+(?:[-+][A-Za-z0-9.-]+)?', robot) or not re.fullmatch(r'[0-9a-f]{64}', sha):
        raise SystemExit('robotd 尚未锁定真实版本及可信清单哈希，拒绝发布')
print(f"components lock {version} OK")
