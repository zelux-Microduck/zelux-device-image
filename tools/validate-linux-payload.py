"""Reject Windows line endings and BOMs in Linux deployment sources."""
from pathlib import Path

root = Path(__file__).resolve().parents[1]
files = set(root.glob("*.sh")) | set((root / "tools").rglob("*.sh"))
files |= {p for p in (root / "overlay").rglob("*") if p.is_file()}
bad = [str(p.relative_to(root)) for p in sorted(files)
       if b"\r" in p.read_bytes() or p.read_bytes().startswith(b"\xef\xbb\xbf")]
if bad:
    raise SystemExit("Linux payload requires LF without BOM: " + ", ".join(bad))
print(f"Linux payload encoding: OK ({len(files)} files)")
