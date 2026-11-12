#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
AGENT="${AGENT:-$REPO_ROOT/../zelux-device-agent}"
STUDIO="${STUDIO:-$REPO_ROOT/../zelux-studio}"
DRIVERS="${DRIVERS:-$REPO_ROOT/../zelux-device-drivers}"
OUTPUT="${OUTPUT:-$REPO_ROOT/components}"

[ -d "$AGENT/software/zeluxd" ] || { echo "Agent 无效：$AGENT" >&2; exit 1; }
[ -f "$STUDIO/index.html" ] || { echo "Studio 无效：$STUDIO" >&2; exit 1; }
[ -d "$DRIVERS/src/zelux_drivers" ] || { echo "Drivers 无效：$DRIVERS" >&2; exit 1; }
case "$(cd -- "$(dirname -- "$OUTPUT")" && pwd -P)/$(basename -- "$OUTPUT")" in
    "$REPO_ROOT"/*) ;;
    *) echo "OUTPUT 必须在镜像仓库内" >&2; exit 1 ;;
esac

rm -rf --one-file-system -- "$OUTPUT"
mkdir -p "$OUTPUT/software"
cp -a "$AGENT/software/." "$OUTPUT/software/"
cp -a "$DRIVERS/src/zelux_drivers" "$OUTPUT/software/zelux_drivers"
mkdir -p "$OUTPUT/software/web"
cp -a "$STUDIO/." "$OUTPUT/software/web/"
rm -rf --one-file-system -- "$OUTPUT/software/web/.git"
find "$OUTPUT" -type d -name __pycache__ -prune -exec rm -rf -- {} +
find "$OUTPUT" -type f -name '*.pyc' -delete
cp "$REPO_ROOT/components.lock.yaml" "$OUTPUT/components.lock.yaml"
printf 'Components assembled: %s\n' "$OUTPUT"
