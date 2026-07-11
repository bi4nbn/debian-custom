#!/bin/bash
set -euo pipefail

# ====================== 配置区 ======================
ISO_IN="/root/debian-12.9.0-amd64-DVD-1.iso"
PRESEED="/root/preseed.cfg"
OUT="/root/debian-custom.iso"
WORK="/root/iso-work"
EXTRA_FILES=(
    "/root/netcfg"
    "/root/init.sh"
)
# ====================================================

# 全局临时挂载点
TMP_EFI_MOUNT="/tmp/efi_mount"
TMP_EFI_IMG="/tmp/efi.img.tmp"

# 打印日志工具（修复颜色码）
info() {
    echo -e "\033[32m[INFO] $1\033[0m"
}
err() {
    echo -e "\033[31m[ERROR] $1\033[0m" >&2
}

# 清理挂载残留
clean_mount() {
    info "清理残留挂载点"
    umount "$WORK/mnt" 2>/dev/null || true
    umount "$TMP_EFI_MOUNT" 2>/dev/null || true
}

# 安装依赖（手动执行一次即可，脚本不再自动调用）
install_deps() {
    info "安装构建依赖"
    apt update && apt install -y xorriso isolinux rsync mtools
}

# 前置文件校验（缺失文件打印报错）
check_base_files() {
    info "校验基础文件"
    if [ ! -f "$ISO_IN" ]; then
        err "$ISO_IN 不存在"
        exit 1
    fi
    if [ ! -f "$PRESEED" ]; then
        err "$PRESEED 不存在"
        exit 1
    fi
    for f in "${EXTRA_FILES[@]}"; do
        if [ ! -f "$f" ]; then
            err "自定义文件缺失: $f"
            exit 1
        fi
    done
}

# 1. 完整初始化ISO目录（挂载原版+同步文件+拷贝extra）
init_iso_tree() {
    clean_mount
    # 重建工作目录
    rm -rf "$WORK"
    mkdir -p "$WORK/mnt" "$WORK/iso" "$WORK/iso/extra"

    # 拷贝extra自定义文件
    info "拷贝自定义extra文件"
    for f in "${EXTRA_FILES[@]}"; do
        cp "$f" "$WORK/iso/extra/"
    done
    chmod 644 "$WORK/iso/extra/"*
    ls -la "$WORK/iso/extra/"

    # 挂载原版ISO同步文件树
    info "挂载原版ISO同步文件树"
    mount -o loop "$ISO_IN" "$WORK/mnt"
    rsync -av --exclude='extra' "$WORK/mnt/" "$WORK/iso/"
    umount "$WORK/mnt"

    # 放入preseed.cfg
    cp "$PRESEED" "$WORK/iso/"
    info "ISO目录树初始化完成"
}

# 2. 修改BIOS+UEFI所有引导配置（可重复执行）
patch_boot_config() {
    info "开始修补BIOS/UEFI引导配置"
    local ISO_ROOT="$WORK/iso"
    # BIOS txt.cfg & isolinux.cfg
    local ISOLINUX_DIR="$ISO_ROOT/isolinux"
    sed -i '/^\s*append/ s/$/ auto=true priority=critical preseed\/file=\/cdrom\/preseed.cfg --- quiet/' \
        "$ISOLINUX_DIR/txt.cfg"
    sed -i 's/^timeout.*/timeout 10/' "$ISOLINUX_DIR/isolinux.cfg"
    sed -i 's/^default.*/default install/' "$ISOLINUX_DIR/isolinux.cfg"
    grep -q "^menu hidden" "$ISOLINUX_DIR/isolinux.cfg" || echo "menu hidden" >> "$ISOLINUX_DIR/isolinux.cfg"
    chmod +w -R "$ISOLINUX_DIR"

    # UEFI grub.cfg
    local GRUB_CFG="$ISO_ROOT/boot/grub/grub.cfg"
    [ ! -f "$GRUB_CFG" ] && err "找不到 $GRUB_CFG" && exit 1
    sed -i '/^[[:space:]]*set[[:space:]]\+default=/d' "$GRUB_CFG"
    sed -i '/^[[:space:]]*set[[:space:]]\+timeout=/d' "$GRUB_CFG"
    { echo "set default=0"; echo "set timeout=1"; cat "$GRUB_CFG"; } > "$GRUB_CFG.tmp"
    mv "$GRUB_CFG.tmp" "$GRUB_CFG"
    sed -i '/^\s*linux/ s/$/ auto=true priority=critical preseed\/file=\/cdrom\/preseed.cfg --- quiet/' "$GRUB_CFG"
    info "grub.cfg头部预览:"
    head -5 "$GRUB_CFG"

    # 修补efi.img内grub.cfg
    local EFI_IMG="$ISO_ROOT/boot/grub/efi.img"
    if [ -f "$EFI_IMG" ]; then
        info "修补efi.img内部grub配置"
        cp "$EFI_IMG" "$TMP_EFI_IMG"
        mkdir -p "$TMP_EFI_MOUNT"
        mount -o loop "$TMP_EFI_IMG" "$TMP_EFI_MOUNT"
        for cfg in $(find "$TMP_EFI_MOUNT" -name "grub.cfg" -type f); do
            sed -i '/^[[:space:]]*set[[:space:]]\+default=/d' "$cfg"
            sed -i '/^[[:space:]]*set[[:space:]]\+timeout=/d' "$cfg"
            { echo "set default=0"; echo "set timeout=1"; cat "$cfg"; } > "$cfg.tmp"
            mv "$cfg.tmp" "$cfg"
        done
        umount "$TMP_EFI_MOUNT"
        cp "$TMP_EFI_IMG" "$EFI_IMG"
        rm -f "$TMP_EFI_IMG"
    else
        info "未检测到efi.img，跳过EFI镜像修改"
    fi

    info "引导配置修补完成"
}

# 3. 打包生成ISO
build_iso() {
    info "开始打包定制ISO"
    local ISOHDPFX=$(find /usr -name isohdpfx.bin 2>/dev/null | head -1)
    [ -z "$ISOHDPFX" ] && err "找不到isohdpfx.bin，请执行 ./build.sh deps 安装依赖" && exit 1

    cd "$WORK/iso"
    xorriso -as mkisofs \
      -r -V "Debian custom" \
      -J -joliet-long \
      -cache-inodes \
      -isohybrid-mbr "$ISOHDPFX" \
      -b isolinux/isolinux.bin \
      -c isolinux/boot.cat \
      -boot-load-size 4 -boot-info-table -no-emul-boot \
      -eltorito-alt-boot \
      -e boot/grub/efi.img \
      -no-emul-boot -isohybrid-gpt-basdat \
      -o "$OUT" .
    cd /root
    info "✅ ISO生成完毕：$OUT"
    info "工作目录保留：$WORK"
}

# ====================== 入口逻辑 ======================
main() {
    check_base_files

    case "${1:-full}" in
        deps)
            install_deps
            exit 0
            ;;
        full)
            info "=== 完整重建模式 full ==="
            init_iso_tree
            patch_boot_config
            build_iso
            ;;
        config)
            info "=== 仅更新配置模式 config ==="
            if [ ! -d "$WORK/iso" ] || [ ! -f "$WORK/iso/preseed.cfg" ]; then
                err "工作目录不存在，请先执行 $0 full 初始化ISO目录"
                exit 1
            fi
            # 覆盖最新preseed
            cp "$PRESEED" "$WORK/iso/"
            patch_boot_config
            build_iso
            ;;
        *)
            err "参数错误，用法："
            err "  $0 deps    一次性安装所有依赖"
            err "  $0 full    完整重建（首次/替换原版ISO/修改netcfg/init.sh）"
            err "  $0 config  仅更新引导/preseed，快速重打包（改配置专用）"
            exit 1
            ;;
    esac
}

main "$@"