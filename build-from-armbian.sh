#!/bin/bash
# ============================================================================
#  ZELUX Duck —— 基于官方 Armbian 镜像构建（方案 A）
#
#  为什么不用 Radxa 官方 KDE 镜像了：
#    Radxa 只发 KDE 桌面版，装完 7.7 GB、1200+ 包，其中一整套 Plasma 我们
#    一个像素都不用。而 Armbian 的 rk35xx 镜像是纯 CLI：622 包、3.0 GB，
#    并且已经把这台机器的硬件栈调好了（UART2 舵机 / I2C3 摄像头 / NPU /
#    AIC3104 音频 / WiFi 省电与随机 MAC 关闭）。拿它当底盘，镜像能小一半多，
#    启动链也更干净。
#
#  这个脚本只做三件事：注入 ZELUX 自己的东西、屏蔽别人的服务、把冲突点修掉。
#  它不改内核、不改 dtb、不重建 rootfs —— 底座是什么就是什么。
#
#  用法：
#    bash build-from-armbian.sh                # 默认 /root/off.img → 5G
#    NEWSIZE=6G bash build-from-armbian.sh
#    BASE=/path/base.img bash build-from-armbian.sh
# ============================================================================
set -euo pipefail

BASE=${BASE:-/root/off.img}
SRC=${SRC:-/mnt/d/迅雷下载/zelux-src}
WHEELS=${WHEELS:-/root/wh313}
WORK=${WORK:-/root/zb5}
NEWSIZE=${NEWSIZE:-5G}
VERSION=${VERSION:-1.0.0}
NAME="zelux-duck-armbian-$VERSION.img"

MNT="$WORK/mnt"
IMG="$WORK/$NAME"
OUT="$WORK/$NAME.xz"
LOOP=""

log()  { printf '\033[1;36m[build]\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33m[build] !!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[build] xx\033[0m %s\n' "$*" >&2; exit 1; }
step() { printf '\n\033[1;32m== %s\033[0m\n' "$*" >&2; }

cleanup() {
    mountpoint -q "$MNT" 2>/dev/null && umount "$MNT" 2>/dev/null || true
    [ -n "$LOOP" ] && losetup -d "$LOOP" 2>/dev/null || true
}
trap cleanup EXIT

# 找一个空闲 loop 设备（losetup -f 在 WSL 上偶尔抽风，逐个试更可靠）
pick_loop() {
    local d
    for d in /dev/loop0 /dev/loop1 /dev/loop2 /dev/loop3 /dev/loop4 /dev/loop5 /dev/loop6 /dev/loop7; do
        [ -b "$d" ] || continue
        if ! losetup "$d" >/dev/null 2>&1; then
            printf '%s' "$d"
            return 0
        fi
    done
    return 1
}

# ---------------------------------------------------------------------- 0
step "0/10 前置检查"
[ "$(id -u)" -eq 0 ] || die "要 root"
[ -f "$BASE" ] || die "找不到基底镜像 $BASE"
[ -d "$SRC/overlay" ] || die "找不到 $SRC/overlay"
[ -d "$SRC/software" ] || die "找不到 $SRC/software"
[ -d "$WHEELS" ] || die "找不到离线轮子目录 $WHEELS（cp313 aarch64）"
for t in sgdisk sfdisk e2fsck resize2fs xz; do
    command -v "$t" >/dev/null 2>&1 || die "宿主缺 $t"
done

mkdir -p "$WORK" "$MNT"
rm -f "$IMG" "$OUT"
log "基底   : $BASE ($(du -h "$BASE" | cut -f1))"
log "源     : $SRC"
log "轮子   : $WHEELS ($(ls "$WHEELS"/*.whl 2>/dev/null | wc -l) 个)"
log "目标   : $IMG ($NEWSIZE)"

# ---------------------------------------------------------------------- 1
step "1/10 复制基底并扩容到 $NEWSIZE"
cp --reflink=auto "$BASE" "$IMG" 2>/dev/null || cp "$BASE" "$IMG"
truncate -s "$NEWSIZE" "$IMG"
# sgdisk -e：把备份 GPT 搬到新的磁盘末尾（不搬的话内核会认为 GPT 损坏）
sgdisk -e "$IMG" >/dev/null 2>&1 || warn "sgdisk -e 失败（继续，稍后验证）"

# 记下原分区起点，改成"扩到末尾"
PSTART=$(sfdisk -d "$IMG" 2>/dev/null | awk -F'[ ,]+' '/^\/.*1 :/{for(i=1;i<=NF;i++) if($i=="start=") print $(i+1)}' | head -1)
[ -n "${PSTART:-}" ] || die "读不到分区起点"

if printf ', +\n' | sfdisk --force --no-reread -N 1 "$IMG" >/dev/null 2>&1; then
    log "分区 1 已扩到镜像末尾（起点 $PSTART sector）"
else
    warn "sfdisk 直接扩容失败，改用 sgdisk 重建分区项"
    TCODE=$(sgdisk -i 1 "$IMG" 2>/dev/null | sed -n 's/^Partition GUID code: \([^ ]*\).*/\1/p')
    TNAME=$(sgdisk -i 1 "$IMG" 2>/dev/null | sed -n 's/^Partition name: .\(.*\).$/\1/p')
    [ -n "${TCODE:-}" ] || TCODE="0FC63DAF-8483-4772-8E79-3D69D8477DE4"
    sgdisk -d 1 "$IMG" >/dev/null
    sgdisk -n "1:${PSTART}:0" -t "1:${TCODE}" ${TNAME:+-c "1:$TNAME"} "$IMG" >/dev/null
    log "分区 1 已用 sgdisk 重建（类型 $TCODE）"
fi
sgdisk -v "$IMG" 2>&1 | grep -iE "problem|corrupt" | grep -viE "No problems|free sectors" && die "GPT 有问题，停止" || true
sfdisk -d "$IMG" 2>/dev/null | grep "^$IMG" | head -3 >&2 || true

# ---------------------------------------------------------------------- 2
step "2/10 扩文件系统"
LOOP="$(pick_loop)" || die "没有空闲 loop 设备（先 wsl --shutdown 再试）"
log "loop: $LOOP"
losetup "$LOOP" "$IMG" -P || die "losetup 失败"
sleep 2
partprobe "$LOOP" 2>/dev/null || true
[ -b "${LOOP}p1" ] || die "${LOOP}p1 没出现"
e2fsck -f -p "${LOOP}p1" || warn "e2fsck 返回非 0（已自动修复就没事）"
resize2fs "${LOOP}p1" || die "resize2fs 失败"
dumpe2fs -h "${LOOP}p1" 2>/dev/null | grep -E "^Block count|^Inode count|^Free blocks" >&2

mount "${LOOP}p1" "$MNT" || die "挂载失败"
[ -f "$MNT/etc/os-release" ] || die "挂的不是根分区"
grep -q "Armbian\|Debian" "$MNT/etc/os-release" || warn "基底不是 Debian 系，后面几步可能不适用"
log "已挂载，可用空间：$(df -h "$MNT" | awk 'NR==2{print $4}')"

# ---------------------------------------------------------------------- 3
step "3/10 注入 overlay（ZELUX 的脚本 / 单元 / 配置）"
cp -a "$SRC/overlay/." "$MNT/"
log "overlay 文件数：$(find "$SRC/overlay" -type f | wc -l)"

# ---------------------------------------------------------------------- 4
step "4/10 注入 software 到 /opt/zelux/releases/$VERSION"
REL="$MNT/opt/zelux/releases/$VERSION"
mkdir -p "$REL" "$MNT/opt/zelux/releases"
cp -a "$SRC/software/." "$REL/software/"
rm -rf "$REL/software/var"
ln -sfn "releases/$VERSION" "$MNT/opt/zelux/current"
printf '%s\n' "$VERSION" > "$MNT/opt/zelux/VERSION"
log "software：$(du -sh "$REL/software" | cut -f1) / $(find "$REL/software" -type f | wc -l) 个文件"
[ -d "$REL/software/web" ] || die "software/web 没进去 —— 网页会 404"

# ---------------------------------------------------------------------- 5
step "5/10 装离线 Python 依赖（解包 wheel 到 /opt/zelux/pylibs）"
# 为什么不建 venv：Armbian 基底没有 python3-venv / ensurepip / pip，
# 建不了 venv 也装不了包。wheel 直接解包 + PYTHONPATH 是最省事、最可复现的路
# （zeluxd-run 已经支持 /opt/zelux/pylibs 这条回退路径）。
PYLIB="$MNT/opt/zelux/pylibs"
rm -rf "$PYLIB"
mkdir -p "$PYLIB"
python3 - "$WHEELS" "$PYLIB" <<'PY'
import glob, os, sys, zipfile
wheels, dst = sys.argv[1], sys.argv[2]
n = 0
for whl in sorted(glob.glob(os.path.join(wheels, "*.whl"))):
    with zipfile.ZipFile(whl) as z:
        for name in z.namelist():
            if name.endswith("/"):
                continue
            # .data/purelib 之类要摊平到根
            path = name
            for marker in (".data/purelib/", ".data/platlib/"):
                if marker in path:
                    path = path.split(marker, 1)[1]
            if not path or path.startswith(".."):
                continue
            target = os.path.join(dst, path)
            os.makedirs(os.path.dirname(target), exist_ok=True)
            with z.open(name) as fsrc, open(target, "wb") as fdst:
                fdst.write(fsrc.read())
            n += 1
    print(f"  + {os.path.basename(whl)}", file=sys.stderr)
print(f"  解出 {n} 个文件", file=sys.stderr)
PY
# drvfs/wheel 出来的位不可信：目录 755、文件 644，.so 不需要执行位
find "$PYLIB" -type d -exec chmod 755 {} + 2>/dev/null || true
find "$PYLIB" -type f -exec chmod 644 {} + 2>/dev/null || true
chown -R 0:0 "$PYLIB" 2>/dev/null || true
log "pylibs：$(du -sh "$PYLIB" | cut -f1) / $(find "$PYLIB" -type f | wc -l) 个文件"

# 关键依赖存在性检查（缺一个 zeluxd 就起不来，宁可在构建期炸掉）
for mod in fastapi uvicorn pydantic starlette anyio; do
    [ -e "$PYLIB/$mod" ] || [ -e "$PYLIB/$mod.py" ] || die "pylibs 里没有 $mod"
done
log "fastapi / uvicorn / pydantic / starlette / anyio 都在"

# ---------------------------------------------------------------------- 6
step "6/10 屏蔽别人的服务（它们会抢 8000 端口和舵机串口）"
WANTS="$MNT/etc/systemd/system/multi-user.target.wants"
mkdir -p "$WANTS"
# microduck-studio 在 0.0.0.0:8000 上跑它自己的网页 —— 和 zeluxd 直接冲突，
# 必须屏蔽，否则 zeluxd 绑端口失败，外网看到的还是旧界面。
MASK_LIST="microduck-studio microduck-firstboot microduck-netcheck \
microduck-update-control microduck-updater-engine microduck-voice-prepare \
duck-echo robotd robot-boot-check mediad padd tofd btd configd updaterd"
masked=0
for u in $MASK_LIST; do
    if [ -e "$MNT/etc/systemd/system/$u.service" ] || [ -e "$MNT/usr/lib/systemd/system/$u.service" ] || [ -e "$MNT/lib/systemd/system/$u.service" ]; then
        rm -f "$WANTS/$u.service" 2>/dev/null || true
        find "$MNT/etc/systemd/system" -maxdepth 2 -name "$u.service" -delete 2>/dev/null || true
        ln -sfn /dev/null "$MNT/etc/systemd/system/$u.service"
        masked=$((masked + 1))
    fi
done
log "已屏蔽 $masked 个单元（保留 aic3104-init / aic-bluetooth：那是硬件初始化）"
# 舵机要独占 /dev/ttyS2，任何 getty 都不能挂在上面
find "$MNT/etc/systemd/system" -maxdepth 3 -name "serial-getty@ttyS2.service" -delete 2>/dev/null || true
ln -sfn /dev/null "$MNT/etc/systemd/system/serial-getty@ttyS2.service"
# debug 串口（ttyFIQ0）也不要 getty，日志靠 firstboot 主动写
rm -f "$MNT/etc/systemd/system/getty.target.wants/serial-getty@ttyFIQ0.service" 2>/dev/null || true

# ---------------------------------------------------------------------- 7
step "7/10 网络栈：只修冲突点，不动能用的部分"
NM="$MNT/etc/NetworkManager"

# (a) microduck 的 99-robot-wifi-only.conf 写的是 unmanaged-devices=*,except:type:wifi
#     —— 意思是"NM 只管无线，别的网卡一律不管"。那是机器人不需要网线的取舍。
#     ZELUX 插网线也能用，所以删掉这条，让 NM 管所有网卡。
if [ -f "$NM/conf.d/99-robot-wifi-only.conf" ]; then
    rm -f "$NM/conf.d/99-robot-wifi-only.conf"
    log "已删除 99-robot-wifi-only.conf（放开有线网卡给 NM 管）"
fi

# (b) 98-robot-dns.conf 写 dns=systemd-resolved，但这个镜像里 systemd-resolved
#     并没有被 enable（只有 D-Bus 激活别名）。NM 把 DNS 交给一个没起的 resolver，
#     结果就是"能连上、解析不了域名"。删掉，让 NM 用默认（自己写 resolv.conf）。
if [ -f "$NM/conf.d/98-robot-dns.conf" ]; then
    rm -f "$NM/conf.d/98-robot-dns.conf"
    log "已删除 98-robot-dns.conf（避免把 DNS 交给没启用的 systemd-resolved）"
fi

# (c) 热点靠 NM 的 ipv4.method=shared，它内部会 spawn dnsmasq 发 DHCP。
#     dnsmasq 在 Debian 上编译默认 user=nobody，而 lease 目录 NM 建的是 0700 root:root
#     → 写不了 lease → 手机连上热点永远拿不到 IP（"一直转圈"）。
mkdir -p "$MNT/var/lib/NetworkManager"
chmod 755 "$MNT/var/lib/NetworkManager"
mkdir -p "$NM/dnsmasq-shared.d"
cat > "$NM/dnsmasq-shared.d/00-zelux-lease.conf" <<'EOF'
# ZELUX：热点模式下 NM spawn 的 dnsmasq 不要降权。
# 它要写 /var/lib/NetworkManager/dnsmasq-<if>.leases，nobody 进不去那个目录。
# 系统级 dnsmasq.service 没有启用，这个只影响 NM 托管的那一份。
user=root
EOF
mkdir -p "$MNT/etc/tmpfiles.d"
cat > "$MNT/etc/tmpfiles.d/zelux-network.conf" <<'EOF'
# ZELUX：NetworkManager shared 模式要用的运行时目录
d /run/NetworkManager 0755 root root -
d /run/NetworkManager/dnsmasq.d 0755 root root -
EOF

# (d) wpa_supplicant：**保持启用、绝不遮蔽**。NM 是通过 D-Bus 激活它拿 supplicant 的
#     （Debian 的 NM 二进制里没有 wpa_supplicant 路径，只有 "Failed to D-Bus activate"）。
#     遮蔽它 → 网卡不可用 → 连扫描都做不了。这是上一版镜像踩过的坑，别再来一次。
if [ -L "$MNT/etc/systemd/system/wpa_supplicant.service" ] && \
   [ "$(readlink "$MNT/etc/systemd/system/wpa_supplicant.service" 2>/dev/null)" = "/dev/null" ]; then
    rm -f "$MNT/etc/systemd/system/wpa_supplicant.service"
    log "清掉了历史遗留的 wpa_supplicant 遮蔽"
fi
if [ -f "$MNT/usr/lib/systemd/system/wpa_supplicant.service" ]; then
    mkdir -p "$WANTS"
    ln -sfn "/usr/lib/systemd/system/wpa_supplicant.service" "$WANTS/wpa_supplicant.service"
fi

# (e) 系统 dnsmasq 如果被 enable 会占 53 端口，和 NM 的 DHCP/DNS 打架。
#     Armbian 默认没开，这里只做"如果开了就关掉"，并保留二进制给 NM 用。
if [ -L "$WANTS/dnsmasq.service" ]; then
    rm -f "$WANTS/dnsmasq.service"
    log "系统 dnsmasq.service 已停用（二进制保留，NM 要自己 spawn）"
fi

# ---------------------------------------------------------------------- 8
step "8/10 用户 / 权限 / 单元"
if ! grep -q '^zelux:' "$MNT/etc/passwd"; then
    useradd --root "$MNT" --user-group --shell /bin/bash \
        --comment "ZELUX Duck Studio" --home-dir /home/zelux zelux 2>/dev/null \
        || die "useradd --root 失败"
    log "已创建 zelux 用户"
else
    log "zelux 用户已存在"
fi
mkdir -p "$MNT/home/zelux"
UID_Z=$(awk -F: '$1=="zelux"{print $3}' "$MNT/etc/passwd")
GID_Z=$(awk -F: '$1=="zelux"{print $3}' "$MNT/etc/group")
[ -n "${UID_Z:-}" ] && chown -R "$UID_Z:$GID_Z" "$MNT/home/zelux" 2>/dev/null || true
chmod 750 "$MNT/home/zelux" 2>/dev/null || true

# 硬件组：zelux 不用 sudo 也要能开 ttyS2 / i2c-3
for g in dialout i2c spi gpio video audio netdev plugdev; do
    grep -q "^$g:" "$MNT/etc/group" || groupadd --root "$MNT" -r "$g" 2>/dev/null || true
    usermod --root "$MNT" -a -G "$g" zelux 2>/dev/null || true
done

mkdir -p "$MNT/var/lib/zelux"
[ -n "${UID_Z:-}" ] && chown "$UID_Z:$GID_Z" "$MNT/var/lib/zelux" 2>/dev/null || true
chmod 750 "$MNT/var/lib/zelux"

# 系统口令（SSH 用），网页口令是 firstboot 写的 auth.json，两套
PASS=$(sed -n 's/^[[:space:]]*password[[:space:]]*=[[:space:]]*"\(.*\)".*/\1/p' "$MNT/etc/zelux/zelux.toml" | head -1)
PASS=${PASS:-zelux}
if command -v openssl >/dev/null 2>&1; then
    HASH=$(openssl passwd -6 -salt zeluxduck "$PASS" 2>/dev/null || true)
    [ -n "$HASH" ] && usermod --root "$MNT" -p "$HASH" zelux 2>/dev/null && log "zelux 系统口令已设置"
fi

# 权限：drvfs 复制过来的位一律 0777，必须逐类钉死
chmod 755 "$MNT/usr/local/bin" "$MNT/usr/local/sbin" 2>/dev/null || true
find "$MNT/usr/local/bin" "$MNT/usr/local/sbin" -maxdepth 1 -type f -exec chmod 755 {} + 2>/dev/null || true
find "$MNT/etc/systemd/system" -maxdepth 1 -name "*.service" -exec chmod 644 {} + 2>/dev/null || true
find "$MNT/etc/udev/rules.d" -name "*.rules" -exec chmod 644 {} + 2>/dev/null || true
find "$MNT/etc/polkit-1/rules.d" -name "*.rules" -exec chmod 644 {} + 2>/dev/null || true
chmod 644 "$MNT/etc/zelux/zelux.toml" 2>/dev/null || true
chmod 644 "$MNT/etc/tmpfiles.d/zelux.conf" 2>/dev/null || true
# NM 会拒绝加载权限不对的连接文件 —— 整个文件直接不认，连报错都不给
find "$MNT/etc/NetworkManager/system-connections" -name "*.nmconnection" -exec chmod 600 {} + 2>/dev/null || true
find "$MNT/etc/NetworkManager/system-connections" -name "*.nmconnection" -exec chown 0:0 {} + 2>/dev/null || true

# 开服务（手写软链，不依赖宿主 systemd 版本）
for u in zeluxd zelux-fand zelux-firstboot; do
    ln -sfn "/etc/systemd/system/$u.service" "$WANTS/$u.service"
done
rm -f "$WANTS/zelux-update.service"    # oneshot，只能人工/OTA 触发

# 自愈 timer：zeluxd 因 exit 78 放弃启动后，依赖补装好了也没人再拉它。
# 这个 timer 每 60 秒看一眼，该跑没跑就拉起来 —— 让"网页打不开"这件事能自己好。
TIMERS="$MNT/etc/systemd/system/timers.target.wants"
mkdir -p "$TIMERS"
if [ -f "$MNT/etc/systemd/system/zelux-selfheal.timer" ]; then
    ln -sfn "/etc/systemd/system/zelux-selfheal.timer" "$TIMERS/zelux-selfheal.timer"
    log "已 enable：zelux-selfheal.timer（60 秒自愈一次）"
else
    warn "缺 zelux-selfheal.timer —— 没有自愈兜底"
fi
log "已 enable：zeluxd zelux-fand zelux-firstboot"

# ---------------------------------------------------------------------- 9
step "9/10 自检（不通过就不出包）"
bad=0
chk() {  # chk <说明> <测试命令...>
    local desc="$1"; shift
    if "$@" >/dev/null 2>&1; then
        log "  ✓ $desc"
    else
        warn "  ✗ $desc"
        bad=$((bad + 1))
    fi
}

chk "dtb 已显式指定（不是靠 U-Boot 猜）" grep -q "^[[:space:]]*fdt[[:space:]]" "$MNT/boot/extlinux/extlinux.conf"
chk "dtb 文件存在" test -f "$MNT/boot/dtb/rockchip/rk3566-radxa-zero3.dtb"
chk "wpa_supplicant 未被遮蔽" test ! -L "$MNT/etc/systemd/system/wpa_supplicant.service"
chk "wpa_supplicant 已 enable" test -L "$WANTS/wpa_supplicant.service"
chk "NetworkManager 已 enable" test -L "$WANTS/NetworkManager.service"
chk "dnsmasq 二进制在（NM 要 spawn）" test -x "$MNT/usr/sbin/dnsmasq"
chk "dnsmasq lease 目录 755" test "$(stat -c %a "$MNT/var/lib/NetworkManager")" = "755"
chk "dnsmasq drop-in 存在" test -f "$MNT/etc/NetworkManager/dnsmasq-shared.d/00-zelux-lease.conf"
chk "热点连接文件 0600" test "$(stat -c %a "$MNT/etc/NetworkManager/system-connections/zelux-ap.nmconnection")" = "600"
chk "热点 SSID 是 ZELUX-Duck" grep -q "^ssid=ZELUX-Duck" "$MNT/etc/NetworkManager/system-connections/zelux-ap.nmconnection"
chk "zeluxd 单元在" test -f "$MNT/etc/systemd/system/zeluxd.service"
chk "zeluxd 已 enable" test -L "$WANTS/zeluxd.service"
# 这两条是"WiFi 连上了但网页打不开"的直接病根，必须在构建期钉死：
#   · zeluxd 不能 After=zelux-firstboot（否则热点起来了、服务还在排队）
#   · zeluxd 不能依赖 network-online.target（热点模式永远不满足，白等 20 秒）
chk "zeluxd 不排在首启之后" bash -c "! grep -q '^After=.*zelux-firstboot' '$MNT/etc/systemd/system/zeluxd.service'"
chk "zeluxd 不依赖 network-online" bash -c "! grep -qE '^(After|Wants)=.*network-online' '$MNT/etc/systemd/system/zeluxd.service'"
chk "首启用 restart 而非 try-restart" bash -c "grep -q 'systemctl restart zeluxd' '$MNT/usr/local/bin/zelux-firstboot'"
chk "自愈 timer 在" test -f "$MNT/etc/systemd/system/zelux-selfheal.timer"
chk "自愈 timer 已 enable" test -L "$MNT/etc/systemd/system/timers.target.wants/zelux-selfheal.timer"
chk "首启脚本可执行" test -x "$MNT/usr/local/bin/zelux-firstboot"
chk "zeluxd-run 可执行" test -x "$MNT/usr/local/bin/zeluxd-run"
chk "前端 index.html 在" test -f "$MNT/opt/zelux/current/software/web/index.html"
chk "current 软链正确" test -L "$MNT/opt/zelux/current"
chk "pylibs 有 fastapi" test -d "$MNT/opt/zelux/pylibs/fastapi"
chk "pylibs 有 uvicorn" test -d "$MNT/opt/zelux/pylibs/uvicorn"
chk "pylibs 有 pydantic_core（.so）" bash -c "ls $MNT/opt/zelux/pylibs/pydantic_core/*.so >/dev/null 2>&1"
chk "zelux 用户已建" grep -q "^zelux:" "$MNT/etc/passwd"
chk "microduck-studio 已屏蔽" test -L "$MNT/etc/systemd/system/microduck-studio.service"
chk "serial-getty@ttyS2 已屏蔽（舵机要独占）" test -L "$MNT/etc/systemd/system/serial-getty@ttyS2.service"
chk "zelux.toml 端口 8000" grep -q "^port = 8000" "$MNT/etc/zelux/zelux.toml"

# 反向检查：不该还活着的
for u in microduck-studio zelux-update; do
    if [ -e "$WANTS/$u.service" ]; then warn "  ✗ $u 还在 wants 里"; bad=$((bad + 1)); fi
done

# 冲突检查：谁还占着 8000（只看单元文件本身，drop-in 目录 .d/ 不算 —— 主单元已 mask）
leftover=$(grep -l "0\.0\.0\.0:8000" "$MNT"/etc/systemd/system/*.service 2>/dev/null | grep -v zelux || true)
if [ -n "$leftover" ]; then
    warn "  ✗ 还有别的单元监听 0.0.0.0:8000："
    printf '      %s\n' $leftover >&2
    bad=$((bad + 1))
else
    log "  ✓ 8000 端口没有争论"
fi

log "可用空间：$(df -h "$MNT" | awk 'NR==2{print $4}')"
if [ "$bad" -ne 0 ]; then
    die "自检 $bad 项不通过，不出包"
fi
log "自检全部通过"

# ---------------------------------------------------------------------- 10
step "10/10 卸载并压缩"
sync
umount "$MNT" || die "卸载失败（有进程占着？）"
losetup -d "$LOOP" && LOOP=""

log "压缩中（xz -T0 -6，几分钟）…"
xz -T0 -6 -c "$IMG" > "$OUT"
rm -f "$IMG"
xz -t "$OUT" || die "压缩包校验失败"
(cd "$WORK" && sha256sum "$(basename "$OUT")" > "$(basename "$OUT").sha256")
{
    echo "name=$(basename "$OUT")"
    echo "version=$VERSION"
    echo "base=$(basename "$BASE")"
    echo "base_scheme=armbian-single-partition"
    echo "built=$(date -Iseconds)"
    echo "size_bytes=$(stat -c %s "$OUT")"
    echo "size_human=$(du -h "$OUT" | cut -f1)"
} > "$OUT.buildinfo"

echo
log "完成：$OUT"
log "大小：$(du -h "$OUT" | cut -f1)"
log "sha256：$(cut -d' ' -f1 "$OUT.sha256")"
