#!/usr/bin/env bash
# --------------------------------------------------------
# 生产级 VPS 自动化初始化脚本
# 支持: Ubuntu 22.04 / 24.04
#
# 特性:
# - 幂等执行
# - 严格校验
# - SSH 加固
# - Docker 官方源安装
# - Swap / BBR
# - Fail2ban
# - 清理 snapd
# - Telegram 配置拉取
# - 资源监控 + TG 告警
# - 菜单式增量执行
#
# 使用方式:
# 交互式:
#   sudo bash init.sh
#
# 非交互式:
#   RUN_MODE=monitor sudo bash init.sh
#
# RUN_MODE 可选:
#   full / tg / monitor / ssh / docker
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

RUN_MODE="${RUN_MODE:-}"                  # full / tg / monitor / ssh / docker

# 资源监控参数
CPU_ALERT_THRESHOLD="${CPU_ALERT_THRESHOLD:-50}"
MEM_ALERT_THRESHOLD="${MEM_ALERT_THRESHOLD:-80}"
ALERT_WINDOW_MINUTES="${ALERT_WINDOW_MINUTES:-30}"
ALERT_CHECK_INTERVAL_MINUTES="${ALERT_CHECK_INTERVAL_MINUTES:-5}"

# ===== 输出函数 =====
log_info() { echo -e "\033[32m[INFO]\033[0m $*"; }
log_warn() { echo -e "\033[33m[WARN]\033[0m $*"; }
log_err()  { echo -e "\033[31m[ERROR]\033[0m $*"; exit 1; }

# ===== 基础检查 =====
check_root() {
  [[ "${EUID}" -eq 0 ]] || log_err "请使用 root 权限运行: sudo bash init.sh"
}

check_os() {
  [[ -f /etc/os-release ]] || log_err "无法识别系统。"
  # shellcheck disable=SC1091
  . /etc/os-release
  [[ "${ID:-}" == "ubuntu" ]] || log_err "仅支持 Ubuntu，当前系统: ${ID:-unknown}"
  case "${VERSION_ID:-}" in
    22.04|24.04) ;;
    *) log_warn "当前 Ubuntu 版本为 ${VERSION_ID:-unknown}，脚本主要针对 22.04 / 24.04 验证。" ;;
  esac
}

# ===== 参数收集 =====
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

select_run_mode() {
  if [[ -n "${RUN_MODE}" ]]; then
    return
  fi

  echo
  echo "==============================="
  echo "  VPS 初始化 / 增量配置菜单"
  echo "==============================="
  echo "1) 全部初始化"
  echo "2) 更新 Telegram 配置"
  echo "3) 更新资源监控"
  echo "4) 更新 SSH 配置"
  echo "5) 更新 Docker"
  echo "0) 退出"
  echo "==============================="
  read -r -p "请输入选项编号 [0-5]: " menu_choice

  case "${menu_choice}" in
    1) RUN_MODE="full" ;;
    2) RUN_MODE="tg" ;;
    3) RUN_MODE="monitor" ;;
    4) RUN_MODE="ssh" ;;
    5) RUN_MODE="docker" ;;
    0)
      echo "已退出。"
      exit 0
      ;;
    *)
      log_err "无效选项: ${menu_choice}"
      ;;
  esac
}

collect_params() {
  echo -e "\033[36m=================================================\033[0m"
  echo -e "\033[36m VPS 初始化向导 (Ubuntu 专用) \033[0m"
  echo -e "\033[36m=================================================\033[0m"

  case "${RUN_MODE}" in
    full)
      prompt_if_empty SSH_PORT " 1. 请输入 SSH 端口" "24153"
      prompt_if_empty SWAP_SIZE " 2. 请输入 Swap 大小(GB)，填 0 不创建" "2"
      prompt_if_empty TIMEZONE " 3. 请输入系统时区" "Asia/Shanghai"

      if [[ -z "${SSH_KEY}" ]]; then
        echo " 4. 请粘贴登录 [${TARGET_USER}] 账号的 SSH 公钥:"
        read -r SSH_KEY
      fi
      ;;
    tg)
      log_info "当前模式：更新 Telegram 配置"
      ;;
    monitor)
      log_info "当前模式：更新资源监控"
      ;;
    ssh)
      prompt_if_empty SSH_PORT " 1. 请输入 SSH 端口" "24153"
      if [[ -z "${SSH_KEY}" ]]; then
        echo " 2. 请粘贴登录 [${TARGET_USER}] 账号的 SSH 公钥:"
        read -r SSH_KEY
      fi
      ;;
    docker)
      log_info "当前模式：更新 Docker"
      ;;
    *)
      log_err "不支持的 RUN_MODE: ${RUN_MODE}"
      ;;
  esac
}

validate_params() {
  [[ "${RUN_MODE}" =~ ^(full|tg|monitor|ssh|docker)$ ]] || log_err "RUN_MODE 无效: ${RUN_MODE}"

  case "${RUN_MODE}" in
    full)
      [[ "${SSH_PORT}" =~ ^[0-9]+$ ]] || log_err "SSH_PORT 必须是数字。"
      (( SSH_PORT >= 1 && SSH_PORT <= 65535 )) || log_err "SSH_PORT 必须在 1-65535 之间。"

      [[ "${SWAP_SIZE}" =~ ^[0-9]+$ ]] || log_err "SWAP_SIZE 必须是非负整数。"
      timedatectl list-timezones | grep -qx "${TIMEZONE}" || log_err "TIMEZONE 无效: ${TIMEZONE}"

      echo "${SSH_KEY}" | grep -Eq '^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521|sk-ssh-ed25519@openssh\.com|sk-ecdsa-sha2-nistp256@openssh\.com) ' \
        || log_err "SSH_KEY 格式无效。"
      ;;
    ssh)
      [[ "${SSH_PORT}" =~ ^[0-9]+$ ]] || log_err "SSH_PORT 必须是数字。"
      (( SSH_PORT >= 1 && SSH_PORT <= 65535 )) || log_err "SSH_PORT 必须在 1-65535 之间。"

      echo "${SSH_KEY}" | grep -Eq '^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521|sk-ssh-ed25519@openssh\.com|sk-ecdsa-sha2-nistp256@openssh\.com) ' \
        || log_err "SSH_KEY 格式无效。"
      ;;
    tg|monitor|docker)
      :
      ;;
  esac

  [[ "${SYSTEM_UPGRADE}" =~ ^(yes|no)$ ]] || log_err "SYSTEM_UPGRADE 只能是 yes 或 no"
  [[ "${INSTALL_DOCKER}" =~ ^(yes|no)$ ]] || log_err "INSTALL_DOCKER 只能是 yes 或 no"
  [[ "${ENABLE_BBR}" =~ ^(yes|no)$ ]] || log_err "ENABLE_BBR 只能是 yes 或 no"
  [[ "${REMOVE_SNAPD}" =~ ^(yes|no)$ ]] || log_err "REMOVE_SNAPD 只能是 yes 或 no"

  [[ "${CPU_ALERT_THRESHOLD}" =~ ^[0-9]+$ ]] || log_err "CPU_ALERT_THRESHOLD 必须是数字。"
  [[ "${MEM_ALERT_THRESHOLD}" =~ ^[0-9]+$ ]] || log_err "MEM_ALERT_THRESHOLD 必须是数字。"
  [[ "${ALERT_WINDOW_MINUTES}" =~ ^[0-9]+$ ]] || log_err "ALERT_WINDOW_MINUTES 必须是数字。"
  [[ "${ALERT_CHECK_INTERVAL_MINUTES}" =~ ^[0-9]+$ ]] || log_err "ALERT_CHECK_INTERVAL_MINUTES 必须是数字。"

  (( CPU_ALERT_THRESHOLD >= 1 && CPU_ALERT_THRESHOLD <= 100 )) || log_err "CPU_ALERT_THRESHOLD 必须在 1-100 之间。"
  (( MEM_ALERT_THRESHOLD >= 1 && MEM_ALERT_THRESHOLD <= 100 )) || log_err "MEM_ALERT_THRESHOLD 必须在 1-100 之间。"
  (( ALERT_WINDOW_MINUTES >= 5 )) || log_err "ALERT_WINDOW_MINUTES 不能小于 5。"
  (( ALERT_CHECK_INTERVAL_MINUTES >= 1 )) || log_err "ALERT_CHECK_INTERVAL_MINUTES 不能小于 1。"
}

show_summary() {
  echo
  echo "========== 参数确认 =========="
  echo "运行模式: ${RUN_MODE}"
  echo "用户: ${TARGET_USER}"

  case "${RUN_MODE}" in
    full)
      echo "SSH 端口: ${SSH_PORT}"
      echo "Swap(GB): ${SWAP_SIZE}"
      echo "时区: ${TIMEZONE}"
      echo "系统升级: ${SYSTEM_UPGRADE}"
      echo "安装 Docker: ${INSTALL_DOCKER}"
      echo "启用 BBR: ${ENABLE_BBR}"
      echo "移除 snapd: ${REMOVE_SNAPD}"
      echo "CPU 告警阈值: ${CPU_ALERT_THRESHOLD}%"
      echo "内存告警阈值: ${MEM_ALERT_THRESHOLD}%"
      echo "告警窗口: ${ALERT_WINDOW_MINUTES} 分钟"
      echo "检查间隔: ${ALERT_CHECK_INTERVAL_MINUTES} 分钟"
      ;;
    tg)
      echo "仅执行: 更新 Telegram 配置"
      ;;
    monitor)
      echo "仅执行: 更新资源监控"
      echo "CPU 告警阈值: ${CPU_ALERT_THRESHOLD}%"
      echo "内存告警阈值: ${MEM_ALERT_THRESHOLD}%"
      echo "告警窗口: ${ALERT_WINDOW_MINUTES} 分钟"
      echo "检查间隔: ${ALERT_CHECK_INTERVAL_MINUTES} 分钟"
      ;;
    ssh)
      echo "仅执行: 更新 SSH 配置"
      echo "SSH 端口: ${SSH_PORT}"
      ;;
    docker)
      echo "仅执行: 更新 Docker"
      ;;
  esac

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

  mount | awk '/\/snap\// {print $3}' | sort -r | xargs -r -n1 umount -l 2>/dev/null || true

  if command -v snap >/dev/null 2>&1; then
    local -a snap_pkgs=()
    mapfile -t snap_pkgs < <(snap list 2>/dev/null | awk 'NR>1 {print $1}' || true)
    if (( ${#snap_pkgs[@]} > 0 )); then
      local pkg
      for pkg in "${snap_pkgs[@]}"; do
        [[ -n "${pkg}" ]] || continue
        snap remove --purge "${pkg}" 2>/dev/null || snap remove "${pkg}" 2>/dev/null || true
      done
    fi
  fi

  apt-get purge -y snapd 2>/dev/null || true
  apt-get autoremove -y --purge 2>/dev/null || true

  mount | awk '/\/snap\// {print $3}' | sort -r | xargs -r -n1 umount -l 2>/dev/null || true
  rm -rf /snap /var/snap /var/lib/snapd /var/cache/snapd /root/snap 2>/dev/null || true
  find /home -maxdepth 2 -type d -name snap -exec rm -rf {} + 2>/dev/null || true

  if dpkg -l 2>/dev/null | grep -q '^ii\s\+snapd\s'; then
    log_warn "snapd 仍存在，请稍后手动检查。"
  else
    log_info "snapd 清理完成。"
  fi
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
  [[ "${INSTALL_DOCKER}" == "yes" || "${RUN_MODE}" == "docker" ]] || {
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
  # shellcheck disable=SC1091
  codename="$(
    . /etc/os-release
    echo "${VERSION_CODENAME}"
  )"

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
  id -u "${TARGET_USER}" >/dev/null 2>&1 && usermod -aG docker "${TARGET_USER}" || true

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
logpath = %(sshd_log)s
backend = systemd
maxretry = 5
findtime = 10m
bantime = 1h
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
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
UsePAM yes
PubkeyAuthentication yes
X11Forwarding no
MaxAuthTries 3
ClientAliveInterval 300
ClientAliveCountMax 2
EOF

  sshd -t || log_err "sshd 配置校验失败，请检查配置。"
  systemctl restart ssh
  log_info "SSH 与 Fail2ban 配置完成。"
}

# ===== Telegram 配置 =====
setup_tg_env() {
  if [[ -f /etc/tg.env ]]; then
    log_info "检测到 /etc/tg.env 已存在。"
    read -r -p "是否重新拉取 Telegram 配置？[y/N]: " rewrite_tg
    if [[ ! "${rewrite_tg}" =~ ^[Yy]$ ]]; then
      log_info "跳过 Telegram 配置更新。"
      return
    fi
  fi

  read -r -p "请输入 Telegram 配置地址(如 https://xxx?token=1，直接回车跳过): " tg_url
  if [[ -z "${tg_url}" ]]; then
    log_info "未提供 Telegram 配置地址，跳过。"
    return
  fi

  local tmp_file
  tmp_file="$(mktemp)"

  log_info "正在拉取 Telegram 配置..."
  if ! curl -fsSL "${tg_url}" -o "${tmp_file}"; then
    rm -f "${tmp_file}"
    log_warn "Telegram 配置拉取失败，已跳过。"
    return
  fi

  # 必须包含 TG_CHAT_ID
  grep -Eq '^TG_CHAT_ID=".*"$' "${tmp_file}" || {
    rm -f "${tmp_file}"
    log_warn "Telegram 配置缺少 TG_CHAT_ID，已跳过。"
    return
  }

  # 至少要有一个 TG_XXX
  grep -Eq '^TG_[A-Z0-9_]+=".*"$' "${tmp_file}" || {
    rm -f "${tmp_file}"
    log_warn "Telegram 配置格式无效，已跳过。"
    return
  }

  # 只允许 TG_XXX="..."
  if grep -Ev '^(TG_[A-Z0-9_]+)=".*"$' "${tmp_file}" >/dev/null 2>&1; then
    rm -f "${tmp_file}"
    log_warn "Telegram 配置包含不安全内容，已拒绝写入。"
    return
  fi

  mv "${tmp_file}" /etc/tg.env
  chmod 644 /etc/tg.env
  log_info "Telegram 配置已写入 /etc/tg.env"
}

# ===== 资源监控 + TG 告警 =====
setup_resource_monitor_tg() {
  if [[ ! -f /etc/tg.env ]]; then
    log_warn "未检测到 /etc/tg.env，跳过 TG 资源告警配置。"
    return
  fi

  # shellcheck disable=SC1091
  source /etc/tg.env

  local tg_bot_token="${TG_VLESS:-}"
  local tg_chat_id="${TG_CHAT_ID:-}"

  if [[ -z "${tg_bot_token}" || -z "${tg_chat_id}" ]]; then
    log_warn "检测到 /etc/tg.env，但缺少 TG_VLESS 或 TG_CHAT_ID，跳过资源告警配置。"
    return
  fi

  log_info "配置 TG 资源告警监控..."

  install -d -m 0755 /usr/local/bin
  install -d -m 0755 /var/lib/resource-monitor
  install -d -m 0755 /etc/resource-monitor

  cat > /etc/resource-monitor/resource-monitor.conf <<EOF
CPU_ALERT_THRESHOLD="${CPU_ALERT_THRESHOLD}"
MEM_ALERT_THRESHOLD="${MEM_ALERT_THRESHOLD}"
ALERT_WINDOW_MINUTES="${ALERT_WINDOW_MINUTES}"
ALERT_CHECK_INTERVAL_MINUTES="${ALERT_CHECK_INTERVAL_MINUTES}"
EOF

  chmod 644 /etc/resource-monitor/resource-monitor.conf

  cat > /usr/local/bin/resource-monitor-tg.sh <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

STATE_DIR="/var/lib/resource-monitor"
CPU_HISTORY_FILE="${STATE_DIR}/cpu_history"
MEM_HISTORY_FILE="${STATE_DIR}/mem_history"
ALERT_STATE_FILE="${STATE_DIR}/alert_state"
CONFIG_FILE="/etc/resource-monitor/resource-monitor.conf"

mkdir -p "${STATE_DIR}"

[[ -f /etc/tg.env ]] || exit 0
[[ -f "${CONFIG_FILE}" ]] || exit 0

# shellcheck disable=SC1091
source /etc/tg.env
# shellcheck disable=SC1091
source "${CONFIG_FILE}"

TG_BOT_TOKEN="${TG_VLESS:-}"
TG_CHAT_ID="${TG_CHAT_ID:-}"

[[ -n "${TG_BOT_TOKEN}" && -n "${TG_CHAT_ID}" ]] || exit 0

HOSTNAME_F="$(hostname -f 2>/dev/null || hostname)"
PUBLIC_IP="$(curl -4 -fsS --max-time 8 https://api.ipify.org 2>/dev/null || echo "unknown")"

send_tg() {
  local text="$1"
  curl -fsS --max-time 15 \
    -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
    -d "chat_id=${TG_CHAT_ID}" \
    --data-urlencode "text=${text}" \
    -d "parse_mode=HTML" >/dev/null || true
}

get_cpu_usage_percent() {
  local idle1 total1 idle2 total2
  local user nice system idle iowait irq softirq steal guest guest_nice

  read -r _ user nice system idle iowait irq softirq steal guest guest_nice < /proc/stat
  idle1=$((idle + iowait))
  total1=$((user + nice + system + idle + iowait + irq + softirq + steal))

  sleep 1

  read -r _ user nice system idle iowait irq softirq steal guest guest_nice < /proc/stat
  idle2=$((idle + iowait))
  total2=$((user + nice + system + idle + iowait + irq + softirq + steal))

  if (( total2 <= total1 )); then
    echo 0
    return
  fi

  awk -v t1="${total1}" -v t2="${total2}" -v i1="${idle1}" -v i2="${idle2}" \
    'BEGIN { printf "%.0f", (1 - (i2-i1)/(t2-t1)) * 100 }'
}

get_mem_usage_percent() {
  local total avail
  total="$(awk '/MemTotal:/ {print $2}' /proc/meminfo)"
  avail="$(awk '/MemAvailable:/ {print $2}' /proc/meminfo)"

  if [[ -z "${total}" || -z "${avail}" || "${total}" -eq 0 ]]; then
    echo 0
    return
  fi

  awk -v total="${total}" -v avail="${avail}" 'BEGIN { printf "%.0f", ((total-avail)/total)*100 }'
}

trim_history() {
  local file="$1"
  local keep_lines="$2"
  touch "${file}"
  tail -n "${keep_lines}" "${file}" > "${file}.tmp" 2>/dev/null || true
  mv "${file}.tmp" "${file}"
}

all_lines_ge_threshold() {
  local file="$1"
  local threshold="$2"
  local required="$3"

  [[ -f "${file}" ]] || return 1

  local count
  count="$(wc -l < "${file}")"
  (( count >= required )) || return 1

  tail -n "${required}" "${file}" | awk -v th="${threshold}" '
    { if ($1 + 0 < th) exit 1 }
    END { exit 0 }
  '
}

get_state() {
  local key="$1"
  [[ -f "${ALERT_STATE_FILE}" ]] || { echo 0; return; }
  awk -F= -v k="${key}" '$1==k {print $2}' "${ALERT_STATE_FILE}" | tail -n1
}

set_state() {
  local key="$1"
  local value="$2"
  touch "${ALERT_STATE_FILE}"

  if grep -q "^${key}=" "${ALERT_STATE_FILE}" 2>/dev/null; then
    sed -i "s/^${key}=.*/${key}=${value}/" "${ALERT_STATE_FILE}"
  else
    echo "${key}=${value}" >> "${ALERT_STATE_FILE}"
  fi
}

CPU_USAGE="$(get_cpu_usage_percent)"
MEM_USAGE="$(get_mem_usage_percent)"

REQUIRED_SAMPLES=$((ALERT_WINDOW_MINUTES / ALERT_CHECK_INTERVAL_MINUTES))
(( REQUIRED_SAMPLES < 1 )) && REQUIRED_SAMPLES=1

echo "${CPU_USAGE}" >> "${CPU_HISTORY_FILE}"
echo "${MEM_USAGE}" >> "${MEM_HISTORY_FILE}"

trim_history "${CPU_HISTORY_FILE}" "${REQUIRED_SAMPLES}"
trim_history "${MEM_HISTORY_FILE}" "${REQUIRED_SAMPLES}"

CPU_ALERTED="$(get_state cpu_alerted)"
MEM_ALERTED="$(get_state mem_alerted)"

CPU_HIGH=0
MEM_HIGH=0

all_lines_ge_threshold "${CPU_HISTORY_FILE}" "${CPU_ALERT_THRESHOLD}" "${REQUIRED_SAMPLES}" && CPU_HIGH=1
all_lines_ge_threshold "${MEM_HISTORY_FILE}" "${MEM_ALERT_THRESHOLD}" "${REQUIRED_SAMPLES}" && MEM_HIGH=1

NOW_TIME="$(date '+%F %T %Z')"

if (( CPU_HIGH == 1 )) && (( CPU_ALERTED == 0 )); then
  send_tg "🚨 <b>VPS CPU 告警</b>
主机: <code>${HOSTNAME_F}</code>
IP: <code>${PUBLIC_IP}</code>
时间: <code>${NOW_TIME}</code>
条件: CPU 连续 ${ALERT_WINDOW_MINUTES} 分钟 ≥ ${CPU_ALERT_THRESHOLD}%
当前: <code>${CPU_USAGE}%</code>"
  set_state cpu_alerted 1
fi

if (( MEM_HIGH == 1 )) && (( MEM_ALERTED == 0 )); then
  send_tg "🚨 <b>VPS 内存告警</b>
主机: <code>${HOSTNAME_F}</code>
IP: <code>${PUBLIC_IP}</code>
时间: <code>${NOW_TIME}</code>
条件: 内存连续 ${ALERT_WINDOW_MINUTES} 分钟 ≥ ${MEM_ALERT_THRESHOLD}%
当前: <code>${MEM_USAGE}%</code>"
  set_state mem_alerted 1
fi

if (( CPU_HIGH == 0 )) && (( CPU_ALERTED == 1 )); then
  send_tg "✅ <b>VPS CPU 恢复</b>
主机: <code>${HOSTNAME_F}</code>
IP: <code>${PUBLIC_IP}</code>
时间: <code>${NOW_TIME}</code>
当前: <code>${CPU_USAGE}%</code>"
  set_state cpu_alerted 0
fi

if (( MEM_HIGH == 0 )) && (( MEM_ALERTED == 1 )); then
  send_tg "✅ <b>VPS 内存恢复</b>
主机: <code>${HOSTNAME_F}</code>
IP: <code>${PUBLIC_IP}</code>
时间: <code>${NOW_TIME}</code>
当前: <code>${MEM_USAGE}%</code>"
  set_state mem_alerted 0
fi
EOF

  chmod +x /usr/local/bin/resource-monitor-tg.sh

  cat > /etc/systemd/system/resource-monitor-tg.service <<'EOF'
[Unit]
Description=Resource Monitor Telegram Alert

[Service]
Type=oneshot
ExecStart=/usr/local/bin/resource-monitor-tg.sh
User=root
EOF

  cat > /etc/systemd/system/resource-monitor-tg.timer <<EOF
[Unit]
Description=Run Resource Monitor Telegram Alert every ${ALERT_CHECK_INTERVAL_MINUTES} minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=${ALERT_CHECK_INTERVAL_MINUTES}min
Unit=resource-monitor-tg.service
Persistent=true

[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload
  systemctl enable --now resource-monitor-tg.timer

  log_info "TG 资源告警已配置完成。"
  log_info "规则: CPU 连续 ${ALERT_WINDOW_MINUTES} 分钟 >= ${CPU_ALERT_THRESHOLD}%，内存连续 ${ALERT_WINDOW_MINUTES} 分钟 >= ${MEM_ALERT_THRESHOLD}%"
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
  echo -e "\033[32m VPS 操作完成！\033[0m"
  echo -e "-------------------------------------------------"

  case "${RUN_MODE}" in
    full|ssh)
      echo -e " 请确保 GCP / 云服务商防火墙已放行 TCP ${SSH_PORT}"
      if [[ -n "${public_ip}" ]]; then
        echo -e " 新登录命令: \033[36mssh -p ${SSH_PORT} ${TARGET_USER}@${public_ip}\033[0m"
      else
        echo -e " 新登录命令: \033[36mssh -p ${SSH_PORT} ${TARGET_USER}@你的IP\033[0m"
      fi
      echo -e " 切换 Root: \033[36msudo -i\033[0m"
      echo -e " 请先新开一个终端测试 SSH 成功，再关闭当前会话"
      ;;
    tg)
      echo -e " Telegram 配置已处理，文件位置: \033[36m/etc/tg.env\033[0m"
      ;;
    monitor)
      echo -e " 资源监控已处理。"
      echo -e " 查看定时器: \033[36msystemctl status resource-monitor-tg.timer\033[0m"
      echo -e " 手动测试: \033[36msystemctl start resource-monitor-tg.service\033[0m"
      ;;
    docker)
      echo -e " Docker 模块已处理。"
      echo -e " 查看版本: \033[36mdocker --version\033[0m"
      ;;
  esac

  echo -e "\033[36m=================================================\033[0m"
}

# ===== 主流程 =====
main() {
  check_root
  check_os
  select_run_mode
  collect_params
  validate_params
  show_summary

  case "${RUN_MODE}" in
    full)
      install_base_tools
      cleanup_snapd
      set_timezone
      setup_swap
      setup_bbr
      setup_user_and_ssh_key
      setup_tg_env
      install_docker_official
      harden_ssh_and_fail2ban
      setup_resource_monitor_tg
      final_cleanup
      print_result
      ;;
    tg)
      install_base_tools
      setup_tg_env
      print_result
      ;;
    monitor)
      install_base_tools
      setup_resource_monitor_tg
      print_result
      ;;
    ssh)
      install_base_tools
      setup_user_and_ssh_key
      harden_ssh_and_fail2ban
      print_result
      ;;
    docker)
      install_base_tools
      install_docker_official
      print_result
      ;;
    *)
      log_err "不支持的 RUN_MODE: ${RUN_MODE}"
      ;;
  esac
}

main "$@"