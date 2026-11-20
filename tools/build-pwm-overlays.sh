#!/usr/bin/env bash
# Compile the pinned Radxa Zero 3 PWM pinmux overlays into an image's user overlay dir.
set -euo pipefail
BOOT_ROOT=${1:?usage: build-pwm-overlays.sh <boot-root> <rootfs-root> [source-dir]}
ROOTFS_ROOT=${2:?usage: build-pwm-overlays.sh <boot-root> <rootfs-root> [source-dir]}
SRC_DIR=${3:-"$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../device-tree/overlays" && pwd -P)"}
command -v dtc >/dev/null 2>&1 || { echo "dtc is required to build ZELUX PWM overlays" >&2; exit 1; }
mkdir -p "$BOOT_ROOT/overlay-user"
manifest_tmp=$(mktemp)
trap 'rm -f "$manifest_tmp"' EXIT
for overlay in rk3568-pwm12-m1 rk3568-pwm13-m1; do
    src="$SRC_DIR/$overlay.dts"
    [ -f "$src" ] || { echo "missing trusted overlay source: $src" >&2; exit 1; }
    artifact="$BOOT_ROOT/overlay-user/$overlay.dtbo"
    dtc -@ -q -I dts -O dtb -o "$artifact" "$src"
    digest=$(sha256sum "$artifact" | awk '{print $1}')
    # GNU sha256sum escapes the line for paths containing backslashes (for
    # example when this script is smoke-tested from Git Bash on Windows).
    digest=${digest#\\}
    [ "${#digest}" -eq 64 ] || { echo "invalid SHA-256 output for $artifact" >&2; exit 1; }
    printf '%s  %s.dtbo\n' "$digest" "$overlay" >> "$manifest_tmp"
done
install -D -m 0644 "$manifest_tmp" "$ROOTFS_ROOT/usr/share/zelux/pwm-overlays.sha256"
chmod 0644 "$BOOT_ROOT/overlay-user/rk3568-pwm12-m1.dtbo" "$BOOT_ROOT/overlay-user/rk3568-pwm13-m1.dtbo"
echo "Built Radxa Zero 3 PWM12-M1/PWM13-M1 user overlays"
