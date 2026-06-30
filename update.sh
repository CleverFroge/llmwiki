#!/bin/bash
# update.sh — 从 CleverFroge/llmwiki 一键更新并重启服务
# 用法: bash update.sh
# 可选环境变量:
#   LLMWIKI_DIR     项目目录，默认 /root/llmwiki
#   WORKSPACE_PATH  数据目录，默认 /root/research
#   SERVER_IP       公网 IP，默认从 curl 自动获取
#   LLMWIKI_USER_ID MCP 的 user_id，默认从 SQLite 读取

set -e

# ── 配置 ────────────────────────────────────────────────────────────────────
LLMWIKI_DIR="${LLMWIKI_DIR:-/root/llmwiki}"
WORKSPACE_PATH="${WORKSPACE_PATH:-/root/research}"
VENV="$LLMWIKI_DIR/.venv"
DB="$WORKSPACE_PATH/.llmwiki/index.db"

# 公网 IP（可手动指定 SERVER_IP=x.x.x.x bash update.sh）
if [ -z "$SERVER_IP" ]; then
    SERVER_IP=$(curl -s ifconfig.me || curl -s ipinfo.io/ip)
fi

# MCP user_id（从 SQLite 读，也可手动指定）
if [ -z "$LLMWIKI_USER_ID" ] && [ -f "$DB" ]; then
    LLMWIKI_USER_ID=$(sqlite3 "$DB" "SELECT user_id FROM workspace LIMIT 1;" 2>/dev/null || true)
fi

# ── 颜色输出 ─────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# ── 1. 拉取最新代码 ──────────────────────────────────────────────────────────
info "拉取最新代码..."
cd "$LLMWIKI_DIR"
git fetch origin master
LOCAL=$(git rev-parse HEAD)
REMOTE=$(git rev-parse origin/master)
if [ "$LOCAL" = "$REMOTE" ]; then
    warn "代码已是最新，跳过 git pull"
else
    git pull origin master
    info "代码已更新: $LOCAL → $REMOTE"
fi

# ── 2. 数据库迁移（幂等，可重复执行）────────────────────────────────────────
if [ -f "$DB" ]; then
    info "检查数据库迁移..."
    HAS_KB_ID=$(sqlite3 "$DB" "SELECT COUNT(*) FROM pragma_table_info('documents') WHERE name='kb_id';" 2>/dev/null || echo "0")
    if [ "$HAS_KB_ID" = "0" ]; then
        info "迁移 documents 表：添加 kb_id 字段..."
        sqlite3 "$DB" "
            ALTER TABLE documents ADD COLUMN kb_id TEXT;
            UPDATE documents SET kb_id = (SELECT id FROM workspace LIMIT 1) WHERE kb_id IS NULL;
        "
        info "数据库迁移完成"
    else
        info "数据库已是最新，跳过迁移"
    fi
else
    warn "未找到 SQLite 数据库，跳过迁移（首次部署请先运行 llmwiki init）"
fi

# ── 3. 更新 Python 依赖 ──────────────────────────────────────────────────────
info "更新 Python 依赖..."
source "$VENV/bin/activate"
pip install -q -r "$LLMWIKI_DIR/api/requirements.txt" \
                  -r "$LLMWIKI_DIR/mcp/requirements.txt" \
    -i https://mirrors.cloud.tencent.com/pypi/simple

# ── 4. 更新前端依赖 ──────────────────────────────────────────────────────────
info "更新前端依赖..."
cd "$LLMWIKI_DIR/web"
npm install --silent

# ── 5. 停止旧进程 ────────────────────────────────────────────────────────────
info "停止旧进程..."
pkill -f "uvicorn main:app" 2>/dev/null && info "已停止 API" || true
pkill -f "http_server"      2>/dev/null && info "已停止 MCP" || true
pkill -f "next"             2>/dev/null && info "已停止 Web" || true
sleep 2

# ── 6. 启动后端 API ──────────────────────────────────────────────────────────
info "启动后端 API（端口 8000）..."
cd "$LLMWIKI_DIR/api"
source "$VENV/bin/activate"
PYTHONPATH="$LLMWIKI_DIR/api" \
MODE=local \
WORKSPACE_PATH="$WORKSPACE_PATH" \
DATABASE_URL="" \
APP_URL="http://${SERVER_IP}:3000" \
API_URL="http://${SERVER_IP}:8000" \
PYTHONIOENCODING=utf-8 \
nohup python -m uvicorn main:app --host 0.0.0.0 --port 8000 \
    > "$LLMWIKI_DIR/api.log" 2>&1 &

# ── 7. 启动 HTTP MCP server ──────────────────────────────────────────────────
if [ -n "$LLMWIKI_USER_ID" ]; then
    info "启动 HTTP MCP server（端口 8090）..."
    cd "$LLMWIKI_DIR/mcp"
    source "$VENV/bin/activate"
    PYTHONIOENCODING=utf-8 \
    LLMWIKI_USER_ID="$LLMWIKI_USER_ID" \
    nohup python -m http_server --workspace "$WORKSPACE_PATH" --port 8090 \
        > "$LLMWIKI_DIR/mcp.log" 2>&1 &
else
    warn "未找到 LLMWIKI_USER_ID，跳过 MCP server 启动（请手动设置后重试）"
fi

# ── 8. 构建并启动前端（生产模式，避免 dev 模式 hydration 陷阱）───────────────
info "构建前端（生产模式）..."
cd "$LLMWIKI_DIR/web"
rm -rf .next
NEXT_PUBLIC_MODE=local \
NEXT_PUBLIC_API_URL="http://${SERVER_IP}:8000" \
npm run build
info "启动前端（端口 3000）..."
NEXT_PUBLIC_MODE=local \
NEXT_PUBLIC_API_URL="http://${SERVER_IP}:8000" \
nohup npm run start -- --hostname 0.0.0.0 -p 3000 \
    > "$LLMWIKI_DIR/web.log" 2>&1 &

# ── 9. 健康检查 ──────────────────────────────────────────────────────────────
info "等待服务启动（10s）..."
sleep 10

API_STATUS=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:8000/v1/knowledge-bases || echo "000")
MCP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:8090/health 2>/dev/null || echo "000")

echo ""
echo "────────────────────────────────────"
if [ "$API_STATUS" = "200" ]; then
    info "API  ✓  http://${SERVER_IP}:8000"
else
    warn "API  ✗  状态码 $API_STATUS — 查看日志: tail -f $LLMWIKI_DIR/api.log"
fi

if [ "$MCP_STATUS" = "200" ]; then
    info "MCP  ✓  http://${SERVER_IP}:8090/mcp"
elif [ -n "$LLMWIKI_USER_ID" ]; then
    warn "MCP  ✗  状态码 $MCP_STATUS — 查看日志: tail -f $LLMWIKI_DIR/mcp.log"
fi

info "Web  →  http://${SERVER_IP}:3000"
echo "────────────────────────────────────"
info "更新完成！"
