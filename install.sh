#!/usr/bin/env bash
# ============================================================
# install.sh — 财务账本 Mac 本地部署脚本
# 功能：pm2 守护进程 + 开机自启
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
echo "  💰 财务账本 — 本地部署脚本"
echo "  ================================"
echo ""

# ── 1. 检查 Node.js ──────────────────────────────────────────
if ! command -v node &>/dev/null; then
  error "未检测到 Node.js，请先运行：brew install node"
fi
info "Node.js 已安装：$(node -v)"

# ── 2. 安装 pm2 ──────────────────────────────────────────────
if ! command -v pm2 &>/dev/null; then
  warn "pm2 未安装，正在安装..."
  npm install -g pm2 --quiet
  info "pm2 安装完成"
else
  info "pm2 已安装：$(pm2 -v)"
fi

# ── 3. 写入 .env 文件 ─────────────────────────────────────────
cat > "$ENV_FILE" << ENVEOF
PORT=${PORT}
HOST=127.0.0.1
ENVEOF
chmod 600 "$ENV_FILE"
info ".env 文件已写入"

# ── 4. 创建 pm2 ecosystem 配置 ────────────────────────────────
cat > "$APP_DIR/ecosystem.config.js" << JSEOF
module.exports = {
  apps: [{
    name: '${APP_NAME}',
    script: 'server.js',
    cwd: '${APP_DIR}',
    env_file: '${ENV_FILE}',
    restart_delay: 3000,
    max_restarts: 10,
    watch: false,
    log_date_format: 'YYYY-MM-DD HH:mm:ss',
  }]
};
JSEOF
info "pm2 ecosystem 配置已生成"

# ── 5. 启动 / 重启服务 ────────────────────────────────────────
cd "$APP_DIR"
if pm2 describe "$APP_NAME" &>/dev/null; then
  pm2 reload ecosystem.config.js --update-env
  info "服务已重载"
else
  pm2 start ecosystem.config.js
  info "服务已启动"
fi

# ── 6. 设置开机自启（macOS launchd）─────────────────────────
pm2 save --force

PLIST_NAME="com.finance-calculator.plist"
PLIST_PATH="$HOME/Library/LaunchAgents/$PLIST_NAME"
PM2_BIN=$(command -v pm2)
NODE_BIN=$(command -v node)

mkdir -p "$HOME/Library/LaunchAgents"
mkdir -p "$APP_DIR/logs"

cat > "$PLIST_PATH" << PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.finance-calculator</string>
  <key>ProgramArguments</key>
  <array>
    <string>${NODE_BIN}</string>
    <string>${PM2_BIN}</string>
    <string>resurrect</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <false/>
  <key>StandardOutPath</key>
  <string>${APP_DIR}/logs/launchd.log</string>
  <key>StandardErrorPath</key>
  <string>${APP_DIR}/logs/launchd-error.log</string>
</dict>
</plist>
PLISTEOF

launchctl unload "$PLIST_PATH" 2>/dev/null || true
launchctl load -w "$PLIST_PATH"
info "开机自启已配置（launchd）"

# ── 7. 验证服务 ───────────────────────────────────────────────
sleep 2
if curl -sf "http://127.0.0.1:${PORT}/" | grep -q "财务\|html\|HTML" 2>/dev/null; then
  info "服务验证通过"
else
  warn "服务可能还在启动中，稍后访问：http://127.0.0.1:${PORT}"
fi

# ── 完成 ──────────────────────────────────────────────────────
echo ""
echo "  ============================================"
echo "  ✅ 部署完成！"
echo ""
echo "  📍 访问地址：http://127.0.0.1:${PORT}"
echo ""
echo "  📋 常用命令："
echo "     pm2 status              # 查看状态"
echo "     pm2 logs ${APP_NAME}    # 查看日志"
echo "     pm2 restart ${APP_NAME} # 重启服务"
echo "  ============================================"
echo ""
