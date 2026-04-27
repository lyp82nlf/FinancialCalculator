#!/usr/bin/env bash
# ============================================================
# install.sh — 财务账本 Mac 服务器部署脚本
# 功能：安装依赖、配置 Basic Auth、pm2 守护、开机自启
# 安全：仅监听本机回环 + macOS 防火墙限制端口 + Basic Auth
# ============================================================

set -euo pipefail

PORT=5812
APP_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="finance-calculator"
ENV_FILE="$APP_DIR/.env"

# ── 颜色输出 ─────────────────────────────────────────────────
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
info()  { echo -e "${GREEN}[✓]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
error() { echo -e "${RED}[✗]${NC} $*"; exit 1; }

echo ""
echo "  💰 财务账本 — 服务器部署脚本"
echo "  ================================"
echo ""

# ── 1. 检查 Node.js ──────────────────────────────────────────
if ! command -v node &>/dev/null; then
  error "未检测到 Node.js，请先运行：brew install node"
fi
NODE_VER=$(node -v)
info "Node.js 已安装：$NODE_VER"

# ── 2. 安装 pm2 ──────────────────────────────────────────────
if ! command -v pm2 &>/dev/null; then
  warn "pm2 未安装，正在安装..."
  npm install -g pm2 --quiet
  info "pm2 安装完成"
else
  info "pm2 已安装：$(pm2 -v)"
fi

# ── 3. 配置 Basic Auth ───────────────────────────────────────
echo ""
warn "请设置访问密码（Basic Auth），留空则随机生成强密码）"

read -rp "  用户名 [admin]: " AUTH_USER
AUTH_USER="${AUTH_USER:-admin}"

read -rsp "  密码 [回车随机生成]: " AUTH_PASS
echo ""
if [[ -z "$AUTH_PASS" ]]; then
  AUTH_PASS=$(LC_ALL=C tr -dc 'A-Za-z0-9!@#%^&*' </dev/urandom | head -c 20)
  warn "随机密码已生成，请保存好 ↓"
fi

# ── 4. 写入 .env 文件 ─────────────────────────────────────────
cat > "$ENV_FILE" << EOF
PORT=$PORT
HOST=127.0.0.1
AUTH_USER=$AUTH_USER
AUTH_PASS=$AUTH_PASS
EOF
chmod 600 "$ENV_FILE"   # 仅 owner 可读
info ".env 文件已写入（权限 600）"

# ── 5. 创建 pm2 ecosystem 配置 ────────────────────────────────
cat > "$APP_DIR/ecosystem.config.js" << EOF
module.exports = {
  apps: [{
    name: '$APP_NAME',
    script: 'server.js',
    cwd: '$APP_DIR',
    env_file: '$ENV_FILE',
    restart_delay: 3000,
    max_restarts: 10,
    watch: false,
    log_date_format: 'YYYY-MM-DD HH:mm:ss',
  }]
};
EOF
info "pm2 ecosystem 配置已生成"

# ── 6. 启动 / 重启服务 ────────────────────────────────────────
cd "$APP_DIR"
if pm2 describe "$APP_NAME" &>/dev/null; then
  pm2 reload ecosystem.config.js --update-env
  info "服务已重载"
else
  pm2 start ecosystem.config.js
  info "服务已启动"
fi

# ── 7. 设置开机自启（macOS launchd）─────────────────────────
pm2 save --force

PLIST_NAME="com.finance-calculator.plist"
PLIST_PATH="$HOME/Library/LaunchAgents/$PLIST_NAME"
PM2_BIN=$(command -v pm2)
NODE_BIN=$(command -v node)

mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST_PATH" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.finance-calculator</string>
  <key>ProgramArguments</key>
  <array>
    <string>$NODE_BIN</string>
    <string>$PM2_BIN</string>
    <string>resurrect</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <false/>
  <key>StandardOutPath</key>
  <string>$APP_DIR/logs/launchd.log</string>
  <key>StandardErrorPath</key>
  <string>$APP_DIR/logs/launchd-error.log</string>
</dict>
</plist>
EOF

mkdir -p "$APP_DIR/logs"
# 重新加载 launchd agent
launchctl unload "$PLIST_PATH" 2>/dev/null || true
launchctl load -w "$PLIST_PATH"
info "开机自启已配置（launchd）"

# ── 8. macOS 防火墙：封锁端口 5812 对外访问 ──────────────────
# macOS Application Firewall（系统偏好设置里的那个）是应用级的，
# 端口级封锁用 pf（BSD 包过滤器）
warn "正在配置 pf 防火墙，阻止外部访问端口 $PORT..."

ANCHOR_NAME="finance_block"
ANCHOR_CONF="/etc/pf.anchors/$ANCHOR_NAME"

# 生成规则：只允许 127.0.0.1 访问 5812，拒绝所有其他来源
sudo tee "$ANCHOR_CONF" > /dev/null << EOF
# 拒绝外部访问端口 $PORT（财务账本仅限本机访问）
block in quick on en0 proto tcp from any to any port $PORT
block in quick on en1 proto tcp from any to any port $PORT
EOF

# 将 anchor 挂载到主 pf 配置（幂等）
PF_CONF="/etc/pf.conf"
if ! sudo grep -q "$ANCHOR_NAME" "$PF_CONF" 2>/dev/null; then
  sudo bash -c "echo '' >> '$PF_CONF'"
  sudo bash -c "echo 'anchor \"$ANCHOR_NAME\"' >> '$PF_CONF'"
  sudo bash -c "echo 'load anchor \"$ANCHOR_NAME\" from \"$ANCHOR_CONF\"' >> '$PF_CONF'"
fi

# 启用 pf 并重载规则
sudo pfctl -e 2>/dev/null || true
sudo pfctl -f "$PF_CONF" 2>/dev/null && info "pf 防火墙规则已加载"

# ── 9. 验证服务 ───────────────────────────────────────────────
sleep 2
if curl -s -u "$AUTH_USER:$AUTH_PASS" "http://127.0.0.1:$PORT/" | grep -q "财务"; then
  info "服务验证通过"
else
  warn "服务可能还在启动中，稍后手动验证：curl -u $AUTH_USER:*** http://127.0.0.1:$PORT/"
fi

# ── 完成 ──────────────────────────────────────────────────────
echo ""
echo "  ============================================"
echo "  ✅ 部署完成！"
echo ""
echo "  📍 服务地址（仅本机）: http://127.0.0.1:$PORT"
echo "  👤 用户名: $AUTH_USER"
echo "  🔑 密码:   $AUTH_PASS"
echo ""
echo "  🔒 安全说明："
echo "     · Node.js 仅监听 127.0.0.1（回环地址）"
echo "     · pf 防火墙已封锁外部对 $PORT 端口的访问"
echo "     · Basic Auth 保护所有页面和 API"
echo "     · 请勿直接暴露此端口到公网"
echo ""
echo "  📡 如需局域网访问，推荐用 SSH 隧道："
echo "     在客户端运行：ssh -L $PORT:127.0.0.1:$PORT user@服务器IP"
echo "     然后访问：http://127.0.0.1:$PORT"
echo ""
echo "  📋 常用命令："
echo "     pm2 status          # 查看状态"
echo "     pm2 logs $APP_NAME  # 查看日志"
echo "     pm2 restart $APP_NAME"
echo "  ============================================"
echo ""
