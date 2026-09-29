#!/usr/bin/env bash
# ============================================================================
# BugTraceAI — VPS deploy WITHOUT Docker (Ubuntu 22.04 / jammy)
#
# Deploys, as native systemd services behind nginx:
#   1. PostgreSQL 14          (database for the WEB backend)
#   2. BugTraceAI-WEB backend (Express + Prisma, 127.0.0.1:3001)
#   3. BugTraceAI-CLI engine  (FastAPI,        127.0.0.1:8000)
#   4. BugTraceAI-WEB UI      (Vite build served by nginx, default :6869,
#                              proxies /api/, /cli-api/, /llm-proxy/)
#
# Not included (these ship as Docker containers upstream): api-routes
# (kiterunner MCP), BugTraceAI-API, reconftw-mcp, kali-mcp.
#
# Usage (as root on a fresh Ubuntu 22.04 VPS):
#   bash deploy_vps.sh
#
# Optional environment overrides:
#   REPO_URL=https://github.com/idfishmyid/BugTraceAI.git   (default: your fork)
#   INSTALL_DIR=/opt/bugtraceai
#   WEB_PORT=6869                 CLI_PORT=8000
#   WEB_URL=                      (public URL, e.g. http://example.com:6869)
#   LLM_API_KEY=                  (OpenAI-compatible key; can also be set later)
#   LLM_BASE_URL=https://api.atria-asi.ai/v1/chat/completions
#   LLM_MODEL=Atria-Dawn-Preview
#   SKIP_PLAYWRIGHT=1             (skip chromium download)
#
# Re-running the script is safe: it updates the repos and rebuilds.
# ============================================================================
set -euo pipefail

# ----------------------------------------------------------------------------
# Config
# ----------------------------------------------------------------------------
REPO_URL="${REPO_URL:-https://github.com/idfishmyid/BugTraceAI.git}"
INSTALL_DIR="${INSTALL_DIR:-/opt/bugtraceai}"
WEB_PORT="${WEB_PORT:-6869}"
CLI_PORT="${CLI_PORT:-8000}"
WEB_URL="${WEB_URL:-}"
LLM_API_KEY="${LLM_API_KEY:-}"
LLM_BASE_URL="${LLM_BASE_URL:-https://api.atria-asi.ai/v1/chat/completions}"
LLM_MODEL="${LLM_MODEL:-Atria-Dawn-Preview}"
SKIP_PLAYWRIGHT="${SKIP_PLAYWRIGHT:-0}"

WEB_DIR="$INSTALL_DIR/BugTraceAI-WEB"
CLI_DIR="$INSTALL_DIR/BugTraceAI-CLI"
SECRETS_DIR="$INSTALL_DIR/secrets"
SERVICE_USER="bugtrace"

log()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
ok()   { printf '\033[1;32m[ OK ]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31m[FAIL]\033[0m %s\n' "$*" >&2; exit 1; }
trap 'fail "line $LINENO"' ERR

[[ $EUID -eq 0 ]] || fail "Run as root (sudo bash deploy_vps.sh)"
. /etc/os-release
[[ "${ID:-}" == ubuntu ]] || warn "Tested on Ubuntu only (found: ${ID:-?}); continuing anyway."

# ----------------------------------------------------------------------------
# 0. Swap guard — npm/tsc builds need ~2 GB; cheap VPSes often have 1 GB
# ----------------------------------------------------------------------------
log "0/9 Memory check"
MEM_KB=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
SWAP_KB=$(awk '/SwapTotal/ {print $2}' /proc/meminfo)
if (( MEM_KB + SWAP_KB < 3000000 )); then
    if [[ ! -f /swapfile ]]; then
        warn "Low memory ($(( (MEM_KB+SWAP_KB)/1024 )) MB) — creating 2G swapfile"
        fallocate -l 2G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
        grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
    else
        swapon /swapfile 2>/dev/null || true
        ok "Existing swapfile enabled"
    fi
else
    ok "Memory sufficient ($(( (MEM_KB+SWAP_KB)/1024 )) MB)"
fi

# ----------------------------------------------------------------------------
# 1. System packages
# ----------------------------------------------------------------------------
log "1/9 Installing system packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq ca-certificates curl git build-essential \
    postgresql postgresql-contrib nginx \
    python3 python3-venv python3-dev \
    openssl procps gnupg >/dev/null

# Node.js 20 (NodeSource) — skip if already present and >= v20
if ! command -v node >/dev/null || [[ "$(node -v | tr -d v | cut -d. -f1)" -lt 20 ]]; then
    curl -fsSL https://deb.nodesource.com/setup_20.x | bash - >/dev/null
    apt-get install -y -qq nodejs >/dev/null
fi
ok "node $(node -v), npm $(npm -v), psql $(psql --version | awk '{print $3}')"

# ----------------------------------------------------------------------------
# 2. Source code (fork master; WEB & CLI are plain dirs since commit 6b554e9)
# ----------------------------------------------------------------------------
log "2/9 Fetching source code"
mkdir -p "$INSTALL_DIR"
if [[ -d "$INSTALL_DIR/BugTraceAI/.git" ]]; then
    git -C "$INSTALL_DIR/BugTraceAI" fetch --depth 1 origin master
    git -C "$INSTALL_DIR/BugTraceAI" reset --hard FETCH_HEAD
else
    git clone --depth 1 "$REPO_URL" "$INSTALL_DIR/BugTraceAI"
fi
rm -rf "$WEB_DIR" "$CLI_DIR"
cp -a "$INSTALL_DIR/BugTraceAI/BugTraceAI-WEB" "$WEB_DIR"
cp -a "$INSTALL_DIR/BugTraceAI/BugTraceAI-CLI" "$CLI_DIR"
ok "Source at $INSTALL_DIR/BugTraceAI"

# ----------------------------------------------------------------------------
# 3. PostgreSQL: role, database, extensions
# ----------------------------------------------------------------------------
log "3/9 Configuring PostgreSQL"
mkdir -p "$SECRETS_DIR"
if [[ -f "$SECRETS_DIR/db_password" ]]; then
    DB_PASS=$(cat "$SECRETS_DIR/db_password")
else
    DB_PASS=$(openssl rand -hex 24)
    printf '%s' "$DB_PASS" > "$SECRETS_DIR/db_password"
    chmod 600 "$SECRETS_DIR/db_password"
fi
DB_USER=bugtraceai
DB_NAME=bugtraceai_web
systemctl enable --now postgresql >/dev/null 2>&1 || true

run_as_pg() { runuser -u postgres -- psql -v ON_ERROR_STOP=1 -qAt "$@"; }
run_as_pg -c "SELECT 1 FROM pg_roles WHERE rolname='$DB_USER'" | grep -q 1 \
    || run_as_pg -c "CREATE ROLE $DB_USER LOGIN PASSWORD '$DB_PASS'"
run_as_pg -tc "SELECT 1 FROM pg_database WHERE datname='$DB_NAME'" | grep -q 1 \
    || run_as_pg -c "CREATE DATABASE $DB_NAME OWNER $DB_USER"
run_as_pg -d "$DB_NAME" <<'SQL'
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pg_trgm";
CREATE EXTENSION IF NOT EXISTS "btree_gin";
SQL
ok "Database $DB_NAME ready (password stored in $SECRETS_DIR/db_password)"

# ----------------------------------------------------------------------------
# 4. WEB frontend build (Vite) — VITE_* are inlined into the bundle
# ----------------------------------------------------------------------------
log "4/9 Building WEB frontend (this compiles TypeScript, takes a few minutes)"
cd "$WEB_DIR"
npm ci --no-audit --no-fund >/dev/null 2>&1
VITE_API_URL=/api VITE_CLI_API_URL=/cli-api VITE_BTAI_API_URL=/btai-api \
    npm run build >/dev/null 2>&1
[[ -f dist/index.html ]] || fail "Frontend build produced no dist/index.html"
ok "Frontend bundle at $WEB_DIR/dist"

# ----------------------------------------------------------------------------
# 5. WEB backend (Express + Prisma)
# ----------------------------------------------------------------------------
log "5/9 Building WEB backend and applying Prisma migrations"
cd "$WEB_DIR/backend"
npm ci --no-audit --no-fund >/dev/null 2>&1
npx prisma@5 generate >/dev/null 2>&1
npm run build >/dev/null 2>&1
[[ -f dist/index.js ]] || fail "Backend build produced no dist/index.js"

if [[ -z "$WEB_URL" ]]; then
    PRIMARY_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
    [[ -n "$PRIMARY_IP" ]] || PRIMARY_IP=$(curl -sf --max-time 5 https://api.ipify.org || echo 127.0.0.1)
    WEB_URL="http://${PRIMARY_IP}:${WEB_PORT}"
fi
cat > "$SECRETS_DIR/backend.env" <<EOF
NODE_ENV=production
PORT=3001
DATABASE_URL=postgresql://${DB_USER}:${DB_PASS}@127.0.0.1:5432/${DB_NAME}?schema=public
FRONTEND_URL=${WEB_URL}
EOF
chmod 600 "$SECRETS_DIR/backend.env"
DATABASE_URL="postgresql://${DB_USER}:${DB_PASS}@127.0.0.1:5432/${DB_NAME}?schema=public" \
    npx prisma@5 migrate deploy >/dev/null 2>&1
ok "Backend built, migrations applied"

# ----------------------------------------------------------------------------
# 6. CLI engine (Python venv + Playwright chromium)
# ----------------------------------------------------------------------------
log "6/9 Installing CLI engine (downloads CPU PyTorch — largest step)"
python3 -m venv "$CLI_DIR/venv"
PIP="$CLI_DIR/venv/bin/pip"
"$PIP" install --no-cache-dir --quiet \
    torch --index-url https://download.pytorch.org/whl/cpu
"$PIP" install --no-cache-dir --quiet -e "$CLI_DIR"
"$PIP" install --no-cache-dir --quiet sqlmap
mkdir -p "$CLI_DIR/reports" "$CLI_DIR/logs" "$CLI_DIR/data"

cat > "$CLI_DIR/.env" <<EOF
OPENROUTER_API_KEY=${LLM_API_KEY}
LLM_BASE_URL=${LLM_BASE_URL}
LLM_MODEL=${LLM_MODEL}
API_HOST=127.0.0.1
API_PORT=${CLI_PORT}
CLI_PORT=${CLI_PORT}
MCP_PORT=8001
BUGTRACE_CORS_ORIGINS=http://localhost:${WEB_PORT},${WEB_URL}
EOF
chmod 600 "$CLI_DIR/.env"

if [[ "$SKIP_PLAYWRIGHT" != "1" ]]; then
    "$CLI_DIR/venv/bin/playwright" install chromium >/dev/null 2>&1 \
        && "$CLI_DIR/venv/bin/playwright" install-deps chromium >/dev/null 2>&1 \
        && ok "Playwright chromium installed" \
        || warn "Playwright install failed (browser features disabled; core scanning still works)"
fi
ok "CLI engine installed at $CLI_DIR"

# ----------------------------------------------------------------------------
# 7. systemd services
# ----------------------------------------------------------------------------
log "7/9 Creating systemd services"
id -u "$SERVICE_USER" &>/dev/null || useradd --system --home "$INSTALL_DIR" --shell /usr/sbin/nologin "$SERVICE_USER"
chown -R "$SERVICE_USER":"$SERVICE_USER" "$INSTALL_DIR"

cat > /etc/systemd/system/bugtraceai-backend.service <<EOF
[Unit]
Description=BugTraceAI WEB backend (Express/Prisma)
After=network-online.target postgresql.service
Wants=network-online.target

[Service]
Type=simple
User=${SERVICE_USER}
WorkingDirectory=${WEB_DIR}/backend
EnvironmentFile=${SECRETS_DIR}/backend.env
ExecStartPre=${WEB_DIR}/backend/node_modules/.bin/prisma migrate deploy
ExecStart=/usr/bin/node dist/index.js
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/bugtraceai-cli.service <<EOF
[Unit]
Description=BugTraceAI CLI engine (FastAPI)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${SERVICE_USER}
WorkingDirectory=${CLI_DIR}
Environment=PYTHONUNBUFFERED=1
ExecStart=${CLI_DIR}/venv/bin/python -m bugtrace serve --host 127.0.0.1 --port ${CLI_PORT}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now bugtraceai-backend.service bugtraceai-cli.service >/dev/null 2>&1
ok "Services bugtraceai-backend and bugtraceai-cli enabled"

# ----------------------------------------------------------------------------
# 8. nginx site (SPA + API proxies + LLM proxy gate)
# ----------------------------------------------------------------------------
log "8/9 Configuring nginx on port ${WEB_PORT}"
cat > /etc/nginx/sites-available/bugtraceai.conf <<EOF
map \$http_upgrade \$connection_upgrade {
    default upgrade;
    ''      close;
}

server {
    listen ${WEB_PORT};
    server_name _;
    root ${WEB_DIR}/dist;
    index index.html;

    add_header X-Frame-Options "DENY" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;

    gzip on;
    gzip_types text/plain text/css application/json application/javascript text/xml application/xml;
    gzip_min_length 1000;

    # LLM proxy — same-origin forwarding for OpenAI-compatible endpoints
    # without CORS headers (target travels in X-LLM-Target, key gates abuse)
    location /llm-proxy/ {
        if (\$http_x_llm_proxy_key != "btai-llm-proxy-1f47a2") { return 403; }
        if (\$http_x_llm_target !~* "^https?://") { return 400; }
        proxy_pass \$http_x_llm_target;
        proxy_http_version 1.1;
        proxy_ssl_server_name on;
        proxy_ssl_protocols TLSv1.2 TLSv1.3;
        proxy_read_timeout 180s;
        proxy_send_timeout 180s;
        proxy_buffering off;
    }

    # CLI engine (HTTP + WebSocket; strips /cli-api/ prefix)
    location ^~ /cli-api/ {
        proxy_pass http://127.0.0.1:${CLI_PORT}/;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }

    # WEB backend API
    location ^~ /api/ {
        proxy_pass http://127.0.0.1:3001;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    # Socket.IO (WebSocket + polling) on the backend
    location /socket.io/ {
        proxy_pass http://127.0.0.1:3001/socket.io/;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }

    # Optional services — enable these natively later if needed:
    # /btai-api/ -> 127.0.0.1:8005, /kr-api/ -> 127.0.0.1:8004, /kr-mcp/ -> 8003

    location / {
        try_files \$uri \$uri/ /index.html;
        add_header Cache-Control "no-cache, no-store, must-revalidate";
    }

    location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg|woff|woff2)$ {
        expires 30d;
        add_header Cache-Control "public, no-transform";
    }
}
EOF
ln -sf /etc/nginx/sites-available/bugtraceai.conf /etc/nginx/sites-enabled/bugtraceai.conf
nginx -t >/dev/null 2>&1 || fail "nginx config test failed"
systemctl enable --now nginx >/dev/null 2>&1 || true
systemctl reload nginx 2>/dev/null || systemctl restart nginx
# firewall: only touch UFW if it is active
if ufw status 2>/dev/null | grep -q "Status: active"; then
    ufw allow "${WEB_PORT}/tcp" >/dev/null && ok "UFW: port ${WEB_PORT} allowed"
fi
ok "nginx serving UI on port ${WEB_PORT}"

# ----------------------------------------------------------------------------
# 9. Health checks + summary
# ----------------------------------------------------------------------------
log "9/9 Waiting for services and running health checks"
wait_for() { # url, label
    for _ in $(seq 1 60); do
        curl -sf -o /dev/null --max-time 3 "$1" && { ok "$2 healthy"; return 0; }
        sleep 2
    done
    warn "$2 NOT responding on $1 (check: journalctl -u $3 -e)"
}
wait_for "http://127.0.0.1:3001/health"  "backend"  bugtraceai-backend
wait_for "http://127.0.0.1:${CLI_PORT}/health" "cli-engine" bugtraceai-cli
wait_for "http://127.0.0.1:${WEB_PORT}/" "web-ui"   nginx

echo ""
echo "============================================================"
echo " BugTraceAI deployed (no Docker)"
echo "============================================================"
echo " URL         : ${WEB_URL}"
echo " CLI engine  : 127.0.0.1:${CLI_PORT} (via nginx /cli-api/)"
echo " DB          : ${DB_NAME} @ 127.0.0.1:5432 (user ${DB_USER})"
echo ""
echo " LLM key     : if you did not set LLM_API_KEY, put your key in:"
echo "               ${CLI_DIR}/.env  (OPENROUTER_API_KEY=...)"
echo "               then: systemctl restart bugtraceai-cli"
echo " LLM endpoint: ${LLM_BASE_URL} (model: ${LLM_MODEL})"
echo "               You can change it in the UI: Settings -> API,"
echo "               provider Custom (any OpenAI-compatible endpoint)."
echo ""
echo " Services    : systemctl {status|restart} bugtraceai-{backend,cli}"
echo " Logs        : journalctl -u bugtraceai-backend -e"
echo "               journalctl -u bugtraceai-cli -e"
echo " Update      : re-run this script"
echo "============================================================"
