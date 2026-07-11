#!/bin/bash
set -euo pipefail

# 配置项
AUTHORIZED_KEY="ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQDC8s1el1MUWsPgmSmJ1npXoiEkIdBlrBk5QbVm5/3USPUGt1GQ9XAvyufuDklLjK1Gz7IGSS0wu3iZH9u2baGvaHUxQZaOYgFf24nIUe4kv/Rba+4zWI3gajZk2WKJV1dr3diGHs9JLjeoX4ZiszRSAZi+zxs8BWj/7V2X5RoeaUwGvCdvpCAwET7N7Jdu9/WBG5ZoK7ypp1+B5EEc8TlLse5PcRdYnLh3arLSt/FDL8NpcjUgRgPTGUmT53cGvo8RXuVfE0W9+9JAO1b6GQFR8rBN3gkhHNSx5hGQeLHYN4WNuUo8/eTJ6hRYFJNG1kFEtaB8IX9WEATwFiso800TsthTa0EYVdHbatkGkDjBJBWeF8yc4Tg4af+FEigH7hYfEsLxBejcFBmFmaeBAx4RGwzGlX4J8xVvPoW7Yul0Ln2hTUwRwG3pZ0xcqX/CMj8BfvUbYNSLOqwInUspmwRfn6dxayMpcg9GEkLyM+VwseVmV+YQ0gKrTYwd2rCzKN2PinJVSkP8i2mA7+bnESELjoz9VLHucXT+TOVbLJsxRUnoIYQe6mw/bjAYM79E/8IOqafSaxuxMQ6NubL12K3CY2lC3H0VTi2+KoHCUO0ZEvrez0X5KjwGPreaa9CCygqF5497iGA88sVgTuD8KCPZEJmJEulYIeZ2QIAlnOBnaw== bi4nbn@qq.com"
SSHD_CONFIG="/etc/ssh/sshd_config"
USER_HOME="/root"
TIMESTAMP=$(date +%Y-%m-%d-%H:%M:%S)
SSH_DIR="${USER_HOME}/.ssh"
AUTH_KEY_FILE="${SSH_DIR}/authorized_keys"

[ "$(id -u)" -ne 0 ] && echo "请以root运行" >&2 && exit 1

# ========== 识别 Debian 版本代号（兼容 Debian 11/12/13）==========
VER=""
if [ -f /etc/os-release ]; then
    # 优先使用 /etc/os-release 中的 VERSION_CODENAME
    . /etc/os-release
    VER="${VERSION_CODENAME:-}"
fi

if [ -z "$VER" ] && command -v lsb_release &>/dev/null; then
    VER=$(lsb_release -cs)
fi

if [ -z "$VER" ]; then
    # 回退方案：通过 /etc/debian_version 映射版本号
    if [ -f /etc/debian_version ]; then
        DEB_MAJOR=$(cut -d. -f1 /etc/debian_version)
        case "$DEB_MAJOR" in
            11) VER="bullseye" ;;
            12) VER="bookworm" ;;
            13) VER="trixie"   ;;
            *)  echo "错误：不支持的 Debian 版本 ($DEB_MAJOR)" >&2; exit 1 ;;
        esac
    else
        echo "错误：无法确定 Debian 版本" >&2
        exit 1
    fi
fi

# 验证获取到的代号是否在支持列表中
case "$VER" in
    bullseye|bookworm|trixie) ;;
    *) echo "错误：未知的 Debian 代号 '$VER'，请联系维护者" >&2; exit 1 ;;
esac
# ============================================================

# 替换华为云源
cat > /etc/apt/sources.list << EOF
deb https://mirrors.huaweicloud.com/debian/ $VER main contrib non-free non-free-firmware
deb https://mirrors.huaweicloud.com/debian/ $VER-updates main contrib non-free non-free-firmware
deb https://mirrors.huaweicloud.com/debian/ $VER-backports main contrib non-free non-free-firmware
deb https://mirrors.huaweicloud.com/debian-security/ $VER-security main contrib non-free non-free-firmware
EOF

# 同时处理新的 DEB822 格式源文件（如果存在）
if [ -f /etc/apt/sources.list.d/debian.sources ]; then
    sed -i 's/deb.debian.org/mirrors.huaweicloud.com/g' /etc/apt/sources.list.d/debian.sources
fi

# 更新源索引
apt update -y

# 备份原配置
cp -f "$SSHD_CONFIG" "${SSHD_CONFIG}.bak.$TIMESTAMP"
[ -f "$AUTH_KEY_FILE" ] && cp -f "$AUTH_KEY_FILE" "${AUTH_KEY_FILE}.bak.$TIMESTAMP"

# 写入公钥
mkdir -p "$SSH_DIR"
echo "$AUTHORIZED_KEY" > "$AUTH_KEY_FILE"
chown -R root:root "$SSH_DIR"
chmod 700 "$SSH_DIR"
chmod 600 "$AUTH_KEY_FILE"

# 生成新的 sshd_config（使用你提供的完整配置）
cat > "$SSHD_CONFIG" << 'SSHD_EOF'
# ==================SSCLOUD SSHD CONFIGURATION==================
# 仅允许 root 通过密钥登录，拒绝其他所有用户
AllowUsers root
PermitRootLogin prohibit-password
PubkeyAuthentication yes

# 完全禁止密码和键盘交互
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no

# 其他安全与性能设置（可选但推荐）
LoginGraceTime 10s
MaxAuthTries 3
MaxSessions 5
MaxStartups 10:30:50

Protocol 2
UsePAM yes
StrictModes yes
LogLevel VERBOSE

# 关闭不需要的功能
AllowAgentForwarding no
AllowTcpForwarding no
X11Forwarding no
PermitTunnel no
GatewayPorts no
PermitUserEnvironment no
PrintMotd no
AcceptEnv LANG LC_*
Subsystem sftp /usr/lib/openssh/sftp-server
SSHD_EOF

# 语法校验，出错自动回滚
if ! sshd -t; then
    cp -f "${SSHD_CONFIG}.bak.$TIMESTAMP" "$SSHD_CONFIG"
    echo "SSH配置错误，已自动回滚" >&2
    exit 1
fi

# 重启SSH服务
systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null || service ssh restart 2>/dev/null || /etc/init.d/ssh restart

# 下载网络配置脚本
wget -qO /usr/local/bin/netcfg bash.niteng.net/netcfg && chmod +x /usr/local/bin/netcfg

echo "OJ8K. SSH config backup: ${SSHD_CONFIG}.bak.$TIMESTAMP"
echo -e "Run the command \033[32mnetcfg\033[0m to configure network"