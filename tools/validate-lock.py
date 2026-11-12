#!/usr/bin/env python3
from __future__ import annotations

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
text = (ROOT / "components.lock.yaml").read_text("utf-8")
required = ("schema", "image", "protocol", "studio", "agent", "drivers", "motiond")
missing = [key for key in required if not re.search(rf"^{key}:\s*\S+", text, re.MULTILINE)]
if missing:
    raise SystemExit(f"components.lock.yaml 缺少：{', '.join(missing)}")
version = (ROOT / "VERSION").read_text("utf-8").strip()
locked = re.search(r"^image:\s*(\S+)", text, re.MULTILINE).group(1)
if version != locked:
    raise SystemExit(f"镜像版本不一致：VERSION={version}, lock={locked}")
print(f"components lock {version} OK")
