#!/bin/bash
# ZELUX 烧写（macOS 版）—— 只是 flash-linux.sh 的外壳：选盘更好选，其它一样
#
# 跑在哪：Mac 上。要什么权限：sudo（写 /dev/rdiskN）。
# 会改动什么：**整张 SD 卡**（不是电脑里的文件），不做格式化。
#
# 用法：
#   sudo ./flash-macos.sh zelux-duck-1.0.0-zero3w.img.xz
#   sudo ./flash-macos.sh img.xz /dev/disk4
#
# 为什么不用 balenaEtcher：能用就用（更省心）。这个脚本是给"命令行更快"的人准备的，
# 而且它会在写完之后把整盘读回来算 sha256 —— Etcher 之外多一层保险。
set -euo pipefail

readonly PROG="${0##*/}"
readonly HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

log()  { printf '\033[1;36m[flash-mac]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[flash-mac] xx\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(uname -s)" = "Darwin" ] || die "这是 macOS 专用脚本。Linux 请用 flash-linux.sh"
[ "$(id -u)" -eq 0 ] || die "要 root：sudo $PROG <镜像> [disk]"
[ $# -ge 1 ] || die "用法：sudo $PROG zelux-duck-1.0.0-zero3w.img.xz [/dev/disk4]"

IMG="$1"
DEV="${2:-}"

[ -f "$IMG" ] || die "找不到镜像：$IMG"
[ -x "$HERE/flash-linux.sh" ] || die "找不到同目录的 flash-linux.sh（两个脚本要放一起）"

if [ -z "$DEV" ]; then
    log "外部磁盘列表（认准容量，别选到移动硬盘）："
    diskutil list external physical >&2 || true
    printf '\n输入磁盘（例如 disk4）：' >&2
    ans=""
    read -r ans || true
    [ -n "$ans" ] || die "没输入，取消"
    case "$ans" in
        /dev/*) DEV="$ans" ;;
        disk*)  DEV="/dev/$ans" ;;
        *)      die "看不懂：$ans（要 disk4 这种）" ;;
    esac
fi

case "$DEV" in
    /dev/disk*) ;;
    *) die "macOS 上设备名必须是 /dev/diskN：$DEV" ;;
esac

# 卸载但**不弹出**：dd 需要设备还在
log "卸载 $DEV 上的卷（不弹出）"
diskutil unmountDisk "$DEV" >/dev/null 2>&1 || log "没有可卸载的卷（可能本来就没挂载）"

# 剩下的交给 flash-linux.sh：它已经处理了 rdisk、shasum、回读校验
exec "$HERE/flash-linux.sh" "$IMG" "$DEV" "${@:3}"
