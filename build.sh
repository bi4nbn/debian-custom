#!/bin/bash
set -euo pipefail

# ====================== 配置区 ======================
ISO_IN="/opt/debian-12.9.0-amd64-netinst.iso"
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

# 打印日志工具
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
    rm -f "$TMP_EFI_IMG"
}

# 安装依赖
install_deps() {
    info "安装构建依赖"
    apt update && apt install -y xorriso rsync mtools
}

# 前置文件校验
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

# 1. 完整初始化ISO目录
init_iso_tree() {
    clean_mount
    rm -rf "$WORK"
    mkdir -p "$WORK/mnt" "$WORK/iso" "$WORK/iso/extra"

    # 拷贝自定义文件，赋予执行权限
    info "拷贝自定义extra文件"
    for f in "${EXTRA_FILES[@]}"; do
        cp "$f" "$WORK/iso/extra/"
    done
    chmod 755 "$WORK/iso/extra/"*
    ls -la "$WORK/iso/extra/"

    # 挂载原版ISO同步文件树
    info "挂载原版ISO同步文件树"
    mount -o loop "$ISO_IN" "$WORK/mnt"
    rsync -av "$WORK/mnt/" "$WORK/iso/"
    chmod -R u+w "$WORK/iso/"
    umount "$WORK/mnt"

    # 放入preseed.cfg
    cp "$PRESEED" "$WORK/iso/"
    info "ISO目录树初始化完成"
}

# 2. 仅修补UEFI grub配置，删除全部BIOS/isolinux代码
patch_boot_config() {
    info "修补UEFI grub配置"
    local ISO_ROOT="$WORK/iso"
    local GRUB_CFG="$ISO_ROOT/boot/grub/grub.cfg"
    local EFI_IMG="$ISO_ROOT/boot/grub/efi.img"
    local GRUB_TEXT="set default=0
set timeout=3
menuentry \"SSCLOUD Debian Auto Install\" {
    linux /install.amd/vmlinuz auto=true priority=critical preseed/file=/cdrom/preseed.cfg debian-installer/force_quiet=true --- quiet
    initrd /install.amd/initrd.gz
}"

    chmod -R u+w "$ISO_ROOT/boot/grub"
    [ ! -f "$GRUB_CFG" ] && err "缺失 $GRUB_CFG" && exit 1
    echo "$GRUB_TEXT" > "$GRUB_CFG"

    if [ -f "$EFI_IMG" ]; then
        cp "$EFI_IMG" "$TMP_EFI_IMG"
        mkdir -p "$TMP_EFI_MOUNT"
        mount -o loop "$TMP_EFI_IMG" "$TMP_EFI_MOUNT"
        # 修正：直接写根目录grub.cfg，不存在grub子文件夹
        echo "$GRUB_TEXT" > "$TMP_EFI_MOUNT/grub.cfg"
        umount "$TMP_EFI_MOUNT"
        cp "$TMP_EFI_IMG" "$EFI_IMG"
        rm -f "$TMP_EFI_IMG"
    fi
    info "UEFI引导修补完成"
}

# 3. 打包：移除所有BIOS/ISOLINUX参数，仅保留EFI引导
build_iso() {
    info "开始打包纯UEFI ISO"
    cd "$WORK/iso"
    xorriso -as mkisofs \
      -r -V "Debian UEFI Custom" \
      -J -joliet-long \
      -cache-inodes \
      -eltorito-alt-boot \
      -e boot/grub/efi.img \
      -no-emul-boot \
      -o "$OUT" .
    cd /root
    info "✅ 纯UEFI ISO生成完毕：$OUT"
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
            cp "$PRESEED" "$WORK/iso/"
            patch_boot_config
            build_iso
            ;;
        *)
            err "参数错误，用法："
            err "  $0 deps    一次性安装所有依赖"
            err "  $0 full    完整重建（首次/修改extra文件）"
            err "  $0 config  仅更新preseed/grub快速重打包"
            exit 1
            ;;
    esac
}

main "$@"
