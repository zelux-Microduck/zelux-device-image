#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
AGENT="${AGENT:-$REPO_ROOT/../zelux-device-agent}"
STUDIO="${STUDIO:-$REPO_ROOT/../zelux-studio}"
DRIVERS="${DRIVERS:-$REPO_ROOT/../zelux-device-drivers}"
FAN="${FAN:-$REPO_ROOT/../zelux-fan/fanctl}"
OUTPUT="${OUTPUT:-$REPO_ROOT/components}"

[ -n "${ROBOTD_RELEASE_DIR:-}" ] && [ -n "${ROBOTD_MANIFEST_SHA256:-}" ] || {
    echo '需要 ROBOTD_RELEASE_DIR 和 ROBOTD_MANIFEST_SHA256；不会构建缺少 robotd 的完整交付' >&2; exit 1;
}
if [ -e "$OUTPUT" ]; then
    echo 'OUTPUT 已存在；请选择新的装配目录，避免覆盖已有组件' >&2; exit 1
fi

[ -d "$AGENT/software/zeluxd" ] || { echo "Agent 无效：$AGENT" >&2; exit 1; }
[ -f "$STUDIO/index.html" ] || { echo "Studio 无效：$STUDIO" >&2; exit 1; }
[ -d "$DRIVERS/src/zelux_drivers" ] || { echo "Drivers 无效：$DRIVERS" >&2; exit 1; }
# fanctl is a single Python script (no .py extension for direct execution)
[ -f "$FAN" ] || { echo "Fan 无效：$FAN (expected fanctl Python script)" >&2; exit 1; }
case "$(cd -- "$(dirname -- "$OUTPUT")" && pwd -P)/$(basename -- "$OUTPUT")" in
    "$REPO_ROOT"/*) ;;
    *) echo "OUTPUT 必须在镜像仓库内" >&2; exit 1 ;;
esac

rm -rf --one-file-system -- "$OUTPUT"
mkdir -p "$OUTPUT/software"
cp -a "$AGENT/software/." "$OUTPUT/software/"
cp -a "$DRIVERS/src/zelux_drivers" "$OUTPUT/software/zelux_drivers"
mkdir -p "$OUTPUT/software/web"
tar -C "$STUDIO" --exclude=.git --exclude=.codegraph --exclude=node_modules -cf - . | tar -C "$OUTPUT/software/web" -xf -
rm -rf --one-file-system -- "$OUTPUT/software/web/.git"
# Install canonical fanctl script (single Python file) into zelux-fan component
mkdir -p "$OUTPUT/software/zelux-fan"
cp "$FAN" "$OUTPUT/software/zelux-fan/fanctl"
chmod +x "$OUTPUT/software/zelux-fan/fanctl"
# Install systemd service units (canonical source for Device Image build)
mkdir -p "$OUTPUT/software/systemd"
cp "$REPO_ROOT/overlay/etc/systemd/system"/*.service "$OUTPUT/software/systemd/"
find "$OUTPUT" -type d -name __pycache__ -prune -exec rm -rf -- {} +
find "$OUTPUT" -type f -name '*.pyc' -delete
if [ -z "${ROBOTD_RELEASE_DIR:-}" ] || [ -z "${ROBOTD_MANIFEST_SHA256:-}" ]; then
    echo '需要 ROBOTD_RELEASE_DIR 和 ROBOTD_MANIFEST_SHA256（独立 ARM64 发布交付目录及可信 manifest 哈希）' >&2
    exit 1
fi
python3 "$REPO_ROOT/tools/robotd_component.py" assemble --source "$ROBOTD_RELEASE_DIR" \
    --manifest-sha256 "$ROBOTD_MANIFEST_SHA256" --output "$OUTPUT/robotd" --lock "$REPO_ROOT/components.lock.yaml"
cp "$REPO_ROOT/components.lock.yaml" "$OUTPUT/components.lock.yaml"
printf 'Components assembled: %s\n' "$OUTPUT"
