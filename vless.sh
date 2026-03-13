#!/bin/bash
set -euo pipefail

# ==============================================================================
# 1. Telegram 配置
# ==============================================================================
TG_ENV_FILE="/etc/tg.env"
TG_KEY="${TG_KEY:-TG_VLESS}"                 # 可改成 TG_QL / TG_OTHER
TG_FETCH_URL_DEFAULT="${TG_FETCH_URL_DEFAULT:-}"

# ==============================================================================
# 2. 基础变量
# ==============================================================================
if [ "$EUID" -ne 0 ]; then
  echo "❌ 请使用 root 权限运行此脚本 (例如: sudo bash updater.sh)"
  exit 1
fi

APP_DIR="/opt/singbox-reality"
DATA_FILE="$APP_DIR/.node_data"
LAST_IP_FILE="$APP_DIR/.last_ip"
TARGET_SCRIPT="$APP_DIR/updater.sh"
CONFIG_FILE="$APP_DIR/config.json"
COMPOSE_FILE="$APP_DIR/docker-compose.yml"
CONFIG_SHA_FILE="$APP_DIR/.config.sha256"

SNI="www.ubuntu.com"
PORT=2053
CONTAINER_NAME="singbox-reality"

mkdir -p "$APP_DIR"

# 自动复制脚本到固定位置，避免源文件被删后自启失效
CURRENT_SCRIPT="$(readlink -f "$0")"
if [ "$CURRENT_SCRIPT" != "$TARGET_SCRIPT" ]; then
  cp "$CURRENT_SCRIPT" "$TARGET_SCRIPT"
  chmod +x "$TARGET_SCRIPT"
fi

echo "🔄 正在检查基础依赖..."
apt-get update -y > /dev/null 2>&1
apt-get install -y curl openssl ca-certificates > /dev/null 2>&1

# ==============================================================================
# 3. Telegram 环境加载
# ==============================================================================
TG_CHAT_ID=""
TG_BOT_TOKEN=""

load_tg_env() {
  if [ -f "$TG_ENV_FILE" ]; then
    # shellcheck disable=SC1090
    source "$TG_ENV_FILE"
  fi
}

validate_tg_env_file() {
  local file="$1"

  # 至少有一条 TG_XXX 和 TG_CHAT_ID
  grep -Eq '^TG_CHAT_ID=".*"$' "$file" || return 1
  grep -Eq '^TG_[A-Z0-9_]+=".*"$' "$file" || return 1

  # 只允许 TG_ 开头的安全键值行
  if grep -Ev '^(TG_[A-Z0-9_]+)=".*"$' "$file" >/dev/null 2>&1; then
    return 1
  fi

  return 0
}

fetch_tg_env_if_needed() {
  load_tg_env

  local tg_var_name="$TG_KEY"
  local current_token="${!tg_var_name:-}"

  if [[ -n "${TG_CHAT_ID:-}" && -n "${current_token:-}" ]]; then
    return 0
  fi

  echo "⚠️ 未检测到可用的 Telegram 配置。"
  echo "   当前需要变量: ${TG_KEY}"
  echo "   将尝试获取并保存到: ${TG_ENV_FILE}"

  local fetch_url="${TG_FETCH_URL_DEFAULT}"

  if [[ -z "$fetch_url" ]]; then
    read -r -p "请输入 Telegram 配置地址（如 https://xxx.workers.dev/?token=你的密码，直接回车跳过）: " fetch_url
  else
    echo "📥 正在使用预设地址拉取 Telegram 配置..."
  fi

  if [[ -z "$fetch_url" ]]; then
    echo "⚠️ 未提供 Telegram 配置地址，跳过 Telegram 通知功能。"
    return 0
  fi

  local tmp_file
  tmp_file="$(mktemp)"

  if curl -fsSL "$fetch_url" -o "$tmp_file"; then
    if validate_tg_env_file "$tmp_file"; then
      mv "$tmp_file" "$TG_ENV_FILE"
      chmod 644 "$TG_ENV_FILE"
      echo "✅ Telegram 配置已保存到 ${TG_ENV_FILE}"
      load_tg_env
    else
      rm -f "$tmp_file"
      echo "❌ 获取到的 Telegram 配置格式不合法，已拒绝写入。"
      return 1
    fi
  else
    rm -f "$tmp_file"
    echo "❌ 拉取 Telegram 配置失败。"
    return 1
  fi
}

fetch_tg_env_if_needed

TG_BOT_TOKEN="${!TG_KEY:-}"

if [[ -n "${TG_CHAT_ID:-}" && -n "${TG_BOT_TOKEN:-}" ]]; then
  echo "✅ Telegram 配置已加载，当前使用键: ${TG_KEY}"
else
  echo "⚠️ Telegram 配置未完整加载，将跳过 Telegram 通知。"
fi

# ==============================================================================
# 4. 检查 Docker / Compose
# ==============================================================================
if ! command -v docker >/dev/null 2>&1; then
  echo "🐳 未检测到 Docker，正在自动安装..."
  curl -fsSL https://get.docker.com | bash -s docker
fi

sleep 2

if ! docker compose version >/dev/null 2>&1; then
  echo "❌ 未检测到 docker compose 插件，请检查 Docker 安装是否完整。"
  exit 1
fi

# ==============================================================================
# 5. 读取或生成核心参数（只在首次生成一次）
# ==============================================================================
if [ -f "$DATA_FILE" ]; then
  echo -e "\n📦 检测到已有配置，读取固化参数..."
  # shellcheck disable=SC1090
  source "$DATA_FILE"
else
  echo -e "\n🔑 首次运行，生成并固化节点参数..."

  read -r -p "📝 请输入节点名称 (直接回车默认: MyVPS): " NODE_NAME
  NODE_NAME="${NODE_NAME:-MyVPS}"
  NODE_NAME_URL="$(printf '%s' "$NODE_NAME" | sed 's/ /%20/g')"

  UUID="$(cat /proc/sys/kernel/random/uuid)"
  SHORTID="$(openssl rand -hex 8)"

  echo "⏳ 正在生成 Reality 密钥对..."
  KEYPAIR="$(docker run --rm ghcr.io/sagernet/sing-box:latest generate reality-keypair)"
  PRIVATE_KEY="$(echo "$KEYPAIR" | awk '/PrivateKey/ {print $2}')"
  PUBLIC_KEY="$(echo "$KEYPAIR" | awk '/PublicKey/ {print $2}')"

  cat > "$DATA_FILE" <<EOF
NODE_NAME_URL="${NODE_NAME_URL}"
UUID="${UUID}"
SHORTID="${SHORTID}"
PRIVATE_KEY="${PRIVATE_KEY}"
PUBLIC_KEY="${PUBLIC_KEY}"
EOF

  chmod 644 "$DATA_FILE"
  echo "✅ 参数固化完成！"
fi

: "${NODE_NAME_URL:?DATA_FILE 缺少 NODE_NAME_URL}"
: "${UUID:?DATA_FILE 缺少 UUID}"
: "${SHORTID:?DATA_FILE 缺少 SHORTID}"
: "${PRIVATE_KEY:?DATA_FILE 缺少 PRIVATE_KEY}"
: "${PUBLIC_KEY:?DATA_FILE 缺少 PUBLIC_KEY}"

# ==============================================================================
# 6. 写入配置文件
# ==============================================================================
cd "$APP_DIR"

cat > "$CONFIG_FILE" <<EOF
{
  "log": {
    "level": "warn",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-in",
      "listen": "::",
      "listen_port": ${PORT},
      "users": [
        {
          "uuid": "${UUID}",
          "flow": "xtls-rprx-vision"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "${SNI}",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "${SNI}",
            "server_port": 443
          },
          "private_key": "${PRIVATE_KEY}",
          "short_id": ["${SHORTID}"]
        }
      }
    }
  ],
  "outbounds": [
    { "type": "direct" },
    { "type": "block" }
  ]
}
EOF

cat > "$COMPOSE_FILE" <<EOF
services:
  sing-box:
    image: ghcr.io/sagernet/sing-box:latest
    container_name: ${CONTAINER_NAME}
    restart: always
    network_mode: "host"
    volumes:
      - ./config.json:/etc/sing-box/config.json:ro
    command: run -c /etc/sing-box/config.json
EOF

# ==============================================================================
# 7. 配置变更检测：变了就强制重建，没变就只确保运行
# ==============================================================================
NEW_SHA="$(sha256sum "$CONFIG_FILE" "$COMPOSE_FILE" | sha256sum | awk '{print $1}')"
OLD_SHA="$(cat "$CONFIG_SHA_FILE" 2>/dev/null || true)"

if [ "$NEW_SHA" != "$OLD_SHA" ]; then
  echo "♻️ 检测到配置变化，强制重建容器..."
  docker compose down > /dev/null 2>&1 || true
  docker compose up -d --force-recreate > /dev/null 2>&1
  echo "$NEW_SHA" > "$CONFIG_SHA_FILE"
else
  echo "✅ 配置无变化，确保容器处于运行状态..."
  docker compose up -d > /dev/null 2>&1
fi

sleep 2
if ! docker ps --format '{{.Names}}' | grep -qx "${CONTAINER_NAME}"; then
  echo "❌ 容器未正常运行，请检查日志：docker logs ${CONTAINER_NAME}"
  exit 1
fi

# ==============================================================================
# 8. 获取公网 IP
# ==============================================================================
echo -e "\n🌐 正在获取最新公网 IP..."
IP="$(curl -4 -s --max-time 8 https://api.ipify.org || true)"

if [ -z "$IP" ]; then
  echo "❌ 无法获取公网 IP，脚本终止。"
  exit 1
fi

VLESS_LINK="vless://${UUID}@${IP}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=chrome&pbk=${PUBLIC_KEY}&type=tcp&sid=${SHORTID}#${NODE_NAME_URL}"

LAST_IP="$(cat "$LAST_IP_FILE" 2>/dev/null || true)"
SEND_NOTIFY=false

if [ "$IP" = "$LAST_IP" ]; then
  echo "✅ 当前 IP ($IP) 未变化，跳过通知。"
else
  echo "⚠️ 检测到 IP 变化: 旧 IP [${LAST_IP:-无}] -> 新 IP [$IP]"
  echo "$IP" > "$LAST_IP_FILE"
  SEND_NOTIFY=true
fi

# ==============================================================================
# 9. 配置开机自启
# ==============================================================================
SERVICE_FILE="/etc/systemd/system/singbox-ip-updater.service"

if [ ! -f "$SERVICE_FILE" ]; then
  echo "⚙️ 正在注册 systemd 开机自启服务..."
  cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Singbox Reality IP Updater & Notifier
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/bin/bash $TARGET_SCRIPT
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable singbox-ip-updater.service > /dev/null 2>&1
  echo "✅ 开机自启服务安装完成！"
fi

# ==============================================================================
# 10. 发送 Telegram 通知（只在 IP 变化时）
# ==============================================================================
if [ "$SEND_NOTIFY" = true ]; then
  echo -e "\n====================================================================="
  echo -e "🎯 你的 VLESS 节点[${NODE_NAME_URL}]链接："
  echo -e "\033[32m${VLESS_LINK}\033[0m"
  echo -e "=====================================================================\n"

  if [[ -n "${TG_BOT_TOKEN:-}" && -n "${TG_CHAT_ID:-}" ]]; then
    echo "📡 正在发送 Telegram 通知..."

    MSG_TEXT="你的 VLESS 节点[${NODE_NAME_URL}] IP 已更新

最新 IP: ${IP}

节点链接:
${VLESS_LINK}"

    TG_RESPONSE="$(
      curl -s -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
        --data-urlencode "chat_id=${TG_CHAT_ID}" \
        --data-urlencode "text=${MSG_TEXT}"
    )"

    echo "Telegram 返回: $TG_RESPONSE"

    if echo "$TG_RESPONSE" | grep -q '"ok":true'; then
      echo "✅ Telegram 通知发送成功！"
    else
      echo "❌ Telegram 通知发送失败。"
    fi
  else
    echo "⚠️ 未找到可用的 Telegram 配置，跳过通知。"
  fi
fi

# ==============================================================================
# 11. 输出当前状态
# ==============================================================================
echo
echo "================ 当前服务状态 ================"
docker ps --filter "name=${CONTAINER_NAME}"
echo
echo "最近日志："
docker logs --tail=20 "${CONTAINER_NAME}" 2>/dev/null || true
echo "============================================="

