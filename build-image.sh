#!/usr/bin/env bash
# =============================================================================
# ZELUX Duck Studio —— 全量镜像构建（Radxa Zero 3W / RK3566 / ARM64 / Debian 12）
#
# 跑在哪：**Linux 或 WSL2**，root（要 losetup / mount / mknod）。
#         原生 Windows 的 Git Bash 不行——没有 loop 设备。
# 要什么权限：root。脚本会：解压 → losetup -Pf → 挂 boot(FAT32)+rootfs(ext4)
#             → rsync 注入 overlay + software → 建 zelux 用户 → 关 cloud-init
#             → 打开 systemd 服务 → 清理（日志/machine-id/ssh host key）
#             → 卸载 → xz -T0 -9 压缩 → 出 .sha256。
# 会改动什么：**只动 build/ 下的临时镜像和 --out 指定的输出文件**。
#             --base 那个下载下来的原镜像只读，不会被写。
#             不会碰宿主机上任何块设备。
#
# 用法：
#   sudo ./build-image.sh --base ~/Downloads/radxa-zero3_bookworm_cli_*.img.xz
#   sudo ./build-image.sh --base https://.../radxa-zero3_bookworm_cli_xxx.img.xz
#   sudo ./build-image.sh --base x.img.xz --out /data/zelux-duck-1.0.0-zero3w.img.xz
#   sudo ./build-image.sh --base x.img.xz --size-gb 16      # 直接给最终容量
#   sudo ./build-image.sh --base x.img.xz --no-compress      # 出 .img（快，占地方）
#   sudo ./build-image.sh --base x.img.xz --dry-run          # 只校验，不挂载
#   ./build-image.sh --list                                  # 官方镜像在哪下
#
# 产物：zelux-duck-<VERSION>-zero3w.img.xz + .sha256 + .buildinfo
# =============================================================================
set -euo pipefail

readonly PROG="${0##*/}"
readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly COMPONENT_ROOT="${ZELUX_COMPONENT_ROOT:-$SCRIPT_DIR/components}"
readonly OVERLAY_DIR="$SCRIPT_DIR/overlay"
readonly UNITS_DIR="$COMPONENT_ROOT/software/systemd"
readonly SOFTWARE_DIR="$COMPONENT_ROOT/software"
readonly VERSION="$(tr -d '[:space:]' < "$SCRIPT_DIR/VERSION")"

# 构建工作区（可复用；每次会删掉里面的旧 img）
WORK_DIR="$SCRIPT_DIR/build"
IMG=""
MNT=""
LOOP=""
ROOT_PART=""
BOOT_PART=""
BOOT_MNT_REL=""
ROOT_MOUNTED=0
BOOT_MOUNTED=0
WORK_STARTED=0                          # 是否已经动过工作区（决定失败时提不提示"产物留在哪"）

BASE=""
OUT=""
NO_COMPRESS=0
SIZE_GB=""
DRY_RUN=0
# 默认带离线轮子：板子首个网络是自己开的热点，那时没有外网，
# 不预置依赖 → 首启装不上 fastapi/uvicorn → zeluxd 退出 78 → 网页永远打不开（死循环）。
WHEELHOUSE=1
KEEP_SERIAL=0
NO_GROW=0
# 设备树：留空 = 自动选 rk3566-radxa-zero-3w-ap6212.dtb（Zero 3W 最常见模组）。
# 板上是 AIC8800 模组时用 --dtb aic8800ds2。
ZELUX_DTB="${ZELUX_DTB:-}"

readonly MIB=1048576
readonly GIB=1073741824
# 默认扩容余量：2 GB。为什么不是"整卡"：镜像要能烧到 8/16/32 GB 任意卡上，
# 剩余空间由首启的 zelux-firstboot 在目标机上 growpart + resize2fs 吃完。
readonly DEFAULT_SPARE_BYTES=$((2 * GIB))

# ---------------------------------------------------------------- 输出
log()  { printf '\033[1;36m[build]\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33m[build] !!\033[0m %s\n' "$*" >&2; }
error(){ printf '\033[1;31m[build] ERROR\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[build] xx\033[0m %s\n' "$*" >&2; exit 1; }
step() { printf '\n\033[1;32m== %s\033[0m\n' "$*" >&2; }

usage() {
    sed -n '2,32p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit 0
}

# ---------------------------------------------------------------- 参数
need_val() {                            # need_val <选项名> <参数个数>
    [ "$2" -ge 2 ] || die "$1 需要一个值（看 --help）"
}

# ---------------------------------------------------------------- --list
list_official() {
    cat <<'EOF'
官方 Radxa Zero 3W 镜像（Debian 12 bookworm）

  ⚠ 重要变化（2025-07 起）：Radxa 已停止发布 bookworm **CLI** 镜像。
    最新 release（rsdk-b1, 2025-07-15）只提供 KDE 桌面版，官方说明：
    "Radxa now only supports the Debian Desktop image.
     Other variants that were previously provided AS-IS are no longer provided."

  → 现在正确选择：KDE 桌面版（约 1.4 GB），构建脚本会自动关掉 sddm/KDE
    （切 multi-user.target，包不卸载，以后能救回来），内存留给 zeluxd。

  发布页：https://github.com/radxa-build/radxa-zero3/releases
  文件名：radxa-zero3_bookworm_kde_*.output_512.img.xz

  下载参考：
    # 直连
    curl -fL -O https://github.com/radxa-build/radxa-zero3/releases/download/rsdk-b1/radxa-zero3_bookworm_kde_b1.output_512.img.xz

    # 国内强烈建议用 aria2 多线程（16 线能跑满，1.4 GB 只要几分钟）
    aria2c -x16 -s16 -k5M -c -o rk3w-base.img.xz "<上面那个 URL>"

    # 断点续传：重跑同一条 aria2c 命令即可（一定要带 -c）
    # 下完务必核对：xz -t 通过才算完整（aria2 中途断过会导致文件比预期大但内容缺失）

  下载完自查：
    xz -t rk3w-base.img.xz && xz -l rk3w-base.img.xz
    # 期望：约 1.39 GB 压缩 / 7.7 GB 解压 / CRC64

  ⚠ 别用 bullseye CLI 旧版（2024-01 的 b6）：Debian 11 自带 Python 3.9，
    本项目代码用了 `str | None` 等 3.10+ 语法，跑了直接 SyntaxError。

  ⚠ 宿主是 Ubuntu 22.04 / Debian 11 时请加 --no-grow：
    那边的 e2fsprogs 1.46.5 认不出 bookworm 的 orphan_file 特性（FEATURE_C12），
    e2fsck / resize2fs 都会拒绝执行。跳过宿主扩容不影响使用——
    板子首启的 zelux-firstboot 会用配套新版工具把分区撑满。
EOF
}

# ---------------------------------------------------------------- 前置校验
check_platform() {
    [ "$(uname -s)" = "Linux" ] || die "只能在 Linux / WSL2 上跑（当前 $(uname -s)）。
      Windows 上请装 WSL2：wsl --install -d Ubuntu，然后在 WSL 里 `sudo apt install -y xz-utils rsync parted e2fsprogs`"
    if grep -qi microsoft /proc/version 2>/dev/null; then
        log "检测到 WSL2：loop 设备可用，但镜像必须放在 WSL 自己的文件系统里（/home 下），"
        log "不要放在 /mnt/c —— 那上面 losetup/rsync 会慢十倍且偶发失败"
    fi
}

check_root() {
    [ "$(id -u)" -eq 0 ] || die "要 root：sudo $PROG --base <img.xz>"
}

check_tools() {
    local missing=()
    local t
    for t in xz losetup parted partx e2fsck resize2fs rsync blkid findmnt sha256sum \
             stat truncate install awk sed grep mount umount lsblk dtc sha256sum; do
        command -v "$t" >/dev/null 2>&1 || missing+=("$t")
    done
    if [ "${#missing[@]}" -gt 0 ]; then
        die "缺工具：${missing[*]}
     Debian/Ubuntu：sudo apt install -y xz-utils rsync parted e2fsprogs util-linux coreutils gdisk device-tree-compiler"
    fi
    command -v sgdisk >/dev/null 2>&1 || warn "没有 sgdisk（gdisk 包）：GPT 扩容时备份表可能不迁移，能用但建议装上"
    command -v systemctl >/dev/null 2>&1 || warn "宿主机没有 systemctl：跳过离线 enable 检查"
    if command -v pip3 >/dev/null 2>&1 || command -v pip >/dev/null 2>&1; then :; else
        [ "$WHEELHOUSE" -eq 1 ] && warn "没有 pip：--wheelhouse 会被跳过"
    fi
}

check_overlay() {
    [ -d "$OVERLAY_DIR" ] || die "没有 overlay 目录：$OVERLAY_DIR"
    [ -f "$OVERLAY_DIR/etc/zelux/zelux.toml" ] || die "overlay 缺 etc/zelux/zelux.toml"
    [ -f "$OVERLAY_DIR/usr/local/bin/zelux-firstboot" ] || die "overlay 缺 zelux-firstboot"
    [ -f "$OVERLAY_DIR/usr/local/bin/fanctl" ] || die "overlay 缺 fanctl"
    [ -d "$SOFTWARE_DIR" ] || die "没有 software 目录：$SOFTWARE_DIR"

    local f b
    for f in "$UNITS_DIR"/*.service; do
        [ -e "$f" ] || continue
        b="$(basename "$f")"
        if [ -f "$OVERLAY_DIR/etc/systemd/system/$b" ]; then
            if ! cmp -s "$f" "$OVERLAY_DIR/etc/systemd/system/$b"; then
                warn "单元文件有两份且不一致：software/systemd/$b != overlay/.../$b"
                warn "构建以 software/systemd 为准（overlay 那份会被覆盖）；建议 cp 一下保持仓库一致"
            fi
        fi
    done
}

resolve_base() {
    [ -n "$BASE" ] || die "必须给 --base <官方 img.xz 路径或 URL>（--list 看在哪下）"
    case "$BASE" in
        http://*|https://*)
            command -v curl >/dev/null 2>&1 || die "给了 URL 但没有 curl"
            mkdir -p "$SCRIPT_DIR/downloads"
            local name dest
            name="$(basename "${BASE%%\?*}")"
            dest="$SCRIPT_DIR/downloads/$name"
            if [ -s "$dest" ]; then
                log "已经下载过：$dest（要用新的就删掉它）"
            else
                log "下载到 $dest（几百 MB，慢慢等；断了重跑会续传）"
                curl -fL --retry 3 --retry-delay 3 -C - -o "$dest" "$BASE" \
                    || die "下载失败。国内网络建议手动下载后用 --base ./xxx.img.xz"
            fi
            BASE="$dest"
            ;;
    esac

    [ -e "$BASE" ] || die "找不到 $BASE"
    if [ -b "$BASE" ]; then
        die "$BASE 是块设备。--base 要的是镜像**文件**（img.xz），不是磁盘设备。
     把设备当镜像传进来会直接写坏它；烧写请用 image/flash/ 里的脚本。"
    fi
    case "$BASE" in
        /dev/*) die "拒绝使用 /dev 下的路径：$BASE" ;;
    esac
    [ -f "$BASE" ] || die "$BASE 不是普通文件"
    [ -r "$BASE" ] || die "$BASE 读不了（权限？）"
    [ -s "$BASE" ] || die "$BASE 是空文件"
}

check_space() {
    local need avail
    need=$(( $(stat -c %s "$BASE") * 2 + 3 * GIB ))
    avail=$(( $(df -Pk "$WORK_DIR" | awk 'NR==2{print $4}') * 1024 ))
    if [ "$avail" -lt "$need" ]; then
        die "空间不够：$WORK_DIR 需要约 $((need / GIB)) GB，只剩 $((avail / GIB)) GB。
     换个 --work-dir（比如 /data），或先清掉 build/ 里的旧镜像"
    fi
    log "磁盘余量 OK（需要约 $((need / GIB)) GB，可用 $((avail / GIB)) GB）"
}

# ---------------------------------------------------------------- 清理（trap）
cleanup() {
    local rc=$?
    set +e
    if [ "$BOOT_MOUNTED" -eq 1 ]; then
        umount "$MNT$BOOT_MNT_REL" 2>/dev/null || umount -l "$MNT$BOOT_MNT_REL" 2>/dev/null
        BOOT_MOUNTED=0
    fi
    if [ "$ROOT_MOUNTED" -eq 1 ]; then
        umount "$MNT" 2>/dev/null || umount -l "$MNT" 2>/dev/null
        ROOT_MOUNTED=0
    fi
    if [ -n "$LOOP" ]; then
        losetup -d "$LOOP" 2>/dev/null || true
        LOOP=""
    fi
    if [ -n "$MNT" ] && [ -d "$MNT" ]; then
        rmdir "$MNT" 2>/dev/null || true
    fi
    if [ "$rc" -ne 0 ] && [ "$WORK_STARTED" -eq 1 ]; then
        printf '\033[1;31m[build] xx\033[0m 失败退出（%s）。中间产物留在 %s，排查完可以删掉\n' "$rc" "$WORK_DIR" >&2
    fi
    exit "$rc"
}
trap cleanup EXIT INT TERM

# ---------------------------------------------------------------- 解压
decompress_base() {
    local out="$1"
    case "$BASE" in
        *.xz)   log "解压（xz -dc，几分钟）"; xz -dc -- "$BASE" > "$out" ;;
        *.gz)   log "解压（gzip -dc）"; gzip -dc -- "$BASE" > "$out" ;;
        *.img)  log "已经是 .img，直接复制"; cp --sparse=always -- "$BASE" "$out" ;;
        *)
            if xz -l -- "$BASE" >/dev/null 2>&1; then
                log "没有 .xz 后缀但确实是 xz，按 xz 解"
                xz -dc -- "$BASE" > "$out"
            else
                log "当作裸 img 复制"
                cp --sparse=always -- "$BASE" "$out"
            fi
            ;;
    esac
    [ -s "$out" ] || die "解压出来是空文件：$BASE 可能坏了（xz -t 验一下）"
}

# ---------------------------------------------------------------- 分区
find_partitions() {
    local p fstype
    ROOT_PART=""
    BOOT_PART=""
    # 有的内核/loop 组合 -P 之后不会自动建 p* 节点，手工补一刀
    if ! ls "$LOOP"p* >/dev/null 2>&1; then
        partx -a "$LOOP" >/dev/null 2>&1 || true
        sleep 1
    fi
    for p in "$LOOP"p*; do
        [ -e "$p" ] || continue
        fstype="$(blkid -o value -s TYPE "$p" 2>/dev/null || true)"
        [ -n "$fstype" ] || continue
        log "  $p  ->  $fstype"
        case "$fstype" in
            ext4|ext3)
                [ -n "$ROOT_PART" ] || ROOT_PART="$p"
                ;;
            vfat|fat|msdos)
                [ -n "$BOOT_PART" ] || BOOT_PART="$p"
                ;;
        esac
    done
    [ -n "$ROOT_PART" ] || die "没找到 ext4 分区（这个镜像不是 Radxa Debian？）"
    [ -n "$BOOT_PART" ] || warn "没找到 FAT32 分区，boot 不单独挂载"
}

part_num() { local p="$1"; printf '%s' "${p##*p}"; }

# 第一步：把镜像**文件**长大。
# 必须在 losetup 之前做：loop 设备容量是 attach 那一刻从文件大小定下来的，
# attach 之后再 truncate，内核看不到新增的尾部（sgdisk -e / parted 都会算错位置）。
GROW_WANTED=0
prepare_image_size() {
    local cur target
    cur="$(stat -c %s "$IMG")"

    if [ "$NO_GROW" -eq 1 ]; then
        log "--no-grow：保持原大小（分区不动）"
        return 0
    fi
    if [ -n "$SIZE_GB" ]; then
        case "$SIZE_GB" in ''|*[!0-9]*) die "--size-gb 要是整数（单位 GB），收到：$SIZE_GB" ;; esac
        target=$(( SIZE_GB * GIB ))
        if [ "$target" -le "$cur" ]; then
            warn "--size-gb $SIZE_GB 不大于原镜像（$((cur / GIB)) GB），不扩容"
            return 0
        fi
        log "目标容量：$SIZE_GB GB"
    else
        target=$(( cur + DEFAULT_SPARE_BYTES ))
        log "自动加 2 GB 余量：$((cur / MIB)) MiB -> $((target / MIB)) MiB"
    fi

    truncate -s "$target" "$IMG" || die "truncate 失败（工作区文件系统不支持稀疏文件？）"
    GROW_WANTED=1
}

# 第二步：扩分区 + 扩文件系统（此时 loop 已经是新容量）
grow_partition() {
    [ "$GROW_WANTED" -eq 1 ] || return 0

    # 根分区必须是最后一个：否则扩容等于把后面的分区吞掉
    local last
    # 注意：列名是 PARTNUM 不是 PARTN。util-linux 2.37（Ubuntu 22.04 / Debian 11 常见）
    # 没有 PARTN 这个别名，直接用会报 "unknown column" 并让整个构建挂掉。
    # 更稳的做法是不依赖 lsblk 的列名，直接从 sysfs 读分区号。
    local last=""
    if [ -d "/sys/block/$(basename "$LOOP")" ]; then
        last="$(ls "/sys/block/$(basename "$LOOP")" 2>/dev/null | sed -n 's/^'"$(basename "$LOOP")"'p\([0-9]\+\)$/\1/p' | sort -n | tail -1)"
    fi
    if [ -z "$last" ]; then
        last="$(lsblk -lno NAME,TYPE "$LOOP" 2>/dev/null | awk '$2=="part"{print $1}' | sed 's/.*p\([0-9]\+\)$/\1/' | sort -n | tail -1)"
    fi
    [ -n "$last" ] || die "识别不出分区号（lsblk/sysfs 都没读出来）"
    if [ "$last" != "$(part_num "$ROOT_PART")" ]; then
        warn "根分区是第 $(part_num "$ROOT_PART") 个，最后一个是第 $last 个：跳过扩容（先扩文件没意义）"
        return 0
    fi

    # GPT：先把备份表挪到新末尾，否则 parted 会警告并可能写坏
    local pttype
    pttype="$(blkid -o value -s PTTYPE "$LOOP" 2>/dev/null || true)"
    if [ "$pttype" = "gpt" ] && command -v sgdisk >/dev/null 2>&1; then
        sgdisk -e "$LOOP" >/dev/null 2>&1 || warn "sgdisk -e 失败（继续，parted 一般也能处理）"
    fi

    log "扩第 $(part_num "$ROOT_PART") 个分区到 100%"
    parted --script "$LOOP" "resizepart $(part_num "$ROOT_PART") 100%" || die "parted 扩分区失败"
    partx -u "$LOOP" 2>/dev/null || partprobe "$LOOP" 2>/dev/null || warn "分区表重读失败，继续试"
    sleep 1

    local rc=0
    e2fsck -f -y "$ROOT_PART" || rc=$?
    # 退出码含义：0/1 = 没问题或有小问题已修好；>=2 才是真错。
    # 但有个已知的"假错误"：e2fsck 版本比镜像新的时候会报
    #   "filesystem has unsupported feature(s): FEATURE_C12"
    # FEATURE_C12 是 ext4 的 orphan_file（Linux 5.15+ / e2fsprogs 1.47+ 引入），
    # Debian 12 镜像默认带上，而 Ubuntu 22.04 的 e2fsprogs 只有 1.46.5，认不出来。
    # 这种情况下文件系统本身是好的，只是检查工具太旧 —— 不该让整个构建失败。
    # 处理：只对根分区做"在线扩容"（resize2fs 不需要先 fsck），扩完再由首启的
    # growpart/resize2fs 在板子本体上（bookworm，工具是新的）复查一遍。
    if [ "$rc" -ge 8 ]; then
        # 8 = 操作错误 / 12 = 用法或版本问题（我们的场景就是 12）
        if [ "$rc" -eq 12 ] || [ "$rc" -eq 8 ]; then
            warn "e2fsck 退出码 $rc：疑似 e2fsprogs 版本比镜像旧（认不出新 ext4 特性）"
            warn "跳过 fsck 直接 resize2fs；真正的一致性检查交给板子首启（那边工具是配套的）"
            # resize2fs 在识别不了 orphan_file 时也可能报错，那就退回 tune2fs 清标记再试
            if ! resize2fs "$ROOT_PART" 2>/tmp/resize.err; then
                warn "resize2fs 首试失败：$(head -2 /tmp/resize.err | tr '\n' ' ')"
                warn "尝试清掉宿主不认识的特性标记后再扩"
                tune2fs -O ^orphan_file "$ROOT_PART" 2>/dev/null || true
                resize2fs "$ROOT_PART" || die "resize2fs 仍失败（见 /tmp/resize.err）"
            fi
        else
            die "e2fsck 失败（退出码 $rc）"
        fi
    elif [ "$rc" -gt 1 ]; then
        die "e2fsck 失败（退出码 $rc）"
    else
        resize2fs "$ROOT_PART" || die "resize2fs 失败"
    fi
    log "文件系统已扩到 $(dumpe2fs -h "$ROOT_PART" 2>/dev/null | awk -F: '/Block count/{gsub(/ /,"",$2); print $2}' || echo "?") 块"
}

# ---------------------------------------------------------------- rootfs 内容
# 下面所有函数都在删/写 "$MNT/..."，MNT 一旦为空就是"对宿主机根目录动手"。
# 每个写操作前都过一遍这个闸，宁可报错也不冒险。
require_rootfs() {
    if [ -z "${MNT:-}" ] || [ "$ROOT_MOUNTED" -ne 1 ] || [ ! -f "${MNT}/etc/os-release" ]; then
        die "rootfs 没有正确挂载（MNT=${MNT:-<空>}）：拒绝继续写入/清理"
    fi
}

inject_overlay() {
    require_rootfs
    step "注入 overlay"
    rsync -aHAX --numeric-ids "$OVERLAY_DIR/" "$MNT/"
    # A Windows working tree can still contain CRLF despite the checkout attributes.
    # Normalize the image copies only; do not rewrite the developer's source checkout.
    local script
    for script in "$OVERLAY_DIR/usr/local/bin/"* "$OVERLAY_DIR/usr/local/sbin/"*; do
        [ ! -f "$script" ] || sed -i 's/\r$//' "$MNT/${script#"$OVERLAY_DIR/"}"
    done
    mkdir -p "$MNT/usr/local/libexec"
    install -D -m 0755 "$SCRIPT_DIR/tools/build-pwm-overlays.sh" "$MNT/usr/local/libexec/zelux-build-pwm-overlays"
    # 单元文件以 software/systemd 为唯一真源（overlay 里那份是给"手工 rsync"用的副本）
    local f b
    for f in "$UNITS_DIR"/*.service; do
        [ -e "$f" ] || continue
        b="$(basename "$f")"
        install -D -m 0644 "$f" "$MNT/etc/systemd/system/$b"
    done
}

install_software() {
    require_rootfs
    local rel="$MNT/opt/zelux/releases/$VERSION"
    step "安装软件到 /opt/zelux/releases/$VERSION"
    mkdir -p "$rel/software" "$MNT/opt/zelux/releases" "$MNT/opt/zelux"
    rsync -aHAX --numeric-ids \
        --exclude '__pycache__/' --exclude '*.pyc' --exclude '.pytest_cache/' \
        --exclude 'var/' \
        "$SOFTWARE_DIR/" "$rel/software/"

    # 前端目录还没有时给个占位：FastAPI 挂 StaticFiles(check_dir) 会直接起不来，
    # 那比"网页 404"难查得多
    if [ ! -d "$rel/software/web" ]; then
        mkdir -p "$rel/software/web"
        cat > "$rel/software/web/index.html" <<'HTML'
<!doctype html><meta charset="utf-8"><title>ZELUX</title>
<body style="font:16px system-ui;background:#0B0F14;color:#F6F8FA;padding:40px">
<h1 style="color:#00D8A0">ZELUX Duck Studio</h1>
<p>后端已经在跑，但这份镜像里没有打包前端。</p>
<p>把 <code>software/web/</code> 放进来重新构建（或 <code>install.sh</code> 一次）。</p>
</body>
HTML
        warn "software/web 不存在：镜像里放了占位页（后端能起，页面是提示）"
    fi

    ln -sfn "releases/$VERSION" "$MNT/opt/zelux/current"
    printf '%s\n' "$VERSION" > "$MNT/opt/zelux/VERSION"
    chmod 755 "$MNT/opt/zelux" "$MNT/opt/zelux/releases" 2>/dev/null || true
    rmdir "$MNT/opt/zelux/releases/$VERSION/software/var" 2>/dev/null || true
}

create_user() {
    require_rootfs
    step "创建 zelux 用户"
    local root="$MNT"
    if grep -q '^zelux:' "$root/etc/passwd"; then
        log "zelux 用户已存在，跳过"
    else
        # --root 只做文件操作，不会执行目标架构的二进制（宿主机是 x86 也能用）
        useradd --root "$root" --user-group --shell /bin/bash --comment "ZELUX Duck Studio" \
            --home-dir /home/zelux zelux 2>/dev/null \
            || die "useradd --root 失败。宿主机要有 shadow-utils；或在 debootstrap 后的系统上跑"
    fi
    mkdir -p "$root/home/zelux"
    local uid gid
    uid="$(awk -F: '$1=="zelux"{print $3}' "$root/etc/passwd")"
    gid="$(awk -F: '$1=="zelux"{print $3}' "$root/etc/group")"
    [ -n "$uid" ] || die "建完 zelux 却读不到 uid"
    chown -R "$uid:$gid" "$root/home/zelux"
    chmod 750 "$root/home/zelux"

    # 硬件组：缺了就建，保证 zelux 不用 sudo 也能开 ttyS2 / i2c-3
    local g
    for g in gpio i2c spi dialout video audio netdev plugdev; do
        if ! grep -q "^$g:" "$root/etc/group"; then
            groupadd --root "$root" -r "$g" 2>/dev/null || warn "建 $g 组失败（跳过）"
        fi
        if grep -q "^$g:" "$root/etc/group"; then
            usermod --root "$root" -a -G "$g" zelux 2>/dev/null || warn "把 zelux 加进 $g 失败"
        fi
    done

    # 系统口令（SSH/HDMI 登录用；网页口令是另一套，首启才写 auth.json）
    # 从 TOML 读，保持"口令只有一个来源"
    local pass hash=""
    pass="$(python3 -c 'import sys,tomllib;print((tomllib.load(open(sys.argv[1],"rb")).get("system") or {}).get("password","zelux"))' \
        "$root/etc/zelux/zelux.toml" 2>/dev/null || true)"
    [ -n "$pass" ] || pass="zelux"
    if command -v openssl >/dev/null 2>&1; then
        hash="$(openssl passwd -6 -salt zeluxduck "$pass" 2>/dev/null || true)"
    fi
    if [ -n "$hash" ]; then
        usermod --root "$root" -p "$hash" zelux || warn "写口令失败"
        log "zelux 系统口令已设为默认值（首启会用 TOML 里的口令再设一次）"
    else
        warn "没有 openssl：zelux 暂时没有系统口令，首启的 chpasswd 会补上"
    fi
}

prepare_dirs() {
    require_rootfs
    local root="$MNT"
    mkdir -p "$root/var/lib/zelux/models" "$root/var/lib/zelux/shots" "$root/var/lib/zelux/backup"
    local uid gid
    uid="$(awk -F: '$1=="zelux"{print $3}' "$root/etc/passwd" 2>/dev/null || echo 1000)"
    gid="$(awk -F: '$1=="zelux"{print $3}' "$root/etc/group" 2>/dev/null || echo 1000)"
    chown -R "$uid:$gid" "$root/var/lib/zelux/models" "$root/var/lib/zelux/shots"
    chown "$uid:$gid" "$root/var/lib/zelux"
    chmod 750 "$root/var/lib/zelux"
    chmod 700 "$root/var/lib/zelux/backup"
    rm -f "$root/var/lib/zelux/.initialized"        # 必须是"没初始化"状态
}

disable_cloud_init() {
    require_rootfs
    [ -d "$MNT/etc/cloud" ] || { log "没有 cloud-init，跳过"; return 0; }
    step "关掉 cloud-init（它会覆盖我们写的 hostname/用户/网络）"
    mkdir -p "$MNT/etc/cloud/cloud.cfg.d"
    cat > "$MNT/etc/cloud/cloud.cfg.d/99-zelux.cfg" <<'EOF'
# ZELUX：cloud-init 在 Radxa 镜像里负责"首次开机建用户/配网络"，
# 而这两件事我们用自己的 zelux-firstboot + NetworkManager 做。
# 两边同时改 /etc/hostname 和 sshd 配置必然打架，所以这里彻底禁掉。
datasource_list: [ None ]
EOF
    : > "$MNT/etc/cloud/cloud-init.disabled"

    local u
    for u in cloud-init cloud-init-local cloud-config cloud-final cloud-init-hotplugd; do
        # 删掉启用软链 + 用 /dev/null 遮蔽，双保险
        find "$MNT/etc/systemd/system" -maxdepth 2 -type l -name "${u}.service" -delete 2>/dev/null || true
        find "$MNT/etc/systemd/system" -maxdepth 2 -type l -name "${u}" -delete 2>/dev/null || true
        ln -sfn /dev/null "$MNT/etc/systemd/system/${u}.service"
    done
    rm -rf "$MNT/var/lib/cloud/instances" 2>/dev/null || true
}

disable_desktop() {
    require_rootfs
    # Radxa 官方现在只发 KDE 桌面版（rsdk-b1 起不再提供 CLI 版）。
    # 桌面在我们这台上是没有意义的：ZELUX 只用 8000 端口的网页 + 一个 Python 进程，
    # 而 sddm + KDE 常驻要吃掉 600–900 MB 内存（3W 只有 2/4/8 GB），
    # 还会抢 framebuffer / GPU，首启也慢。所以这里把图形栈关掉，但**不卸载**——
    # 留着以后想接 HDMI 调试时用 `systemctl set-default graphical.target` 能救回来。
    local root="$MNT"
    local dm found=""
    # 逐个找显示管理器：不同 Radxa 版本可能是 sddm / lightdm / gdm3
    for dm in sddm lightdm gdm3 gdm xdm lxdm nodm; do
        if [ -e "$root/lib/systemd/system/${dm}.service" ] || \
           [ -e "$root/usr/lib/systemd/system/${dm}.service" ] || \
           [ -e "$root/etc/systemd/system/${dm}.service" ]; then
            found="$found $dm"
        fi
    done
    # graphical.target 的 wants 软链是真正让它开机自启的东西
    local gwants="$root/etc/systemd/system/graphical.target.wants"
    local gtarget=""
    if [ -d "$gwants" ]; then
        gtarget="$(ls "$gwants" 2>/dev/null | tr '\n' ' ')"
    fi
    if [ -z "$found" ] && [ -z "$gtarget" ]; then
        log "没发现桌面/显示管理器，跳过（本来就是个 CLI 镜像）"
        return 0
    fi
    step "关掉图形桌面（$found）——内存留给 zeluxd"
    # 1) 默认启动目标改成 multi-user（纯命令行）
    if [ -e "$root/etc/systemd/system/default.target" ] || [ -L "$root/etc/systemd/system/default.target" ]; then
        rm -f "$root/etc/systemd/system/default.target"
    fi
    ln -sfn /lib/systemd/system/multi-user.target "$root/etc/systemd/system/default.target"
    # 2) 用 /dev/null 遮蔽显示管理器（软链到 /dev/null 是 systemd 官方的禁用手法，
    #    比 rm 单元文件更可逆，也比 disable 更保险——disable 只删软链，别名仍可能被拉起）
    for dm in $found; do
        mkdir -p "$root/etc/systemd/system"
        ln -sfn /dev/null "$root/etc/systemd/system/${dm}.service"
        rm -f "$gwants/${dm}.service" 2>/dev/null || true
    done
    # 3) 清掉 graphical.target.wants 里的其他图形相关单元（plasma-*、xdg-*、colord 等）
    if [ -d "$gwants" ]; then
        rm -rf "$gwants"
    fi
    # 4) KDE 的 baloo 索引器：开机扫全盘建索引，在 SD 卡上是灾难
    local b
    for b in baloo_file baloo_file_extractor kdeconnectd; do
        find "$root/etc/systemd/system" -maxdepth 2 -name "${b}*" -delete 2>/dev/null || true
    done
    # 5) 用户级 autostart：新用户登录时不再拉起 KDE 会话（我们用 zelux 用户跑服务，不登录桌面）
    rm -rf "$root/etc/xdg/autostart/plasma-workspace.target.desktop" 2>/dev/null || true
    log "已切到 multi-user.target；显示管理器已遮蔽（$found）"
    log "想恢复桌面：sudo systemctl set-default graphical.target（镜像里包没卸）"
}

# ---------------------------------------------------------------- 网络栈修复（关键）
# 这里有一段**踩过坑的历史**，改这个函数前务必读完：
#
# ⚠ 教训（v2 镜像的回归，症状："原来是能搜到 WiFi 的，现在连网络都搜不到了"）：
#   曾经以为 wpa_supplicant.service 是「standalone 模式抢 wlan0」的元凶，把它用
#   /dev/null 遮蔽了。这是**错的**，而且把整块无线彻底弄哑。
#
#   事实（对着镜像里的二进制验过）：
#   · Debian 12 的 NetworkManager **自己不会去 spawn wpa_supplicant**
#     —— `strings /usr/sbin/NetworkManager` 里根本没有 /sbin/wpa_supplicant 这种
#     可执行路径常量（对比 dnsmasq 就有 `/usr/sbin/dnsmasq`，那个才是 NM 亲自 spawn 的）。
#   · NM 走的是 **D-Bus 激活**：NM 请求服务名 fi.w1.wpa_supplicant1 →
#     /usr/share/dbus-1/system-services/fi.w1.wpa_supplicant1.service
#        （里面写着 SystemdService=wpa_supplicant.service）→
#     systemd 去拉起 wpa_supplicant.service。
#   · 一旦 wpa_supplicant.service 被遮蔽，systemd 认为这个单元是 masked，
#     D-Bus 激活立刻失败，NM 日志出现
#     「Failed to D-Bus activate wpa_supplicant service」，
#     结果是 NM 手上没有 supplicant → WiFi 网卡不可用 → **连扫描都做不了**。
#
#   而且那个单元根本不是 "standalone 抢网卡"：
#     ExecStart=/sbin/wpa_supplicant -u -s -O "DIR=/run/wpa_supplicant GROUP=netdev"
#     `-u` = 只提供 D-Bus 服务，**没有 -i <iface>**，所以它不碰 wlan0，
#     它就是 NM 需要的那份 supplicant 后端。是必需品，不是争抢者。
#
# 需要遮蔽的只有 dnsmasq.service：
#   · dnsmasq.service 常驻占 53 端口（默认绑 0.0.0.0）→ NM 的
#     ipv4.method=shared 会**自己 spawn** 一个 dnsmasq 来发 DHCP/DNS，
#     它带的是 `--conf-file=/dev/null --listen-address=<AP 地址>`，
#     两个 dnsmasq 抢 53 端口 → 热点 SSID 广播得出去，但手机连上拿不到 IP，
#     表现就是「WiFi 显示了却一直转圈 / 连不上」。
#   注意：要让 NM 能 spawn，dnsmasq **二进制**必须在（包 dnsmasq-base），
#   只是那个常驻服务不能跑 —— 「包在」和「服务跑」是两件事。
fix_network_stack() {
    require_rootfs
    local root="$MNT"
    local wants="$root/etc/systemd/system/multi-user.target.wants"
    step "修复网络栈（dnsmasq 冲突；wpa_supplicant 必须保持启用）"

    # 1) wpa_supplicant.service：**必须保持「已启用且未被遮蔽」**。
    #    下面这段是"反向操作"——专门清理早期版本误加的 /dev/null 遮蔽，
    #    把它恢复成 base 镜像原本的样子（multi-user.target.wants 里的软链）。
    local wpa_target="/lib/systemd/system/wpa_supplicant.service"
    [ -e "$root$wpa_target" ] || wpa_target="/usr/lib/systemd/system/wpa_supplicant.service"
    if [ -e "$root$wpa_target" ]; then
        # 1a) 拆掉历史遗留的遮蔽（就是它让 NM 的 D-Bus 激活失败的）
        local p
        for p in "$root/etc/systemd/system/wpa_supplicant.service" \
                 "$root/etc/systemd/system/wpa_supplicant@.service"; do
            if [ -L "$p" ] && [ "$(readlink "$p" 2>/dev/null)" = "/dev/null" ]; then
                rm -f "$p"
                log "已移除遮蔽：${p#"$root"}（它挡住了 NM 的 D-Bus 激活 → WiFi 全哑）"
            fi
        done
        # 1b) 重新 enable（幂等）。NM 靠 D-Bus 激活这个单元来拿 supplicant。
        mkdir -p "$wants"
        ln -sfn "$wpa_target" "$wants/wpa_supplicant.service" 2>/dev/null || true
        log "wpa_supplicant.service 保持启用（NM 通过 D-Bus 激活它，绝对不能遮蔽）"
    else
        warn "镜像里没有 wpa_supplicant.service —— NM 拿不到 supplicant，WiFi 一定不可用"
    fi

    # 2) dnsmasq.service：遮蔽（让出 53 端口给 NM 自己 spawn 的那个）。
    #    二进制必须留着，见下面第 3 步。
    if [ -L "$wants/dnsmasq.service" ] || [ -e "$root/lib/systemd/system/dnsmasq.service" ] \
       || [ -e "$root/usr/lib/systemd/system/dnsmasq.service" ]; then
        rm -f "$wants/dnsmasq.service" 2>/dev/null || true
        mkdir -p "$root/etc/systemd/system"
        ln -sfn /dev/null "$root/etc/systemd/system/dnsmasq.service"
        log "已停用常驻 dnsmasq.service（让出 53 端口给 NM 的 shared 模式）"
    fi

    # 3) 确认 dnsmasq **二进制**在（NM shared 模式下要 exec 它，包名 dnsmasq-base）。
    #    注意：包要在、服务不能跑 —— 这是两件事，别一起删了。
    local dnsbin=""
    local d
    for d in /usr/sbin/dnsmasq /usr/bin/dnsmasq; do
        [ -x "$root$d" ] && dnsbin="$d" && break
    done
    if [ -n "$dnsbin" ]; then
        log "dnsmasq 可执行文件在：$dnsbin（供 NM 调用，不常驻）"
    else
        warn "没找到 dnsmasq 可执行文件 —— 热点会给不出 DHCP，手机连上没 IP"
        # 尽力从官方镜像的 deb 缓存/包管理里找；找不到就让首启去装
        log "首启阶段会尝试 apt-get install -y dnsmasq-base（见 zelux-firstboot）"
    fi

    # 4) NetworkManager 的补充配置。
    #    ⚠ 不要在这里写 `plugins=keyfile`：那会把 base 镜像默认的
    #      `plugins=ifupdown,keyfile` 覆盖掉，属于无谓偏离基线（早期版本这么干过，
    #      注释还写着"把 D-Bus 后端交给 NM 统一管理"，那句话跟 plugins 毫无关系，是错的）。
    #      网卡可见性/扫描能力跟 plugins 无关，只跟 supplicant 有关。
    mkdir -p "$root/etc/NetworkManager/conf.d"
    cat > "$root/etc/NetworkManager/conf.d/20-zelux.conf" <<'EOF'
# ZELUX 补充配置（保持最小化，尽量不偏离 base 镜像基线）
[device]
# 关掉扫描时的 MAC 随机化：Zero 3W 的 brcmfmac / AIC8800 在 AP 模式下
# 随机 MAC 会让部分手机认不出同一个热点，关掉最稳。
wifi.scan-rand-mac-address=no

[connection]
# 兜底热点激活后不要因为"检测不到互联网"就自己断开
# （0 = 无限重试，NM 的默认是 -1 走全局值）
connection.autoconnect-retries=0
EOF
    log "已写入 /etc/NetworkManager/conf.d/20-zelux.conf"

    # 5) dnsmasq 的 lease 权限（热点"SSID 有了但拿不到 IP"的真凶）。
    #    NM 在 ipv4.method=shared 时会 spawn：
    #      /usr/sbin/dnsmasq --conf-file=/dev/null --keep-in-foreground \
    #        --dhcp-range=192.168.4.10,192.168.4.254,60m \
    #        --dhcp-leasefile=/var/lib/NetworkManager/dnsmasq-<if>.leases ...
    #    两个坑叠在一起：
    #      a) Debian 的 dnsmasq 编译默认 user=nobody，启动后立刻 setuid 降权；
    #      b) NM 传了 --conf-file=/dev/null，所以 /etc/dnsmasq.conf 里的 user= 根本不生效；
    #      c) 而 /var/lib/NetworkManager 是 0700 root:root（Radxa 镜像原样）。
    #    结果：nobody 进不去目录 → 写不了 lease → dnsmasq 直接退出
    #    → 手机连上 SSID 后一直停在"正在获取 IP 地址" → 用户看到的就是"网页打不开"。
    #    解法：给 NM 的 shared 模式加一个 drop-in，显式 user=root。
    #    风险可控：这个 dnsmasq 只监听 192.168.4.1 的 53/67，生命周期跟着 NM 走，
    #    而且系统级的 dnsmasq.service 已经被遮蔽了（见第 2 步）。
    local nmdir="$root/var/lib/NetworkManager"
    mkdir -p "$nmdir"
    chown 0:0 "$nmdir" 2>/dev/null || true
    chmod 0755 "$nmdir" 2>/dev/null || true
    mkdir -p "$root/etc/NetworkManager/dnsmasq-shared.d"
    cat > "$root/etc/NetworkManager/dnsmasq-shared.d/00-zelux-lease.conf" <<'EOF'
# ZELUX：NM 在 shared（热点）模式 spawn 的 dnsmasq 不要降权到 nobody。
#
# 原因：Debian 的 dnsmasq 编译默认 user=nobody，而 NM 传 --conf-file=/dev/null
# 让 /etc/dnsmasq.conf 失效，所以启动后必然 setuid 到 nobody。
# NM 指定的 lease 文件在 /var/lib/NetworkManager（0700 root:root），nobody 写不了
# → dnsmasq 退出 → 手机连上热点拿不到 IP。
user=root
EOF
    log "已修复 dnsmasq lease 权限 + drop-in（热点 DHCP 才能真正发出 IP）"

    # 6) shared 模式还要在 /run/NetworkManager 建 dnsmasq.pid。
    #    镜像里 /run 是空的，用 tmpfiles 保证重启后目录还在。
    mkdir -p "$root/etc/tmpfiles.d"
    cat > "$root/etc/tmpfiles.d/zelux-network.conf" <<'EOF'
# ZELUX：NetworkManager shared 模式需要的运行时目录
d /run/NetworkManager 0755 root root -
EOF
    log "已写入 /etc/tmpfiles.d/zelux-network.conf"

    # 7) dnsmasq 的默认 lease 目录兜底
    mkdir -p "$root/var/lib/misc"
    chown 0:0 "$root/var/lib/misc" 2>/dev/null || true
    chmod 0755 "$root/var/lib/misc" 2>/dev/null || true
}

# ---------------------------------------------------------------- 固定设备树（关键）
# 为什么必须显式写死 fdt：
#   u-boot-update 生成的是 `fdtdir /usr/lib/linux-image-<ver>/`，而该目录下的
#   rockchip/ 子目录里同时躺着**三个** Radxa Zero 系列的 dtb：
#       rk3566-radxa-zero-3e.dtb            ← 3E 版本，没有 WiFi 模组
#       rk3566-radxa-zero-3w-ap6212.dtb     ← 3W + AP6212（brcmfmac）
#       rk3566-radxa-zero-3w-aic8800ds2.dtb ← 3W + AIC8800（SDIO）
#   U-Boot 的 `fdtdir` 是按 board name 去猜的，猜错就加载 3E 的 dtb ——
#   那上面根本没有 sdio/wifi 节点，wlan0 永远不会出现。
#   表现就是：板子亮灯、系统能起，但**连 WiFi 列表都刷不出来**，热点也无从谈起。
#   这不是"驱动没装"，驱动和固件都在（brcmfmac.ko / aic8800_*.ko / 全套 fw）。
# 做法：把 `fdtdir` 换成一句明确的 `fdt <具体文件>`，并把 bootargs 里的
#   dtb 覆盖参数清掉，让内核只看这一个文件。
# 选哪个由 ZELUX_DTB 决定，默认 ap6212（Zero 3W 出货最多的模组）。
fix_devicetree() {
    require_rootfs
    local root="$MNT"
    step "固定设备树（防止 U-Boot 误选 zero-3e 的无 WiFi dtb）"

    local conf="$root/boot/extlinux/extlinux.conf"
    [ -f "$conf" ] || { warn "没有 $conf，跳过 dtb 固定"; return 0; }

    # 1) 找内核版本对应的 dtb 目录
    local ddir=""
    local kver
    kver="$(sed -n 's/^[[:space:]]*linux .*vmlinuz-\(.*\)$/\1/p' "$conf" | head -1)"
    if [ -n "$kver" ] && [ -d "$root/usr/lib/linux-image-$kver/rockchip" ]; then
        ddir="$root/usr/lib/linux-image-$kver/rockchip"
    else
        ddir="$(find "$root/usr/lib" -maxdepth 3 -type d -name rockchip 2>/dev/null | head -1)"
    fi
    [ -n "$ddir" ] && [ -d "$ddir" ] || { warn "找不到 rockchip dtb 目录，跳过"; return 0; }

    # 2) 挑 dtb：显式指定优先，否则按板上实际能探测到的模组，最后默认 ap6212
    local want="${ZELUX_DTB:-}"
    local dtb=""
    if [ -n "$want" ]; then
        dtb="$(find "$ddir" -maxdepth 1 -name "*${want}*.dtb" 2>/dev/null | head -1)"
        [ -n "$dtb" ] || warn "ZELUX_DTB=$want 在镜像里找不到，回退自动选择"
    fi
    if [ -z "$dtb" ]; then
        # aic8800 的 dtb 名字里带 aic8800ds2；ap6212 的带 ap6212
        if [ -f "$ddir/rk3566-radxa-zero-3w-ap6212.dtb" ]; then
            dtb="$ddir/rk3566-radxa-zero-3w-ap6212.dtb"
        elif [ -f "$ddir/rk3566-radxa-zero-3w-aic8800ds2.dtb" ]; then
            dtb="$ddir/rk3566-radxa-zero-3w-aic8800ds2.dtb"
        fi
    fi
    [ -n "$dtb" ] && [ -f "$dtb" ] || { warn "找不到 rk3566-radxa-zero-3w-*.dtb，跳过"; return 0; }

    # 3) 必须是 3w 的，绝不能是 3e（3e 无 WiFi）
    case "$(basename "$dtb")" in
        *zero-3e*) error "选到了 3E 的设备树（没有 WiFi 模组），构建中止"; return 1 ;;
    esac
    local inst="/${dtb#"$root"}"
    log "选用设备树：$(basename "$dtb")"

    # 4) 把 fdtdir 行换成 fdt 行（两个 label 都要换）
    [ -f "$conf.zelux-backup" ] || cp -a "$conf" "$conf.zelux-backup"
    sed -i -E "s#^([[:space:]]*)fdtdir[[:space:]].*#\1fdt ${inst}#" "$conf"

    # 5) /etc/kernel/cmdline 里如果有 dtb= / fdtfile= 之类，一并清掉
    #    （u-boot-update 会拿它重新生成 extlinux.conf，不清就复活）
    if [ -f "$root/etc/kernel/cmdline" ]; then
        sed -i -E 's/(^|[[:space:]])(dtb|fdtfile)=[^[:space:]]*//g; s/[[:space:]]+/ /g' "$root/etc/kernel/cmdline"
    fi

    # 6) 顺便把 /etc/default/u-boot 钉死，免得下次 u-boot-update 又变回 fdtdir
    if [ -f "$root/etc/default/u-boot" ]; then
        if grep -qE '^#?U_BOOT_FDT=' "$root/etc/default/u-boot"; then
            sed -i -E "s|^#?U_BOOT_FDT=.*|U_BOOT_FDT=\"$(basename "$dtb")\"|" "$root/etc/default/u-boot"
        else
            printf 'U_BOOT_FDT="%s"\n' "$(basename "$dtb")" >> "$root/etc/default/u-boot"
        fi
        log "已钉住 /etc/default/u-boot 的 U_BOOT_FDT=$(basename "$dtb")"
    fi

    # 7) 结果自检：必须恰好剩下 fdt 行，不能再有 fdtdir
    if grep -qE '^[[:space:]]*fdtdir' "$conf"; then
        error "$conf 里还有 fdtdir（U-Boot 仍会自己猜）"; return 1
    fi
    if ! grep -qE "^[[:space:]]*fdt ${inst}$" "$conf"; then
        error "$conf 里的 fdt 行没写进去"; return 1
    fi
    log "已固定 fdt -> $inst"
    return 0
}

disable_serial_console() {
    require_rootfs
    # 舵机总线用 /dev/ttyS2 @ 1 Mbps。
    # ⚠ 注意 ttyFIQ0 和 ttyS2 是**同一个物理 UART2**：RK 平台默认让 fiq_debugger
    #   以 ttyFIQ0 的身份占用 UART2 做内核控制台，此时用户态就没有 ttyS2 可用了。
    #   Radxa 官方 bookworm 镜像的 cmdline 正是 `console=ttyFIQ0,1500000n8`，
    #   所以只匹配 ttyS2 是匹配不到的（早期版本踩过这个坑）。
    [ "$KEEP_SERIAL" -eq 1 ] && { log "--keep-serial-console：保留串口控制台（舵机总线可能不可用）"; return 0; }
    step "关掉串口控制台（UART2 留给舵机总线）"
    local f changed=0
    for f in "$MNT/boot/extlinux/extlinux.conf" "$MNT/boot/uEnv.txt" "$MNT/boot/armbianEnv.txt" \
             "$MNT/boot/cmdline.txt" "$MNT/etc/kernel/cmdline"; do
        [ -f "$f" ] || continue
        grep -qE 'console=(ttyS2|ttyFIQ0)' "$f" || continue
        if [ ! -f "$f.zelux-backup" ]; then
            cp -a "$f" "$f.zelux-backup"
        fi
        # earlycon 也要去掉：它在 console 初始化**之前**就往 UART2 打内核日志，
        # 那些字节会原样进舵机总线（舵机校验不过就丢，但偶发误动作查起来极难）。
        sed -i -E 's/console=(ttyS2|ttyFIQ0)(,[0-9]+[a-zA-Z0-9]*)?//g; s/earlycon=[^[:space:]]*//g; s/[[:space:]]+/ /g' "$f"
        # 总得留一个控制台，否则开机全黑。注意：要补在 append/extraargs 那一行里，
        # 直接往文件尾部 printf 会多出一行，extlinux 会当成垃圾指令。
        if ! grep -qE 'console=[^[:space:]]' "$f"; then
            case "$f" in
                */cmdline.txt|*/kernel/cmdline)
                    sed -i -E 's/[[:space:]]+$//; s/$/ console=tty1/' "$f"
                    ;;
                *)
                    if grep -qE '^[[:space:]]*(append|APPEND)' "$f"; then
                        sed -i -E 's/^([[:space:]]*(append|APPEND).*[^[:space:]])$/\1 console=tty1/' "$f"
                    else
                        warn "${f#"$MNT"} 里没找到 append 行，手动确认一下控制台"
                    fi
                    ;;
            esac
        fi
        log "已改：${f#"$MNT"}（备份 .zelux-backup）"
        changed=1
    done

    # extlinux.conf 改了还不够：bookworm 的 u-boot-update 会用 /etc/kernel/cmdline
    # 重新生成 extlinux.conf。如果那里还留着 ttyFIQ0，下次内核升级就会复活。
    if [ -f "$MNT/etc/kernel/cmdline" ] && grep -qE 'console=(ttyS2|ttyFIQ0)' "$MNT/etc/kernel/cmdline"; then
        log "/etc/kernel/cmdline 仍是旧控制台，清理后同步 extlinux"
    fi

    [ "$changed" -eq 0 ] && warn "没找到含 console=ttyS2/ttyFIQ0 的启动配置（可能已经去掉了，或用了别的方案）"

    # 串口 getty 也遮掉，免得有人开机后手动拉起抢总线
    mkdir -p "$MNT/etc/systemd/system"
    ln -sfn /dev/null "$MNT/etc/systemd/system/serial-getty@ttyS2.service" 2>/dev/null || true
    ln -sfn /dev/null "$MNT/etc/systemd/system/serial-getty@ttyFIQ0.service" 2>/dev/null || true
}

apply_perms() {
    require_rootfs
    local root="$MNT"
    step "固定权限（git/Windows 检出的位不可信）"
    chmod 755 "$root/usr/local/bin" "$root/usr/local/sbin" 2>/dev/null || true
    local f
    for f in "$root"/usr/local/bin/* "$root"/usr/local/sbin/*; do
        [ -f "$f" ] || continue
        chmod 755 "$f"
    done
    [ -f "$root/etc/zelux/zelux.toml" ] && chmod 644 "$root/etc/zelux/zelux.toml"
    for f in "$root"/etc/systemd/system/*.service; do
        [ -f "$f" ] && chmod 644 "$f"
    done
    # NetworkManager 会拒绝加载权限过宽/过窄的连接文件
    for f in "$root"/etc/NetworkManager/system-connections/*.nmconnection; do
        [ -f "$f" ] || continue
        chmod 600 "$f"
        chown 0:0 "$f" 2>/dev/null || true
    done
    chmod 644 "$root/etc/udev/rules.d/"*.rules 2>/dev/null || true
    chmod 644 "$root/etc/polkit-1/rules.d/"*.rules 2>/dev/null || true
    chmod 644 "$root/etc/tmpfiles.d/zelux.conf" 2>/dev/null || true
}

enable_units() {
    require_rootfs
    step "打开需要的服务"
    local root="$MNT"
    local wants="$root/etc/systemd/system/multi-user.target.wants"
    mkdir -p "$wants"
    # 手写软链而不是 systemctl --root：不依赖宿主 systemd 版本，结果可预期
    local u
    for u in zeluxd zelux-fand zelux-pwm-setupd zelux-firstboot; do
        ln -sfn "/etc/systemd/system/${u}.service" "$wants/${u}.service"
    done
    # sshd / NetworkManager：官方镜像一般已经开了，缺了就补
    local t
    for pair in "ssh.service:/lib/systemd/system/ssh.service" \
                "NetworkManager.service:/lib/systemd/system/NetworkManager.service"; do
        t="${pair%%:*}"
        if [ -e "$root/etc/systemd/system/$t" ] || [ -e "$root${pair#*:}" ] || [ -e "$root/usr/lib/systemd/system/$t" ]; then
            ln -sfn "/usr/lib/systemd/system/$t" "$wants/$t" 2>/dev/null || true
        fi
    done
    # zelux-update 是 oneshot，故意**不** enable（只能人工/OTA 触发）
    rm -f "$wants/zelux-update.service"
    log "已 enable：zeluxd zelux-fand zelux-pwm-setupd zelux-firstboot"
}

wheelhouse() {
    require_rootfs
    [ "$WHEELHOUSE" -eq 1 ] || { log "跳过离线轮子（要带就加 --wheelhouse）"; return 0; }
    step "预下载 aarch64 轮子（离线安装用）"

    # 为什么必须离线带轮子、不能靠首启联网装：
    #   板子的第一个网络就是它自己开的热点（192.168.4.1），那时候它**没有外网**。
    #   而 zelux-firstboot 在热点之后紧接着就要装 fastapi/uvicorn，
    #   于是 pip 必然失败 → zeluxd 退出码 78 → 网页永远打不开。
    #   这是个死循环：要装依赖得联网，要联网得先有网页。所以轮子必须烧进镜像。
    local wh="$MNT/opt/zelux/wheels"
    mkdir -p "$wh"
    local py=""
    command -v python3 >/dev/null 2>&1 && py="python3"
    if [ -z "$py" ]; then
        warn "没有 python3，无法预下载轮子（首启会因无网而装不上依赖）"
        rmdir "$wh" 2>/dev/null || true
        return 0
    fi

    local req="$MNT/opt/zelux/releases/$VERSION/software/requirements.txt"
    [ -f "$req" ] || { warn "找不到 $req"; rmdir "$wh" 2>/dev/null || true; return 0; }

    # --only-binary=:all: 强制只要 wheel，绝不拉源码包（源码包在板上要编译，必然失败）
    # 平台写成 manylinux aarch64 + cp311（bookworm 的 Python 3.11）
    local log_f=/tmp/zelux-wheel.log
    if "$py" -m pip download -q -d "$wh" \
        --only-binary=:all: \
        --platform manylinux2014_aarch64 \
        --platform manylinux_2_17_aarch64 \
        --platform manylinux_2_28_aarch64 \
        --python-version 3.11 --implementation cp --abi cp311 \
        --no-deps -r "$req" >"$log_f" 2>&1; then
        # --no-deps 先拿直接依赖，再补它们自己的依赖（同样只要 aarch64 wheel）
        "$py" -m pip download -q -d "$wh" \
            --only-binary=:all: \
            --platform manylinux2014_aarch64 \
            --platform manylinux_2_17_aarch64 \
            --platform manylinux_2_28_aarch64 \
            --python-version 3.11 --implementation cp --abi cp311 \
            -r "$req" >>"$log_f" 2>&1 || warn "补依赖时有问题（下面会核对）"
        local n
        n="$(find "$wh" -name '*.whl' | wc -l)"
        if [ "$n" -ge 5 ]; then
            log "轮子已就位：$n 个（首启可完全离线，不需要外网）"
            # 清掉 pip 的缓存目录，别把镜像撑大
            rm -rf "$wh"/.cache "$wh"/*.whl.tmp 2>/dev/null || true
            ls -1 "$wh" | head -12
        else
            warn "只下到 $n 个 wheel，可能不完整。日志："
            tail -15 "$log_f" >&2 || true
        fi
    else
        warn "--wheelhouse 失败（宿主机 pip 太旧或网络不通）。日志："
        tail -20 "$log_f" >&2 || true
        warn "!! 没有离线轮子 → 板子首启会因为无外网装不上依赖，网页打不开"
        rmdir "$wh" 2>/dev/null || true
    fi
    rm -f "$log_f"
}

verify_units() {
    command -v systemd-analyze >/dev/null 2>&1 || { warn "宿主机没有 systemd-analyze，跳过单元校验"; return 0; }
    step "校验 systemd 单元"
    local ok=1
    if systemd-analyze verify \
        "$MNT"/etc/systemd/system/zeluxd.service \
        "$MNT"/etc/systemd/system/zelux-fand.service \
        "$MNT"/etc/systemd/system/zelux-pwm-setupd.service \
        "$MNT"/etc/systemd/system/zelux-firstboot.service \
        "$MNT"/etc/systemd/system/zelux-update.service >/tmp/zelux-verify.log 2>&1; then
        log "zelux-*.service 通过"
    else
        # 宿主机 systemd 版本和 bookworm 不一致时会有噪声，所以只当警告
        warn "systemd-analyze 有意见（可能是宿主版本差异）："
        sed -n '1,20p' /tmp/zelux-verify.log >&2 || true
        ok=0
    fi
    rm -f /tmp/zelux-verify.log
    [ "$ok" -eq 1 ] || warn "单元校验没全过，烧到板子上先 systemctl status zeluxd 看一眼"
}

# 无线栈自检：这几条一旦不满足，板子会「连 WiFi 列表都刷不出来」。
# 血泪教训（v2 回归）：wpa_supplicant.service 被误遮蔽 → NM 的 D-Bus 激活失败
# → 连扫描都做不了。构建时**硬失败**，不要等烧完卡到现场才发现。
verify_network_stack() {
    require_rootfs
    step "自检无线栈（错了就硬失败，别烧到板子上才翻车）"
    local root="$MNT" bad=0

    # 1) wpa_supplicant.service 不能被遮蔽 —— NM 靠 D-Bus 激活它
    local p
    for p in "$root/etc/systemd/system/wpa_supplicant.service" \
             "$root/etc/systemd/system/wpa_supplicant@.service"; do
        if [ -L "$p" ] && [ "$(readlink "$p" 2>/dev/null)" = "/dev/null" ]; then
            error "无线致命错误：${p#"$root"} 被遮蔽成 /dev/null"
            error "  → NetworkManager 会报 'Failed to D-Bus activate wpa_supplicant service'"
            error "  → WiFi 网卡不可用，连扫描都做不了。见 fix_network_stack() 的注释。"
            bad=1
        fi
    done

    # 2) 单元文件本体 + supplicant 二进制必须在
    if [ -e "$root/lib/systemd/system/wpa_supplicant.service" ] \
       || [ -e "$root/usr/lib/systemd/system/wpa_supplicant.service" ]; then
        :
    else
        error "无线致命错误：镜像里找不到 wpa_supplicant.service 单元文件"; bad=1
    fi
    if [ -x "$root/sbin/wpa_supplicant" ] || [ -x "$root/usr/sbin/wpa_supplicant" ]; then
        :
    else
        error "无线致命错误：找不到 wpa_supplicant 二进制（包 wpasupplicant 没装）"; bad=1
    fi

    # 3) wpa_supplicant 必须在 multi-user.target.wants 里（开机/按需都能起来）。
    #    ⚠ 这里必须用 `-L`/`-e` 的并集判断：镜像里的软链是**绝对路径**
    #    （→ /lib/systemd/system/wpa_supplicant.service），而我们在宿主机上看，
    #    那个绝对路径会被按宿主机的根解析 → 悬空 → 单用 -e 会误报"缺失"。
    #    （早期就是用 -e 误判过，白白多排查一轮。）
    if [ -L "$root/etc/systemd/system/multi-user.target.wants/wpa_supplicant.service" ] \
       || [ -e "$root/etc/systemd/system/multi-user.target.wants/wpa_supplicant.service" ]; then
        log "  ✓ wpa_supplicant.service 已启用，且未被遮蔽"
    else
        warn "wpa_supplicant.service 不在 multi-user.target.wants（D-Bus 仍可激活，但最好 enable 上）"
    fi

    # 4) dnsmasq 服务要遮蔽，但二进制要留着（NM shared 模式自己 spawn 它）
    if [ -L "$root/etc/systemd/system/dnsmasq.service" ] \
       && [ "$(readlink "$root/etc/systemd/system/dnsmasq.service" 2>/dev/null)" = "/dev/null" ]; then
        log "  ✓ dnsmasq.service 已遮蔽（让出 53 端口）"
    else
        warn "dnsmasq.service 没被遮蔽：它会常驻占 53 端口，热点下手机可能拿不到 IP"
    fi
    if [ -x "$root/usr/sbin/dnsmasq" ] || [ -x "$root/usr/bin/dnsmasq" ]; then
        log "  ✓ dnsmasq 二进制在（NM 能 spawn 它发 DHCP）"
    else
        error "dnsmasq 二进制不在：热点起来也给不出 DHCP（apt install dnsmasq-base）"; bad=1
    fi

    # 5) 无线监管数据库：缺了 cfg80211 会拒绝部分信道 → 扫描结果不全甚至空。
    #    ⚠ 这里也不能只用 -e：regulatory.db 是**绝对软链**
    #    （→ /etc/alternatives/regulatory.db），宿主机上 -e 一律判悬空。
    #    用 -e 或 -L 任一命中即可。
    if [ -e "$root/lib/firmware/regulatory.db" ] || [ -L "$root/lib/firmware/regulatory.db" ] \
       || [ -e "$root/lib/firmware/regulatory.db.p7s" ] || [ -L "$root/lib/firmware/regulatory.db.p7s" ]; then
        log "  ✓ wireless-regdb 在"
    else
        warn "没有 regulatory.db（wireless-regdb 没装）：某些信道会被内核禁用，扫描可能不全"
    fi

    # 6) WiFi 固件：两种模组都要在（AP6212 / AIC8800）
    local fw_ok=0
    [ -e "$root/lib/firmware/brcm/brcmfmac43455-sdio.bin" ] && fw_ok=$((fw_ok+1))
    [ -d "$root/lib/firmware/aic8800_fw" ] && fw_ok=$((fw_ok+1))
    if [ "$fw_ok" -ge 1 ]; then
        log "  ✓ WiFi 固件在（brcmfmac / aic8800 命中 $fw_ok 个）"
    else
        error "两种 WiFi 固件都没有：网卡 probe 不起来"; bad=1
    fi

    # 7) 别把 ifupdown 的 plugins 覆盖掉（早期版本写过 plugins=keyfile，属于无谓偏离基线）
    local cfg="$root/etc/NetworkManager/conf.d/20-zelux.conf"
    if [ -f "$cfg" ] && grep -qE '^[[:space:]]*plugins[[:space:]]*=' "$cfg"; then
        warn "$cfg 里又出现了 plugins= —— 会覆盖 base 的 ifupdown,keyfile，建议删掉这行"
    fi

    # 8) dnsmasq 的 drop-in：没有它，热点模式下 dnsmasq 会降权到 nobody，
    #    写不进 /var/lib/NetworkManager 的 lease 文件 → 直接退出 → 手机拿不到 IP。
    local drop="$root/etc/NetworkManager/dnsmasq-shared.d/00-zelux-lease.conf"
    if [ -f "$drop" ] && grep -qE '^[[:space:]]*user[[:space:]]*=[[:space:]]*root' "$drop"; then
        log "  ✓ dnsmasq shared drop-in 在（user=root，lease 写得进去）"
    else
        error "缺 $drop（或没写 user=root）：热点起来后手机拿不到 IP"; bad=1
    fi
    # 对应目录权限：NM 的 lease 目录必须让降权后的进程能进
    local nmdir="$root/var/lib/NetworkManager"
    if [ -d "$nmdir" ]; then
        local m
        m="$(stat -c %a "$nmdir" 2>/dev/null || echo "?")"
        case "$m" in
            700) warn "/var/lib/NetworkManager 是 0700：dnsmasq 降权后写不了 lease（drop-in 已兜底，但建议 755）" ;;
            *)   log "  ✓ /var/lib/NetworkManager 权限 $m" ;;
        esac
    else
        error "/var/lib/NetworkManager 不存在：NM shared 模式没地方放 lease"; bad=1
    fi

    if [ "$bad" -ne 0 ]; then
        die "无线栈自检不通过（见上面 error）。这个镜像烧上去 WiFi 一定用不了，先修再构建。"
    fi
    log "无线栈自检全部通过"
}

# 设备树自检：U-Boot 必须拿到**明确的那一个** dtb。
# 血泪教训（v3 仍然存在）：u-boot-update 生成的是 `fdtdir`，而该目录下同时有
#   zero-3e（无 WiFi）/ zero-3w-ap6212 / zero-3w-aic8800ds2 三个 dtb。
# U-Boot 按 board name 猜，猜成 3e 就完全没有 wlan0 —— 表现为"网络都搜不到"。
verify_devicetree() {
    require_rootfs
    step "自检设备树（必须钉死成 zero-3w 的那一个）"
    local root="$MNT" bad=0
    local conf="$root/boot/extlinux/extlinux.conf"

    if [ ! -f "$conf" ]; then
        warn "没有 extlinux.conf，跳过设备树自检（非 U-Boot 启动方案？）"
        return 0
    fi

    # 1) 不能残留 fdtdir
    if grep -qE '^[[:space:]]*fdtdir' "$conf"; then
        error "extlinux.conf 里还有 fdtdir —— U-Boot 会自己挑 dtb，可能挑到无 WiFi 的 zero-3e"
        bad=1
    fi

    # 2) 必须有 fdt 行，且指向 zero-3w
    local fdt_line
    fdt_line="$(grep -E '^[[:space:]]*fdt ' "$conf" | head -1 || true)"
    if [ -z "$fdt_line" ]; then
        error "extlinux.conf 里没有 fdt 行"; bad=1
    else
        log "  ✓ fdt -> $(printf '%s' "$fdt_line" | awk '{print $2}')"
        case "$fdt_line" in
            *zero-3e*)
                error "fdt 指向 zero-3e（无 WiFi 模组）—— 板子上永远不会有 wlan0"; bad=1 ;;
            *zero-3w*)
                : ;;
            *)
                warn "fdt 指向的不是 zero-3w：$fdt_line（确认一下模组型号）" ;;
        esac
    fi

    # 3) 该文件真实存在（绝对路径按 rootfs 拼）
    local fdt_path
    fdt_path="$(printf '%s' "$fdt_line" | awk '{print $2}')"
    if [ -n "$fdt_path" ] && [ ! -f "$root$fdt_path" ]; then
        error "fdt 指向的文件在镜像里不存在：$fdt_path"; bad=1
    fi

    # 4) /etc/kernel/cmdline 不能再带 dtb=/fdtfile=（否则 u-boot-update 覆盖回去）
    if [ -f "$root/etc/kernel/cmdline" ] && grep -qE '(^|[[:space:]])(dtb|fdtfile)=' "$root/etc/kernel/cmdline"; then
        error "/etc/kernel/cmdline 里还留着 dtb=/fdtfile=，内核升级后会被覆盖"; bad=1
    fi

    if [ "$bad" -ne 0 ]; then
        die "设备树自检不通过（见上面 error）。这个镜像烧上去可能根本没有 wlan0。"
    fi
    log "设备树自检通过（已钉死 zero-3w 的 dtb）"
}

clean_rootfs() {
    require_rootfs
    step "清理（日志 / machine-id / ssh host key / apt 缓存）"
    local root="$MNT"
    # 日志：只清内容不删目录（有些服务启动前要先能打开自己的 log 文件）
    if [ -d "$root/var/log" ]; then
        find "$root/var/log" -type f -exec truncate -s 0 {} + 2>/dev/null || true
        find "$root/var/log" -type f -name '*.gz' -delete 2>/dev/null || true
        find "$root/var/log" -type f -name '*.1' -delete 2>/dev/null || true
    fi
    rm -rf "$root/var/log/journal" 2>/dev/null || true
    # machine-id 置空：systemd 首次启动会生成新的，否则全公司十台鸭子同一个 id
    : > "$root/etc/machine-id"
    if [ ! -L "$root/var/lib/dbus/machine-id" ]; then
        mkdir -p "$root/var/lib/dbus"
        : > "$root/var/lib/dbus/machine-id"
    fi
    # ssh host key：每台机器自己生成，别共用私钥
    rm -f "$root"/etc/ssh/ssh_host_* 2>/dev/null || true
    # apt / pip 缓存
    rm -rf "$root/var/cache/apt/archives/"*.deb 2>/dev/null || true
    rm -rf "$root/var/lib/apt/lists/"* 2>/dev/null || true
    rm -rf "$root/root/.cache/pip" 2>/dev/null || true
    rm -f "$root/root/.bash_history" "$root/home/zelux/.bash_history" 2>/dev/null || true
    rm -f "$root/etc/motd.d/99-zelux" 2>/dev/null || true
    # 我们的状态标记不能带出去
    rm -f "$root/var/lib/zelux/.initialized" 2>/dev/null || true
    sync
}

# ---------------------------------------------------------------- dry-run
dry_run_report() {
    cat <<EOF

------------------ DRY RUN（没有挂载、没有写入） ------------------
版本          : $VERSION
基础镜像      : $BASE
基础镜像大小  : $(( $(stat -c %s "$BASE") / MIB )) MiB
输出          : $OUT
扩容          : $(if [ "$NO_GROW" -eq 1 ]; then echo "不扩容"; elif [ -n "$SIZE_GB" ]; then echo "${SIZE_GB} GB"; else echo "原大小 + 2 GB 余量"; fi)
压缩          : $(if [ "$NO_COMPRESS" -eq 1 ]; then echo "不压缩（直接出 .img）"; else echo "xz -T0 -9"; fi)
串口控制台    : $(if [ "$KEEP_SERIAL" -eq 1 ]; then echo "保留"; else echo "关闭（ttyS2 让给舵机）"; fi)
离线轮子      : $(if [ "$WHEELHOUSE" -eq 1 ]; then echo "预下载 aarch64 wheel"; else echo "不做"; fi)
overlay 文件  : $(find "$OVERLAY_DIR" -type f | wc -l) 个
systemd 单元  : $(find "$UNITS_DIR" -name '*.service' | wc -l) 个（software/systemd 为真源）
软件目录      : $SOFTWARE_DIR
工作区        : $WORK_DIR

校验结果：
  · 平台/权限/工具/空间：通过
  · overlay 关键文件：齐
  · 分区检查：dry-run 不解压，跳过（真跑时按 ext4 / vfat 识别）
EOF
    if [ -f "$BASE" ]; then
        printf '  · 基础镜像 sha256: %s\n' "$(sha256sum "$BASE" | awk '{print $1}')"
    fi
    cat <<'EOF'

下一步（去掉 --dry-run 真跑）：
  sudo ./build-image.sh --base <同一个路径>
EOF
}

# ---------------------------------------------------------------- 主流程
main() {
    python3 "$SCRIPT_DIR/tools/robotd_component.py" verify --source "$COMPONENT_ROOT/robotd" --lock "$COMPONENT_ROOT/components.lock.yaml"
    check_platform
    [ "$DRY_RUN" -eq 1 ] || check_root
    check_tools
    check_overlay
    resolve_base

    if [ -z "$OUT" ]; then
        if [ "$NO_COMPRESS" -eq 1 ]; then
            OUT="$SCRIPT_DIR/zelux-duck-${VERSION}-zero3w.img"
        else
            OUT="$SCRIPT_DIR/zelux-duck-${VERSION}-zero3w.img.xz"
        fi
    fi
    case "$OUT" in
        /dev/*) die "--out 不能是 /dev 下的设备：$OUT" ;;
    esac
    mkdir -p "$(dirname -- "$OUT")"
    mkdir -p "$WORK_DIR"

    check_space

    if [ "$DRY_RUN" -eq 1 ]; then
        dry_run_report
        exit 0
    fi

    step "0/10 记录基础镜像指纹"
    local base_sha
    base_sha="$(sha256sum "$BASE" | awk '{print $1}')"
    log "base sha256 = $base_sha"

    step "1/10 解压到工作区"
    IMG="$WORK_DIR/zelux-duck-${VERSION}.img"
    rm -f "$IMG"
    decompress_base "$IMG"
    WORK_STARTED=1
    log "解压后 $(($(stat -c %s "$IMG") / MIB)) MiB"

    step "2/10 扩容（先长文件，再挂）"
    prepare_image_size

    step "3/10 挂载（losetup -Pf）"
    # 同一个镜像文件重复 attach 会得到两个互相看不到写入的 loop 设备
    local already
    already="$(losetup -j "$IMG" --noheadings -o NAME 2>/dev/null | head -1 || true)"
    if [ -n "$already" ]; then
        die "$IMG 已经挂在 $already 上了：先 sudo losetup -d $already"
    fi
    LOOP="$(losetup -Pf --show "$IMG")" || die "losetup 失败（WSL 里确认镜像在 Linux 文件系统上）"
    log "loop = $LOOP"
    sleep 1
    find_partitions

    step "4/10 扩分区 + 扩展文件系统"
    grow_partition

    step "5/10 挂载 rootfs / boot"
    MNT="$(mktemp -d "${TMPDIR:-/tmp}/zelux-build.XXXXXX")"
    mount -o rw "$ROOT_PART" "$MNT" || die "挂不上 $ROOT_PART"
    ROOT_MOUNTED=1
    [ -f "$MNT/etc/os-release" ] || die "$ROOT_PART 里没有 /etc/os-release，选错分区了"

    if [ -n "$BOOT_PART" ]; then
        local boot_uuid boot_mp=""
        boot_uuid="$(blkid -o value -s UUID "$BOOT_PART" 2>/dev/null || true)"
        if [ -n "$boot_uuid" ]; then
            boot_mp="$(awk -v u="UUID=$boot_uuid" '$1==u {print $2; exit}' "$MNT/etc/fstab" 2>/dev/null || true)"
        fi
        [ -n "$boot_mp" ] || boot_mp="/boot"
        mkdir -p "$MNT$boot_mp"
        mount "$BOOT_PART" "$MNT$boot_mp" || die "挂不上 $BOOT_PART -> $boot_mp"
        BOOT_MOUNTED=1
        BOOT_MNT_REL="$boot_mp"
        log "boot 挂到 $boot_mp"
    fi

    step "6/10 注入 overlay + 软件"
    inject_overlay
    install_software
    python3 "$SCRIPT_DIR/tools/robotd_component.py" install --source "$COMPONENT_ROOT/robotd" --root "$MNT" --lock "$COMPONENT_ROOT/components.lock.yaml"
    "$MNT/usr/local/libexec/zelux-build-pwm-overlays" "$MNT${BOOT_MNT_REL:-/boot}" "$MNT" "$SCRIPT_DIR/device-tree/overlays"

    step "7/10 用户 / 目录 / cloud-init / 串口 / 设备树 / 桌面"
    create_user
    prepare_dirs
    disable_cloud_init
    disable_serial_console
    # ⚠ 顺序有讲究：disable_serial_console 会重写 extlinux.conf 的 append 行，
    #   而 fix_devicetree 要改的是同一个文件的 fdtdir 行。先串口后 dtb，
    #   这样 dtb 的写入不会被串口那一步的备份/覆盖带掉。
    fix_devicetree || die "设备树固定失败：U-Boot 可能加载无 WiFi 的 zero-3e dtb"
    disable_desktop
    apply_perms

    step "8/10 网络栈 / 服务 / 轮子 / 单元校验"
    fix_network_stack
    enable_units
    wheelhouse
    verify_units

    step "9/10 清理"
    clean_rootfs

    # 自检放在清理之后、卸载之前：这是"即将交付的那份 rootfs"的最后一次把关。
    # 一旦这里 die，就不要产出镜像 —— 烧到卡上再发现的成本高得多。
    verify_network_stack
    verify_devicetree

    step "10/10 卸载"
    if [ "$BOOT_MOUNTED" -eq 1 ]; then
        umount "$MNT$BOOT_MNT_REL" || die "卸载 boot 失败（有进程占着？lsof +D 看看）"
        BOOT_MOUNTED=0
    fi
    sync
    umount "$MNT" || die "卸载 rootfs 失败"
    ROOT_MOUNTED=0
    losetup -d "$LOOP" || warn "losetup -d 失败（不影响文件，重启后自动清）"
    LOOP=""
    rmdir "$MNT" 2>/dev/null || true
    MNT=""

    step "压缩"
    if [ "$NO_COMPRESS" -eq 1 ]; then
        log "--no-compress：直接 mv 成 $OUT"
        mv -f "$IMG" "$OUT"
    else
        log "xz -T0 -9（几 GB 的镜像要几分钟到十几分钟）"
        xz -T0 -9 -c -- "$IMG" > "$OUT"
        rm -f "$IMG"
    fi

    step "校验和"
    ( cd "$(dirname -- "$OUT")" && sha256sum "$(basename -- "$OUT")" > "$(basename -- "$OUT").sha256" )
    {
        printf 'version=%s\n' "$VERSION"
        printf 'built_at=%s\n' "$(date -Is)"
        printf 'host=%s\n' "$(uname -srm)"
        printf 'base=%s\n' "$(basename -- "$BASE")"
        printf 'base_sha256=%s\n' "$base_sha"
        printf 'out=%s\n' "$(basename -- "$OUT")"
        printf 'out_bytes=%s\n' "$(stat -c %s "$OUT")"
        printf 'grow=%s\n' "$(if [ "$NO_GROW" -eq 1 ]; then echo none; elif [ -n "$SIZE_GB" ]; then echo "${SIZE_GB}G"; else echo auto+2G; fi)"
        printf 'compressed=%s\n' "$(if [ "$NO_COMPRESS" -eq 1 ]; then echo no; else echo xz-9; fi)"
        printf 'serial_console=%s\n' "$(if [ "$KEEP_SERIAL" -eq 1 ]; then echo kept; else echo removed; fi)"
    } > "$OUT.buildinfo"

    cat >&2 <<EOF

================== 构建完成 ==================
镜像    : $OUT
大小    : $(( $(stat -c %s "$OUT") / MIB )) MiB
校验    : $(cat "$OUT.sha256")
指纹    : $OUT.buildinfo
烧写    : image/flash/flash-linux.sh "$OUT" /dev/sdX     （或 flash-windows.ps1）
验证    : xz -t "$OUT" && sha256sum -c "$OUT.sha256"
==============================================
EOF
}

# ---------------------------------------------------------------- 解析参数
# 放在最后：--list 要用 list_official()，bash 必须先执行到函数定义
while [ $# -gt 0 ]; do
    case "$1" in
        --base)     need_val "$1" $#; BASE="$2"; shift 2 ;;
        --base=*)   BASE="${1#*=}"; shift ;;
        --out)      need_val "$1" $#; OUT="$2"; shift 2 ;;
        --out=*)    OUT="${1#*=}"; shift ;;
        --size-gb)  need_val "$1" $#; SIZE_GB="$2"; shift 2 ;;
        --size-gb=*) SIZE_GB="${1#*=}"; shift ;;
        --no-compress) NO_COMPRESS=1; shift ;;
        --no-grow)  NO_GROW=1; shift ;;
        --wheelhouse) WHEELHOUSE=1; shift ;;
        --no-wheelhouse) WHEELHOUSE=0; shift ;;
        --keep-serial-console) KEEP_SERIAL=1; shift ;;
        --dtb)      need_val "$1" $#; ZELUX_DTB="$2"; shift 2 ;;
        --dtb=*)    ZELUX_DTB="${1#*=}"; shift ;;
        --work-dir) need_val "$1" $#; WORK_DIR="$2"; shift 2 ;;
        --dry-run)  DRY_RUN=1; shift ;;
        --list)     list_official; exit 0 ;;
        -h|--help)  usage ;;
        *) die "不认识的参数：$1（--help 看全部）" ;;
    esac
done

main "$@"
