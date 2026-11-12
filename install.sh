#!/bin/bash
# =============================================================================
# ZELUX Duck Studio —— 增量安装（已跑着 Radxa 官方系统的板子上，一条命令装好）
#
# 跑在哪：**板子上**（Radxa Zero 3W，官方 Debian 12 bookworm）。宿主机 x86 上只能 --pack。
# 要什么权限：root（写 /etc、/usr/local、/opt，安装依赖，重启服务）。
# 会改动什么：
#   /etc/**（systemd 单元、NetworkManager 连接、zelux.toml、udev/polkit/tmpfiles）
#   /usr/local/bin|sbin（7 个脚本）
#   /opt/zelux/**（软件 + venv）
#   /var/lib/zelux/backup/<时间戳>/**（被改文件的备份，回滚用）
#   systemd：enable + restart zeluxd / zelux-fand
# 不会动：分区表、bootloader、已有用户的其它配置、别人的 NetworkManager 连接。
#
# 用法：
#   sudo ./install.sh                     # 从当前仓库安装/升级（幂等，可以反复跑）
#   sudo ./install.sh --dev               # 开发模式：/opt/zelux/current 指向仓库，改代码即生效
#   sudo ./install.sh --offline [pkg.tar.gz]  # 现场没网：从本地包装（默认找 ./zelux-duck-<ver>-arm64.tar.gz）
#   ./install.sh --pack                   # 在开发机上打离线包（不需要 root）
#   sudo ./install.sh --dry-run           # 只打印会改哪些文件
#   sudo ./install.sh --no-deps --no-restart
#   sudo ./install.sh --rollback-last     # 手工回滚到上一次安装前的状态
#
# 幂等性：所有写操作都是"覆盖/链接"，重复跑结果一致；已存在的 auth.json 永不覆盖。
# 失败时：自动把 /etc 下改过的文件按备份还原、把本次新 enable 的服务关掉、恢复旧软链。
# =============================================================================
set -euo pipefail

readonly PROG="${0##*/}"
readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
readonly COMPONENT_ROOT="${ZELUX_COMPONENT_ROOT:-$SCRIPT_DIR/components}"
readonly STATE_DIR="/var/lib/zelux"
readonly BACKUP_ROOT="$STATE_DIR/backup"
readonly OPT_ROOT="/opt/zelux"
readonly UNITS_ENABLED="zeluxd zelux-fand zelux-firstboot"

MODE="install"          # install | pack | rollback
DEV_MODE=0
OFFLINE=0
OFFLINE_PKG=""
DO_DEPS=1
DO_RESTART=1
DO_FIRSTBOOT=1
DRY_RUN=0
ASSUME_YES=0

TS="$(date +%Y%m%d-%H%M%S)"
BACKUP="$BACKUP_ROOT/$TS"
MANIFEST="$BACKUP/manifest.tsv"

SRC_ROOT=""             # 源根：仓库根，或解包后的包根
SRC_OVERLAY=""
SRC_UNITS=""
SRC_SOFTWARE=""
VERSION=""

TMP_EXTRACT=""
ROLLBACK_ARMED=0

log()  { printf '\033[1;36m[install]\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33m[install] !!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[install] xx\033[0m %s\n' "$*" >&2; exit 1; }
step() { printf '\n\033[1;32m== %s\033[0m\n' "$*" >&2; }

usage() { sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0; }

cleanup() {
    local rc=$?
    set +e
    # 只删自己 mktemp 出来的那种目录（防止变量被污染后删到别处）
    case "${TMP_EXTRACT:-}" in
        */zelux-offline.*) rm -rf --one-file-system -- "$TMP_EXTRACT" 2>/dev/null || true ;;
    esac
    if [ "$rc" -ne 0 ] && [ "$ROLLBACK_ARMED" -eq 1 ]; then
        printf '\033[1;31m[install] xx\033[0m 安装失败（%s），开始回滚…\n' "$rc" >&2
        do_rollback "$BACKUP" || warn "回滚没完整成功，备份在 $BACKUP（手工拷回去）"
    fi
    exit "$rc"
}
trap cleanup EXIT INT TERM

# ---------------------------------------------------------------- 参数
need_val() { [ "$2" -ge 2 ] || die "$1 需要一个值（看 --help）"; }

while [ $# -gt 0 ]; do
    case "$1" in
        --dev) DEV_MODE=1; shift ;;
        --offline)
            OFFLINE=1
            if [ $# -ge 2 ] && [ "${2#-}" = "$2" ]; then OFFLINE_PKG="$2"; shift; fi
            shift
            ;;
        --pack) MODE=pack; shift ;;
        --rollback-last) MODE=rollback; shift ;;
        --no-deps) DO_DEPS=0; shift ;;
        --no-restart) DO_RESTART=0; shift ;;
        --no-firstboot) DO_FIRSTBOOT=0; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        --yes|-y) ASSUME_YES=1; shift ;;
        -h|--help) usage ;;
        *) die "不认识的参数：$1（--help 看全部）" ;;
    esac
done

# ---------------------------------------------------------------- 源解析
resolve_src() {
    if [ "$OFFLINE" -eq 1 ]; then
        local pkg="$OFFLINE_PKG"
        if [ -z "$pkg" ]; then
            # 没给路径：按约定在脚本目录/当前目录找一个
            local v
            v="$(tr -d '[:space:]' < "$REPO_ROOT/image/VERSION" 2>/dev/null || true)"
            for cand in "$SCRIPT_DIR/zelux-duck-${v}-arm64.tar.gz" \
                        "./zelux-duck-${v}-arm64.tar.gz" \
                        "$SCRIPT_DIR/zelux-duck-"*"-arm64.tar.gz"; do
                if [ -n "$cand" ] && [ -f "$cand" ]; then pkg="$cand"; break; fi
            done
        elif [ ! -f "$pkg" ] && [ -f "$SCRIPT_DIR/$pkg" ]; then
            pkg="$SCRIPT_DIR/$pkg"
        fi
        [ -n "$pkg" ] && [ -f "$pkg" ] || die "--offline 但找不到离线包（试着给全路径：--offline ./zelux-duck-<ver>-arm64.tar.gz）"

        if [ -f "${pkg}.sha256" ]; then
            local want got
            want="$(awk '{print $1}' "${pkg}.sha256" | head -1)"
            got="$(sha256sum "$pkg" | awk '{print $1}')"
            [ "$want" = "$got" ] || die "离线包 sha256 不对（期望 $want，实际 $got）"
            log "离线包校验通过：$(basename "$pkg")"
        else
            warn "没有 ${pkg}.sha256，跳过校验（自己确认来源）"
        fi

        TMP_EXTRACT="$(mktemp -d "${TMPDIR:-/tmp}/zelux-offline.XXXXXX")"
        tar -xzf "$pkg" -C "$TMP_EXTRACT" || die "解包失败"
        local cand2
        cand2="$(find "$TMP_EXTRACT" -maxdepth 2 -type d -name overlay | head -1)"
        [ -n "$cand2" ] || die "包里没有 overlay/ 目录（包结构不对）"
        SRC_ROOT="$(dirname "$cand2")"
        log "离线源：$SRC_ROOT"
    else
        local cand3
        for cand3 in "$SCRIPT_DIR" "$REPO_ROOT" "$REPO_ROOT/image"; do
            if [ -d "$cand3/overlay" ]; then SRC_ROOT="$cand3"; break; fi
        done
        [ -n "$SRC_ROOT" ] || die "找不到 overlay 目录。请在仓库的 image/ 目录里跑，或用 --offline ./zelux-duck-<ver>-arm64.tar.gz"
    fi

    SRC_OVERLAY="$SRC_ROOT/overlay"
    [ -d "$SRC_OVERLAY" ] || die "找不到 $SRC_OVERLAY"

    # 单元目录：仓库里在 software/systemd，包里在 units/
    SRC_UNITS="$SRC_ROOT/units"
    [ -d "$SRC_UNITS" ] || SRC_UNITS="$COMPONENT_ROOT/software/systemd"
    [ -d "$SRC_UNITS" ] || SRC_UNITS="$SRC_ROOT/../software/systemd"
    [ -d "$SRC_UNITS" ] || die "找不到 systemd 单元目录（units/ 或 software/systemd）"

    # 软件目录：包里 $SRC_ROOT/software，仓库里 $SRC_ROOT/../software
    SRC_SOFTWARE="$SRC_ROOT/software"
    [ -d "$SRC_SOFTWARE" ] || SRC_SOFTWARE="$COMPONENT_ROOT/software"
    [ -d "$SRC_SOFTWARE" ] || SRC_SOFTWARE="$SRC_ROOT/../software"
    [ -d "$SRC_SOFTWARE" ] || die "找不到 software 目录"

    VERSION=""
    for cand3 in "$SRC_ROOT/VERSION" "$SRC_ROOT/../image/VERSION" "$SCRIPT_DIR/VERSION"; do
        if [ -f "$cand3" ]; then VERSION="$(tr -d '[:space:]' < "$cand3")"; break; fi
    done
    [ -n "$VERSION" ] || die "找不到 VERSION 文件"
}

# ---------------------------------------------------------------- 打包（开发机用）
do_pack() {
    [ -d "$SCRIPT_DIR/overlay" ] || die "--pack 要在镜像仓库里跑（找不到 overlay）"
    [ -d "$COMPONENT_ROOT/software/zeluxd" ] || die "缺少 components；先运行 tools/assemble-components.sh"
    VERSION="$(tr -d '[:space:]' < "$SCRIPT_DIR/VERSION")"
    local stage name out
    stage="$(mktemp -d "${TMPDIR:-/tmp}/zelux-pack.XXXXXX")"
    name="zelux-duck-${VERSION}"
    mkdir -p "$stage/$name"
    cp -a "$SCRIPT_DIR/overlay" "$stage/$name/overlay"
    cp -a "$COMPONENT_ROOT/software/systemd" "$stage/$name/units"
    mkdir -p "$stage/$name/software"
    # 不带 __pycache__ / 本地状态：包里只放要跑的东西
    tar -C "$COMPONENT_ROOT/software" \
        --exclude='__pycache__' --exclude='*.pyc' --exclude='.pytest_cache' --exclude='var' \
        -cf - . | tar -C "$stage/$name/software" -xf -
    printf '%s\n' "$VERSION" > "$stage/$name/VERSION"
    cp "$SCRIPT_DIR/install.sh" "$stage/$name/install.sh" 2>/dev/null || true
    chmod 755 "$stage/$name/install.sh" 2>/dev/null || true
    out="$PWD/${name}-arm64.tar.gz"
    tar -C "$stage" -czf "$out" "$name" || die "打包失败"
    ( cd "$(dirname "$out")" && sha256sum "$(basename "$out")" > "$(basename "$out").sha256" )
    case "$stage" in
        */zelux-pack.*) rm -rf --one-file-system -- "$stage" 2>/dev/null || true ;;
    esac
    log "打包完成：$out"
    log "校验：$(cat "$out.sha256")"
    log "现场用法：sudo ./install.sh --offline $out"
}

# ---------------------------------------------------------------- 前置检查
check_preflight() {
    [ "$(id -u)" -eq 0 ] || die "要 root：sudo $PROG"
    [ -d /run/systemd/system ] || die "这台机器不是 systemd 启动的（容器？），装不了服务"
    command -v systemctl >/dev/null 2>&1 || die "没有 systemctl"
    command -v rsync >/dev/null 2>&1 || die "没有 rsync：apt install rsync"

    local arch
    arch="$(uname -m)"
    case "$arch" in
        aarch64|arm64) ;;
        *) warn "当前架构是 $arch，不是 aarch64：能装，但服务很可能起不来（镜像目标是 Radxa Zero 3W）" ;;
    esac
    if [ -r /etc/os-release ]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        [ "${ID:-}" = "debian" ] || warn "系统是 ${PRETTY_NAME:-未知}，不是 Debian（脚本按 bookworm 写）"
    fi

    [ -d "$OPT_ROOT" ] && [ -e "$OPT_ROOT/current" ] && log "检测到已有安装，按升级处理（旧版本目录会保留）"
}

confirm() {
    [ "$ASSUME_YES" -eq 1 ] && return 0
    printf '%s [y/N] ' "$1" >&2
    local ans=""
    read -r ans || true
    case "$ans" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

# ---------------------------------------------------------------- 备份 / 回滚
record_absent() {
    local path="$1"
    printf 'absent\t%s\n' "$path" >> "$MANIFEST"
}

backup_file() {
    local path="$1"
    if [ -e "$path" ]; then
        mkdir -p "$BACKUP$(dirname "$path")"
        cp -a "$path" "$BACKUP$path" || die "备份 $path 失败"
        printf 'file\t%s\n' "$path" >> "$MANIFEST"
    else
        record_absent "$path"
    fi
}

# 只允许回滚 /etc /usr/local /opt/zelux 下的路径（防手滑）
path_allowed() {
    case "$1" in
        /etc/*|/usr/local/*|"$OPT_ROOT"/*) return 0 ;;
        *) return 1 ;;
    esac
}

do_rollback() {
    local backup="$1"
    local manifest="$backup/manifest.tsv"
    [ -f "$manifest" ] || { warn "没有备份清单：$manifest"; return 1; }
    local kind path
    # 倒序还原：先还原后写的，语义上更接近"退回原样"
    while IFS=$'\t' read -r kind path; do
        [ -n "${path:-}" ] || continue
        path_allowed "$path" || { warn "跳过不在白名单里的路径：$path"; continue; }
        case "$kind" in
            file)
                if [ -e "$backup$path" ] || [ -L "$backup$path" ]; then
                    mkdir -p "$(dirname "$path")"
                    # 先删：目标可能是个指向目录的软链，cp -a 会顺着它往里拷
                    rm -f -- "$path"
                    cp -a "$backup$path" "$path" || warn "还原 $path 失败"
                fi
                ;;
            absent)
                [ -f "$path" ] && rm -f -- "$path" && log "已删除新增文件 $path"
                ;;
            *)
                warn "清单里有不认识的类型：$kind"
                ;;
        esac
    done < <(tac "$manifest" 2>/dev/null || cat "$manifest")
    # 本次新 enable 的服务要关掉（原来就开着的就别动）
    if [ -f "$backup/enabled-before.txt" ]; then
        local u
        for u in $UNITS_ENABLED; do
            if ! grep -qx "$u" "$backup/enabled-before.txt" 2>/dev/null; then
                systemctl disable --now "$u.service" >/dev/null 2>&1 || true
                log "已关闭本次新开的服务：$u"
            fi
        done
    fi
    systemctl daemon-reload 2>/dev/null || true
    log "回滚完成（备份留在 $backup）"
    return 0
}

# ---------------------------------------------------------------- 安装
install_files() {
    local rel
    step "备份将被覆盖的文件"
    mkdir -p "$BACKUP" "$BACKUP_ROOT"
    : > "$MANIFEST"
    chmod 700 "$BACKUP_ROOT" "$BACKUP" 2>/dev/null || true

    # overlay 里所有文件 + 单元文件，逐个记进清单
    ( cd "$SRC_OVERLAY" && find . -type f -print ) | while IFS= read -r rel; do
        rel="${rel#./}"
        case "$rel" in
            opt/zelux/README.md) continue ;;    # 占位说明，不用备份
        esac
        printf '%s\n' "/$rel"
    done > "$BACKUP/planned.txt"
    local f
    for f in "$SRC_UNITS"/*.service; do
        [ -e "$f" ] || continue
        printf '%s\n' "/etc/systemd/system/$(basename "$f")" >> "$BACKUP/planned.txt"
    done

    while IFS= read -r rel; do
        [ -n "$rel" ] || continue
        backup_file "$rel"
    done < "$BACKUP/planned.txt"
    ROLLBACK_ARMED=1
    log "已备份 $(grep -c '^file' "$MANIFEST" 2>/dev/null || echo 0) 个文件到 $BACKUP"

    step "写入 overlay（/etc /usr/local）"
    rsync -aHAX --numeric-ids --exclude 'opt/zelux/README.md' "$SRC_OVERLAY/" "/"

    step "写入 systemd 单元（以 software/systemd 为准）"
    for f in "$SRC_UNITS"/*.service; do
        [ -e "$f" ] || continue
        install -D -m 0644 "$f" "/etc/systemd/system/$(basename "$f")"
    done

    step "安装软件到 $OPT_ROOT/releases/$VERSION"
    local rel_dir="$OPT_ROOT/releases/$VERSION"
    mkdir -p "$rel_dir/software" "$OPT_ROOT/releases"
    rsync -aHAX --numeric-ids \
        --exclude '__pycache__/' --exclude '*.pyc' --exclude '.pytest_cache/' --exclude 'var/' \
        "$SRC_SOFTWARE/" "$rel_dir/software/"
    if [ ! -d "$rel_dir/software/web" ]; then
        mkdir -p "$rel_dir/software/web"
        printf '<!doctype html><meta charset="utf-8"><title>ZELUX</title><body style="font:16px system-ui;background:#0B0F14;color:#F6F8FA;padding:40px"><h1 style="color:#00D8A0">ZELUX Duck Studio</h1><p>后端在跑，但这台机器上没有前端文件（software/web）。</p></body>\n' \
            > "$rel_dir/software/web/index.html"
        warn "没有 software/web，放了占位页"
    fi
    printf '%s\n' "$VERSION" > "$OPT_ROOT/VERSION"

    if [ "$DEV_MODE" -eq 1 ]; then
        # 开发模式：current 指向真实仓库，改一行代码 restart 就能看到
        backup_file "$OPT_ROOT/current"
        mkdir -p "$OPT_ROOT/dev"
        ln -sfn "$SRC_SOFTWARE" "$OPT_ROOT/dev/software"
        ln -sfn "$OPT_ROOT/dev" "$OPT_ROOT/current"
        log "开发模式：$OPT_ROOT/current -> $SRC_SOFTWARE"
    else
        backup_file "$OPT_ROOT/current"
        ln -sfn "releases/$VERSION" "${OPT_ROOT}/current"
    fi
}

apply_perms() {
    local f
    chmod 755 /usr/local/bin /usr/local/sbin 2>/dev/null || true
    for f in /usr/local/bin/* /usr/local/sbin/*; do
        [ -f "$f" ] || continue
        chmod 755 "$f"
    done
    chmod 644 /etc/zelux/zelux.toml 2>/dev/null || true
    for f in /etc/systemd/system/*.service; do
        [ -f "$f" ] && chmod 644 "$f"
    done
    for f in /etc/NetworkManager/system-connections/*.nmconnection; do
        [ -f "$f" ] || continue
        chmod 600 "$f"
        chown 0:0 "$f" 2>/dev/null || true
    done
    chmod 644 /etc/udev/rules.d/99-zelux.rules 2>/dev/null || true
    chmod 644 /etc/polkit-1/rules.d/49-zelux.rules 2>/dev/null || true
    chmod 644 /etc/tmpfiles.d/zelux.conf 2>/dev/null || true
}

ensure_user() {
    step "用户与分组"
    if id zelux >/dev/null 2>&1; then
        log "zelux 用户已存在"
    else
        useradd --user-group --shell /bin/bash --comment "ZELUX Duck Studio" --create-home zelux \
            || die "建用户 zelux 失败"
        log "已建 zelux 用户（暂时没有口令，首启会设）"
    fi
    local g
    for g in gpio i2c spi dialout video audio netdev plugdev; do
        if getent group "$g" >/dev/null 2>&1; then
            usermod -a -G "$g" zelux 2>/dev/null || warn "加组 $g 失败"
        else
            groupadd -r "$g" 2>/dev/null && usermod -a -G "$g" zelux 2>/dev/null || true
        fi
    done
    mkdir -p "$STATE_DIR/models" "$STATE_DIR/shots" "$STATE_DIR/backup"
    chown zelux:zelux "$STATE_DIR" "$STATE_DIR/models" "$STATE_DIR/shots" 2>/dev/null || true
    chmod 750 "$STATE_DIR"
    chmod 700 "$STATE_DIR/backup" 2>/dev/null || true
}

configure_network() {
    if ! command -v nmcli >/dev/null 2>&1; then
        warn "没有 nmcli：跳过热点连接文件（WiFi 兜底不可用）"
        return 0
    fi
    step "让 NetworkManager 认新连接"
    nmcli connection reload 2>/dev/null || warn "nmcli connection reload 失败"
    if ! nmcli -t -f NAME connection show 2>/dev/null | grep -qx 'zelux-ap'; then
        warn "zelux-ap 没被加载：检查 /etc/NetworkManager/system-connections/zelux-ap.nmconnection 权限（要 0600）"
    fi
    if ! command -v dnsmasq >/dev/null 2>&1; then
        warn "没有 dnsmasq-base：热点开了也不会发 IP。apt install -y dnsmasq-base（有网时）"
    fi
}

enable_services() {
    step "打开服务"
    systemctl daemon-reload || die "daemon-reload 失败"
    local u
    # 记下装之前的状态：回滚时只关掉"本次新开"的，别把用户原来开着的服务关了
    : > "$BACKUP/enabled-before.txt"
    for u in $UNITS_ENABLED; do
        if systemctl is-enabled --quiet "$u.service" 2>/dev/null; then
            printf '%s\n' "$u" >> "$BACKUP/enabled-before.txt"
        fi
    done
    for u in $UNITS_ENABLED; do
        systemctl enable "$u.service" >/dev/null 2>&1 || warn "enable $u 失败"
    done
    systemctl restart zelux-fand.service || warn "zelux-fand 起不来（风扇会不转，看 journal）"
    if [ "$DO_RESTART" -eq 1 ]; then
        systemctl restart zeluxd.service || warn "zeluxd 重启失败"
    fi
}

run_firstboot() {
    [ "$DO_FIRSTBOOT" -eq 1 ] || { log "--no-firstboot：跳过"; return 0; }
    if [ -e "$STATE_DIR/.initialized" ]; then
        log "已经初始化过，跳过首启逻辑"
        return 0
    fi
    step "首次初始化（口令 / hostname / 扩容 / WiFi 兜底）"
    if [ -x /usr/local/bin/zelux-firstboot ]; then
        /usr/local/bin/zelux-firstboot || warn "首启脚本有步骤失败（多数情况不影响开机，看上面的日志）"
    fi
}

verify() {
    [ "$DO_RESTART" -eq 1 ] || { log "--no-restart：跳过健康检查"; return 0; }
    step "健康检查"
    local i
    for i in $(seq 1 25); do
        if systemctl is-active --quiet zeluxd.service; then
            log "zeluxd 在跑"
            break
        fi
        sleep 1
        if [ "$i" -eq 25 ]; then
            warn "zeluxd 25 秒内没起来，最近日志："
            journalctl -u zeluxd.service -n 30 --no-pager 2>/dev/null >&2 || true
            return 1
        fi
    done
    if command -v curl >/dev/null 2>&1; then
        local port
        port="$(/usr/local/bin/zeluxd-run --print-env 2>/dev/null | awk -F= '/^ZELUX_PORT=/{print $2}')"
        port="${port:-8000}"
        if curl -fsS --max-time 5 "http://127.0.0.1:${port}/" >/dev/null 2>&1; then
            log "HTTP :${port} 有响应"
        else
            warn "HTTP :${port} 没响应（可能是前端缺文件，或还在启动）"
        fi
    fi
    return 0
}

summary() {
    local ip port
    ip="$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1 || true)"
    port="$(/usr/local/bin/zeluxd-run --print-env 2>/dev/null | awk -F= '/^ZELUX_PORT=/{print $2}')"
    port="${port:-8000}"
    cat >&2 <<EOF

================== 安装完成 ==================
版本      : $VERSION
软件目录  : $OPT_ROOT/current -> $(readlink -f "$OPT_ROOT/current" 2>/dev/null || echo "?")
备份      : $BACKUP
服务      : systemctl status zeluxd zelux-fand
网页      : $(if [ -n "$ip" ]; then echo "http://${ip}:${port}"; else echo "还没拿到 IP：zelux-wifi status"; fi)
口令      : 见 /etc/zelux/zelux.toml 的 [system].password（默认 zelux，登录后请改）
风扇      : fanctl --status    （root 助手：/run/zelux/fan.sock）
ToF       : zelux-tof-install  （只是想看：加 --check 效果一样，默认就是诊断）
升级      : sudo zelux-deps && sudo systemctl restart zeluxd
回滚      : sudo $PROG --rollback-last
==============================================
EOF
}

# ---------------------------------------------------------------- 主流程
main() {
    if [ "$MODE" = "pack" ]; then
        do_pack
        return 0
    fi

    [ "$(id -u)" -eq 0 ] || die "要 root：sudo $PROG"

    if [ "$MODE" = "rollback" ]; then
        local last=""
        last="$(ls -1d "$BACKUP_ROOT"/*/ 2>/dev/null | sort | tail -1 || true)"
        [ -n "$last" ] || die "没有备份可回滚（$BACKUP_ROOT 是空的）"
        last="${last%/}"
        log "回滚到：$last"
        confirm "确认把 /etc、/usr/local、/opt/zelux 恢复到 $last 的状态？" || die "已取消"
        do_rollback "$last"
        return 0
    fi

    resolve_src
    check_preflight

    log "版本 $VERSION    源 $SRC_ROOT"
    if [ "$DRY_RUN" -eq 1 ]; then
        step "DRY RUN：以下是会写入/覆盖的路径（没有真写）"
        ( cd "$SRC_OVERLAY" && find . -type f -print ) | sed 's#^\./##' | sed 's#^#/#' >&2
        printf '/etc/systemd/system/{zeluxd,zelux-fand,zelux-firstboot,zelux-update}.service\n' >&2
        printf '%s/releases/%s/software/**\n' "$OPT_ROOT" "$VERSION" >&2
        printf '%s/current -> releases/%s\n' "$OPT_ROOT" "$VERSION" >&2
        printf '\n会重启：zelux-fand, zeluxd（--no-restart 可跳过）\n' >&2
        printf '备份目录：%s\n' "$BACKUP" >&2
        return 0
    fi

    step "确认"
    if ! confirm "把 ZELUX $VERSION 装到这台机器（会重启 zeluxd，备份在 $BACKUP）？"; then
        die "已取消"
    fi

    install_files
    apply_perms
    ensure_user
    configure_network

    if [ "$DO_DEPS" -eq 1 ]; then
        step "Python 依赖"
        if /usr/local/bin/zelux-deps --check >/dev/null 2>&1; then
            log "依赖已就绪"
        else
            /usr/local/bin/zelux-deps || warn "依赖没装全（zeluxd 可能起不来；有网时重跑 sudo zelux-deps）"
        fi
    else
        log "--no-deps：跳过依赖安装"
    fi

    systemd-tmpfiles --create /etc/tmpfiles.d/zelux.conf >/dev/null 2>&1 || true
    udevadm control --reload-rules >/dev/null 2>&1 || true
    udevadm trigger --subsystem-match=tty >/dev/null 2>&1 || true

    enable_services
    run_firstboot

    if ! verify; then
        ROLLBACK_ARMED=1
        die "健康检查没过（已自动回滚，备份见 $BACKUP）"
    fi

    ROLLBACK_ARMED=0
    summary
}

main "$@"
