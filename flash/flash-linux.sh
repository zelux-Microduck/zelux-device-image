#!/bin/bash
# =============================================================================
# ZELUX 镜像烧写（Linux / macOS 通用）
#
# 跑在哪：你的电脑上（Linux 或 macOS），不是板子上。
# 要什么权限：root（直接写块设备）。
# 会改动什么：**整块 SD 卡/存储设备会被覆盖**（分区表、所有数据），
#             不碰电脑里的任何文件；不会对卡做格式化（dd 是整盘镜像写入）。
#
# 用法：
#   sudo ./flash-linux.sh zelux-duck-1.0.0-zero3w.img.xz            # 交互选卡
#   sudo ./flash-linux.sh zelux-duck-1.0.0-zero3w.img.xz /dev/sdb   # 指定卡
#   sudo ./flash-linux.sh img.xz /dev/sdb --yes                     # 不问直接写（脚本里用）
#   sudo ./flash-linux.sh img.xz /dev/sdb --no-verify                # 跳过回读校验
#
# 安全设计（都是踩过的坑）：
#   · 拒绝非块设备（防止把 /dev/null、镜像文件当目标）
#   · 拒绝已挂载的设备（macOS/Linux 都会在写入时挂掉或写坏）
#   · 拒绝系统盘（用 findmnt 判断 / 和 /boot 在不在同一块盘上）
#   · 拒绝容量小于镜像的设备（省得写一半失败留下半截分区表）
#   · 写完默认**回读校验**：不校验的 dd 等于"我觉得应该写对了"
# =============================================================================
set -euo pipefail

PROG="${0##*/}"

log()  { printf '\033[1;36m[flash]\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33m[flash] !!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[flash] xx\033[0m %s\n' "$*" >&2; exit 1; }

IMG=""
DEV=""
ASSUME_YES=0
VERIFY=1

while [ $# -gt 0 ]; do
    case "$1" in
        --yes|-y) ASSUME_YES=1; shift ;;
        --no-verify) VERIFY=0; shift ;;
        -h|--help) sed -n '2,25p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*) die "不认识的参数：$1" ;;
        *)
            if [ -z "$IMG" ]; then IMG="$1"
            elif [ -z "$DEV" ]; then DEV="$1"
            else die "多余的参数：$1"
            fi
            shift
            ;;
    esac
done

[ "$(id -u)" -eq 0 ] || die "要 root：sudo $PROG <镜像> [设备]"
[ -n "$IMG" ] || die "没给镜像。用法：sudo $PROG zelux-duck-1.0.0-zero3w.img.xz /dev/sdX"
[ -f "$IMG" ] || die "找不到镜像文件：$IMG"

OS="$(uname -s)"
case "$OS" in
    Linux|Darwin) ;;
    *) die "$OS 不支持用这个脚本，Windows 请用 flash-windows.ps1" ;;
esac

# macOS 没有 sha256sum，只有 shasum
if command -v sha256sum >/dev/null 2>&1; then
    sha256() { sha256sum -- "$1" | awk '{print $1}'; }
    sha256_stdin() { sha256sum | awk '{print $1}'; }
else
    sha256() { shasum -a 256 -- "$1" | awk '{print $1}'; }
    sha256_stdin() { shasum -a 256 | awk '{print $1}'; }
fi

# ---------------------------------------------------------------- 镜像信息
img_bytes() {
    case "$IMG" in
        *.xz)
            # --robot 的输出是机器可读的，第 5 个字段是解压后大小
            xz -l --robot "$IMG" 2>/dev/null | awk -F'\t' '$1=="totals"{print $5}'
            ;;
        *) stat -c %s "$IMG" 2>/dev/null || stat -f %z "$IMG" ;;
    esac
}

IMG_BYTES="$(img_bytes)"
[ -n "${IMG_BYTES:-}" ] && [ "$IMG_BYTES" -gt 0 ] 2>/dev/null \
    || die "读不出镜像大小：$IMG（xz 文件坏了吗？xz -t 验一下）"
log "镜像：$IMG（解压后 $(awk -v b="$IMG_BYTES" 'BEGIN{printf "%.0f", b/1048576}') MiB）"

# 有 .sha256 就先验，别写完才发现包里是坏的
if [ -f "${IMG}.sha256" ]; then
    log "校验镜像 sha256…"
    want_hash="$(awk '{print $1}' "${IMG}.sha256" | head -1)"
    got_hash="$(sha256 "$IMG")"
    [ -n "$want_hash" ] || die "${IMG}.sha256 是空的"
    [ "$want_hash" = "$got_hash" ] \
        || die "镜像 sha256 不对（期望 $want_hash，实际 $got_hash）：重新下载，别烧一个坏包"
    log "sha256 OK"
else
    warn "没有 ${IMG}.sha256，跳过写入前校验（建议从发布页下载配套的 .sha256）"
fi

# ---------------------------------------------------------------- 选设备
list_candidates() {
    if [ "$OS" = "Linux" ]; then
        lsblk -dno NAME,SIZE,TYPE,TRAN,MODEL | awk '$3=="disk"'
    else
        diskutil list
    fi
}

if [ -z "$DEV" ]; then
    printf '\n可用的整盘设备：\n' >&2
    list_candidates >&2
    printf '\n用法：sudo %s %s /dev/sdX   （SD 卡一般是 sd[b-z] 或 mmcblk1）\n' "$PROG" "$IMG" >&2
    exit 1
fi

[ -b "$DEV" ] || die "$DEV 不是块设备。烧写要的是整盘设备（/dev/sdb、/dev/disk4），
     不是分区（/dev/sdb1）、也不是镜像文件。"
case "$DEV" in
    /dev/*) ;;
    *) die "设备路径要以 /dev/ 开头：$DEV" ;;
esac

# 必须是整盘而不是某个分区
if [ "$OS" = "Linux" ]; then
    DEV_TYPE="$(lsblk -dno TYPE "$DEV" 2>/dev/null || true)"
    [ "$DEV_TYPE" = "disk" ] || die "$DEV 不是整盘（TYPE=$DEV_TYPE）。去掉末尾的分区号再来"
    DEV_INFO="$(lsblk -dno SIZE,MODEL "$DEV" 2>/dev/null | head -1 || true)"
    DEV_BYTES="$(blockdev --getsize64 "$DEV")"

    # 已挂载就不写：无论是自动挂载还是手动挂载
    if lsblk -no MOUNTPOINT "$DEV" 2>/dev/null | grep -q '[^[:space:]]'; then
        die "$DEV（或它的分区）现在挂载着：
$(lsblk -no NAME,MOUNTPOINT "$DEV" | sed 's/^/     /')
     先 umount 掉所有分区再来"
    fi

    # 系统盘绝对不能写
    root_src="$(findmnt -no SOURCE / || true)"
    root_disk="$(lsblk -no PKNAME "$root_src" 2>/dev/null | head -1 || true)"
    dev_name="$(basename "$DEV")"
    if [ -n "$root_disk" ] && [ "$root_disk" = "$dev_name" ]; then
        die "$DEV 是当前系统所在的盘（/ 就在它上面）。换一张卡。"
    fi
    for mnt in /boot /boot/firmware /var; do
        src="$(findmnt -no SOURCE "$mnt" 2>/dev/null || true)"
        [ -n "$src" ] || continue
        d="$(lsblk -no PKNAME "$src" 2>/dev/null | head -1 || true)"
        if [ -n "$d" ] && [ "$d" = "$dev_name" ]; then
            die "$DEV 上有 $mnt，是系统盘。换一张卡。"
        fi
    done
else
    DEV_INFO="$(diskutil info "$DEV" 2>/dev/null | grep -E 'Device / Media Name|Disk Size|Removable' || true)"
    DEV_BYTES="$(diskutil info "$DEV" 2>/dev/null | awk -F'[()]' '/Disk Size/{gsub(/[^0-9]/,"",$2); print $2; exit}')"
    [ -n "${DEV_BYTES:-}" ] || DEV_BYTES=0
fi

if [ "${DEV_BYTES:-0}" -lt "$IMG_BYTES" ]; then
    die "$DEV 只有 $((DEV_BYTES / 1048576)) MiB，镜像需要 $((IMG_BYTES / 1048576)) MiB。换大一点的卡（≥16 GB，A2）。"
fi

log "目标：$DEV  $DEV_INFO"

if [ "$ASSUME_YES" -ne 1 ]; then
    printf '\n\033[1;31m%s 上的所有数据都会被覆盖，且不可恢复。\033[0m\n' "$DEV" >&2
    printf '确认继续？请输入 yes（其它任何输入都取消）：' >&2
    ans=""
    read -r ans || true
    [ "$ans" = "yes" ] || die "已取消"
fi

# ---------------------------------------------------------------- 写入
log "开始写入…（大文件 2–6 分钟，别拔卡）"
if [ "$OS" = "Darwin" ]; then
    # macOS 的 /dev/rdiskN 是裸设备，比 /dev/diskN 快 5–10 倍
    RDEV="${DEV/\/dev\/disk//dev/rdisk}"
    if [ "$RDEV" = "$DEV" ]; then
        warn "$DEV 不是 /dev/diskN 形式，直接用 dd 写"
        RDEV="$DEV"
    fi
    if [ "${IMG##*.}" = "xz" ]; then
        xz -dc -- "$IMG" | dd of="$RDEV" bs=4m || die "写入失败（换读卡器/换卡）"
    else
        dd if="$IMG" of="$RDEV" bs=4m || die "写入失败"
    fi
    sync
else
    if [ "${IMG##*.}" = "xz" ]; then
        xz -dc -- "$IMG" | dd of="$DEV" bs=4M iflag=fullblock conv=fsync status=progress \
            || die "写入失败。卡坏了 / 读卡器接触不良 / 被系统占用，换一个口再试"
    else
        dd if="$IMG" of="$DEV" bs=4M iflag=fullblock conv=fsync status=progress \
            || die "写入失败"
    fi
    sync
    # 块设备的读也会走 page cache，回读前先把缓冲丢掉
    blockdev --flushbufs "$DEV" 2>/dev/null || true
    partprobe "$DEV" 2>/dev/null || true
fi
log "写入完成"

# ---------------------------------------------------------------- 回读校验
if [ "$VERIFY" -eq 1 ]; then
    log "回读校验（把写进去的字节读出来再算一遍 sha256，约 1–2 分钟）"
    if [ "${IMG##*.}" = "xz" ]; then
        expected="$(xz -dc -- "$IMG" | sha256_stdin)"
    else
        expected="$(sha256 "$IMG")"
    fi
    if [ "$OS" = "Darwin" ]; then
        actual="$(head -c "$IMG_BYTES" "$RDEV" | sha256_stdin)"
    else
        actual="$(head -c "$IMG_BYTES" "$DEV" | sha256_stdin)"
    fi
    if [ "$expected" = "$actual" ]; then
        log "校验通过：${actual:0:16}…"
    else
        die "校验失败！
     写入期望 $expected
     回读得到 $actual
     可能是卡质量不行 / 读卡器不稳定。换一张卡（≥16 GB、A2、正品）重烧。"
    fi
else
    warn "--no-verify：跳过了回读校验"
fi

# ---------------------------------------------------------------- 收尾
if [ "$OS" = "Linux" ]; then
    sync
    log "可以拔卡了（sudo eject $DEV 或直接拔，已经 sync 过）"
else
    diskutil eject "$DEV" 2>/dev/null || true
    log "已弹出"
fi

cat >&2 <<EOF

================= 烧写完成 =================
1. 卡插进 Radxa Zero 3W，接 5V/3A 电源（Type-C）
2. 首次开机 **2–3 分钟**（扩容 + 装依赖），期间 LED 常亮/慢闪都正常
3. 手机连 WiFi：ZELUX-Duck / zeluxduck
4. 浏览器打开：http://192.168.4.1:8000
5. 默认口令 zelux（登录后在「设置 → 密码」里改）
============================================
EOF
