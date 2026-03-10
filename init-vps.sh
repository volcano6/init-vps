#!/usr/bin/env bash
# --------------------------------------------------------
# 生产级 VPS 自动化初始化脚本 V5
# 支持: Ubuntu 22.04 / 24.04
# 特性:
# - 幂等执行
# - 严格校验
# - SSH 加固
# - Docker 官方源安装
# - Swap / BBR
# - Fail2ban
# - 清理 snapd
#
# 使用方式:
#   交互式:
#     sudo bash init-vps.sh
#
#   非交互式:
#     SSH_PORT=24153 SWAP_SIZE=2 TIMEZONE=Asia/Shanghai SSH_KEY="ssh-ed25519 AAAA..." sudo bash init-vps.sh
# --------------------------------------------------------

set -Eeuo pipefail

# ===== 全局变量（可通过环境变量覆盖） =====
SSH_PORT="${SSH_PORT:-}"
SWAP_SIZE="${SWAP_SIZE:-}"
TIMEZONE="${TIMEZONE:-}"
SSH_KEY="${SSH_KEY:-}"
TARGET_USER="${TARGET_USER:-ubuntu}"
SYSTEM_UPGRADE="${SYSTEM_UPGRADE:-yes}"   # yes / no
INSTALL_DOCKER="${INSTALL_DOCKER:-yes}"   # yes / no
ENABLE_BBR="${ENABLE_BBR:-yes}"           # yes / no
REMOVE_SNAPD="${REMOVE_SNAPD:-yes}"       # yes / no

# ===== 输出函数 =====
log_info() { echo -e "\033[32m[INFO]\033[0m $*"; }
log_warn() { echo -e "\033[33m[WARN]\033[0m $*"; }
log_err()  { echo -e "\033[31m[ERROR]\033[0m $*"; exit 1; }

# ===== 基础检查 =====
check_root() {
    [[ "${EUID}" -eq 0 ]] || log_err "请使用 root 权限运行: sudo bash init-vps.sh"
}

check_os() {
    [[ -f /etc/os-release ]] || log_err "无法识别系统。"
    . /etc/os-release

    [[ "${ID:-}" == "ubuntu" ]] || log_err "仅支持 Ubuntu，当前系统: ${ID:-unknown}"
    case "${VERSION_ID:-}" in
        22.04|24.04) ;;
        *)
            log_warn "当前 Ubuntu 版本为 ${VERSION_ID:-unknown}，脚本主要针对 22.04 / 24.04 验证。"
            ;;
    esac
}

# ===== 参数收集与校验 =====
prompt_if_empty() {
    local var_name="$1"
    local prompt_text="$2"
    local default_value="$3"
    local current_value="${!var_name:-}"

    if [[ -z "${current_value}" ]]; then
        read -r -p "${prompt_text} [默认: ${default_value}]: " current_value
        current_value="${current_value:-$default_value}"
        printf -v "$var_name" '%s' "$current_value"
    fi
}

collect_params() {
    echo -e "\033[36m=================================================\033[0m"
    echo -e "\033[36m        VPS 初始化向导 (Ubuntu 专用)         \033[0m"
    echo -e "\033[36m=================================================\033[0m"

    prompt_if_empty SSH_PORT "👉 1. 请输入 SSH 端口" "24153"
    prompt_if_empty SWAP_SIZE "👉 2. 请输入 Swap 大小(GB)，填 0 不创建" "2"
    prompt_if_empty TIMEZONE "👉 3. 请输入系统时区" "Asia/Shanghai"

    if [[ -z "${SSH_KEY}" ]]; then
        echo "👉 4. 请粘贴登录 [${TARGET_USER}] 账号的 SSH 公钥:"
        read -r SSH_KEY
    fi
}

validate_params() {
    [[ "${SSH_PORT}" =~ ^[0-9]+$ ]] || log_err "SSH_PORT 必须是数字。"
    (( SSH_PORT >= 1 && SSH_PORT <= 65535 )) || log_err "SSH_PORT 必须在 1-65535 之间。"

    [[ "${SWAP_SIZE}" =~ ^[0-9]+$ ]] || log_err "SWAP_SIZE 必须是非负整数。"

    timedatectl list-timezones | grep -qx "${TIMEZONE}" || log_err "TIMEZONE 无效: ${TIMEZONE}"

    echo "${SSH_KEY}" | grep -Eq '^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521|sk-ssh-ed25519@openssh\.com|sk-ecdsa-sha2-nistp256@openssh\.com) ' \
        || log_err "SSH_KEY 格式无效。"

    [[ "${SYSTEM_UPGRADE}" =~ ^(yes|no)$ ]] || log_err "SYSTEM_UPGRADE 只能是 yes 或 no"
    [[ "${INSTALL_DOCKER}" =~ ^(yes|no)$ ]] || log_err "INSTALL_DOCKER 只能是 yes 或 no"
    [[ "${ENABLE_BBR}" =~ ^(yes|no)$ ]] || log_err "ENABLE_BBR 只能是 yes 或 no"
    [[ "${REMOVE_SNAPD}" =~ ^(yes|no)$ ]] || log_err "REMOVE_SNAPD 只能是 yes 或 no"
}

show_summary() {
    echo
    echo "========== 参数确认 =========="
    echo "用户:              ${TARGET_USER}"
    echo "SSH 端口:          ${SSH_PORT}"
    echo "Swap(GB):          ${SWAP_SIZE}"
    echo "时区:              ${TIMEZONE}"
    echo "系统升级:          ${SYSTEM_UPGRADE}"
    echo "安装 Docker:       ${INSTALL_DOCKER}"
    echo "启用 BBR:          ${ENABLE_BBR}"
    echo "移除 snapd:        ${REMOVE_SNAPD}"
    echo "=============================="
    echo
}

# ===== 系统准备 =====
install_base_tools() {
    log_info "更新软件源索引..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y

    if [[ "${SYSTEM_UPGRADE}" == "yes" ]]; then
        log_info "执行系统升级..."
        apt-get upgrade -y
    else
        log_info "跳过系统升级。"
    fi

    log_info "安装基础工具..."
    apt-get install -y \
        ca-certificates \
        curl \
        wget \
        vim \
        tmux \
        htop \
        ncdu \
        jq \
        git \
        unzip \
        software-properties-common \
        apt-transport-https \
        fail2ban \
        openssh-server
}

set_timezone() {
    log_info "设置系统时区为 ${TIMEZONE}..."
    timedatectl set-timezone "${TIMEZONE}"
}

cleanup_snapd() {
    [[ "${REMOVE_SNAPD}" == "yes" ]] || {
        log_info "跳过 snapd 清理。"
        return
    }

    log_info "清理 snapd..."
    systemctl stop snapd.service snapd.socket snapd.seeded.service 2>/dev/null || true
    systemctl disable snapd.service snapd.socket snapd.seeded.service 2>/dev/null || true

    if dpkg -l | grep -q "^ii  snapd "; then
        apt-get purge -y snapd
    fi

    rm -rf /snap /var/snap /var/lib/snapd /var/cache/snapd /root/snap
    find /home -maxdepth 2 -type d -name snap -exec rm -rf {} + 2>/dev/null || true
}

# ===== Swap =====
setup_swap() {
    if [[ "${SWAP_SIZE}" == "0" ]]; then
        log_info "用户选择不创建 Swap。"
        return
    fi

    log_info "检查 Swap 状态..."
    if swapon --show | grep -q '^'; then
        log_warn "系统已存在启用中的 Swap，当前信息如下："
        swapon --show || true
        log_warn "将跳过 /swapfile 创建。如需重建请手动关闭并删除现有 swap。"
        return
    fi

    if [[ -f /swapfile ]]; then
        log_warn "/swapfile 已存在但未启用，跳过自动重建。请手动检查后再执行。"
        return
    fi

    log_info "创建 ${SWAP_SIZE}GB /swapfile..."
    fallocate -l "${SWAP_SIZE}G" /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=$((SWAP_SIZE * 1024)) status=progress
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile

    grep -qxF '/swapfile none swap sw 0 0' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab

    cat > /etc/sysctl.d/99-custom-swap.conf <<'EOF'
vm.swappiness=10
vm.vfs_cache_pressure=50
EOF

    sysctl --system >/dev/null
    log_info "Swap 配置完成。"
}

# ===== BBR =====
setup_bbr() {
    [[ "${ENABLE_BBR}" == "yes" ]] || {
        log_info "跳过 BBR 配置。"
        return
    }

    log_info "配置 BBR..."
    cat > /etc/sysctl.d/99-bbr.conf <<'EOF'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF

    sysctl --system >/dev/null || true

    if sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q "bbr"; then
        log_info "BBR 已启用。"
    else
        log_warn "BBR 启用失败，请检查内核支持情况。"
    fi
}

# ===== 用户与 SSH Key =====
setup_user_and_ssh_key() {
    log_info "配置用户 ${TARGET_USER}..."

    if ! id -u "${TARGET_USER}" >/dev/null 2>&1; then
        adduser --disabled-password --gecos "" "${TARGET_USER}"
    fi

    echo "${TARGET_USER} ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/90-${TARGET_USER}"
    chmod 0440 "/etc/sudoers.d/90-${TARGET_USER}"

    local user_home
    user_home="$(getent passwd "${TARGET_USER}" | cut -d: -f6)"
    [[ -n "${user_home}" ]] || log_err "无法获取用户 ${TARGET_USER} 的家目录。"

    mkdir -p "${user_home}/.ssh"
    touch "${user_home}/.ssh/authorized_keys"

    grep -qxF "${SSH_KEY}" "${user_home}/.ssh/authorized_keys" || echo "${SSH_KEY}" >> "${user_home}/.ssh/authorized_keys"

    chmod 700 "${user_home}/.ssh"
    chmod 600 "${user_home}/.ssh/authorized_keys"
    chown -R "${TARGET_USER}:${TARGET_USER}" "${user_home}/.ssh"
}

# ===== Docker =====
install_docker_official() {
    [[ "${INSTALL_DOCKER}" == "yes" ]] || {
        log_info "跳过 Docker 安装。"
        return
    }

    log_info "安装 Docker 官方 APT 仓库..."

    install -m 0755 -d /etc/apt/keyrings

    if [[ ! -f /etc/apt/keyrings/docker.asc ]]; then
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
        chmod a+r /etc/apt/keyrings/docker.asc
    fi

    local arch codename
    arch="$(dpkg --print-architecture)"
    codename="$(. /etc/os-release && echo "${VERSION_CODENAME}")"

    cat > /etc/apt/sources.list.d/docker.list <<EOF
deb [arch=${arch} signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${codename} stable
EOF

    apt-get update -y

    if ! command -v docker >/dev/null 2>&1; then
        apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    else
        log_info "Docker 已安装，跳过软件包安装。"
    fi

    getent group docker >/dev/null 2>&1 || groupadd docker
    usermod -aG docker "${TARGET_USER}" || true

    systemctl enable docker 2>/dev/null || true
    systemctl enable containerd 2>/dev/null || true
    systemctl restart containerd 2>/dev/null || true
    systemctl restart docker 2>/dev/null || true

    log_info "Docker 配置完成。"
}

# ===== SSH 与 Fail2ban =====
harden_ssh_and_fail2ban() {
    log_info "配置 Fail2ban..."
    cat > /etc/fail2ban/jail.d/sshd-custom.conf <<EOF
[sshd]
enabled = true
port = ${SSH_PORT}
filter = sshd
backend = systemd
banaction = iptables-multiport
maxretry = 3
findtime = 3600
bantime = 86400
EOF

    systemctl enable fail2ban >/dev/null 2>&1 || true
    systemctl restart fail2ban

    log_info "配置 SSH..."
    systemctl disable --now ssh.socket 2>/dev/null || true
    systemctl enable --now ssh.service 2>/dev/null || true

    cp -a /etc/ssh/sshd_config "/etc/ssh/sshd_config.bak.$(date +%F-%H%M%S)"

    if ! grep -Eq '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf' /etc/ssh/sshd_config; then
        log_warn "未发现 sshd_config Include 指令，自动补全。"
        sed -i '1i Include /etc/ssh/sshd_config.d/*.conf\n' /etc/ssh/sshd_config
    fi

    mkdir -p /etc/ssh/sshd_config.d
    cat > /etc/ssh/sshd_config.d/99-custom-security.conf <<EOF
Port ${SSH_PORT}
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
UsePAM yes
AuthorizedKeysFile .ssh/authorized_keys
AllowUsers ${TARGET_USER}
X11Forwarding no
EOF

    log_info "校验 SSH 配置..."
    sshd -t || log_err "SSH 配置语法错误，请检查 /etc/ssh/sshd_config.d/99-custom-security.conf"

    systemctl restart ssh
    log_info "SSH 配置已应用。"
}

# ===== 清理 =====
final_cleanup() {
    log_info "执行系统清理..."
    apt-get autoremove -y --purge
    apt-get clean
    rm -rf /var/lib/apt/lists/*
}

# ===== 结果输出 =====
print_result() {
    local public_ip=""
    public_ip="$(curl -4 -fsS --max-time 5 ifconfig.me 2>/dev/null || true)"

    echo
    echo -e "\033[36m=================================================\033[0m"
    echo -e "\033[32m🎉 VPS 初始化全部完成！\033[0m"
    echo -e "-------------------------------------------------"
    echo -e "👉 请确保 GCP / 云服务商防火墙已放行 TCP ${SSH_PORT}"
    if [[ -n "${public_ip}" ]]; then
        echo -e "👉 新登录命令: \033[36mssh -p ${SSH_PORT} ${TARGET_USER}@${public_ip}\033[0m"
    else
        echo -e "👉 新登录命令: \033[36mssh -p ${SSH_PORT} ${TARGET_USER}@你的IP\033[0m"
    fi
    echo -e "👉 切换 Root: \033[36msudo -i\033[0m"
    echo -e "👉 请先新开一个终端测试 SSH 成功，再关闭当前会话"
    echo -e "\033[36m=================================================\033[0m"
}

# ===== 主流程 =====
main() {
    check_root
    check_os
    collect_params
    validate_params
    show_summary

    cleanup_snapd
    install_base_tools
    set_timezone
    setup_swap
    setup_bbr
    setup_user_and_ssh_key
    install_docker_official
    harden_ssh_and_fail2ban
    final_cleanup
    print_result
}

main "$@"