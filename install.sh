#!/usr/bin/env bash
# NativeLink one-command installer
#
# Usage:
#   # Deploy CAS + Scheduler (the "server")
#   curl -fsSL https://raw.githubusercontent.com/littlexia4-creator/nativelink-deploy/main/install.sh | bash -s -- server
#
#   # Deploy a worker pointing to a server
#   curl -fsSL https://raw.githubusercontent.com/littlexia4-creator/nativelink-deploy/main/install.sh | bash -s -- worker <SERVER_IP>
#
# Options (via environment variables):
#   DEPLOY_DIR        Install directory (default: /opt/nativelink)
#   CAS_MAX_GB        CAS store size in GB (default: 500, server only)
#   AC_MAX_GB         AC store size in GB (default: 10, server only)
#   WORKER_CACHE_GB   Worker local cache in GB (default: 30, worker only)
#   MAX_TASKS         Max concurrent tasks (default: auto-detect via nproc, worker only)
#   RUST_LOG          Log level (default: warn)

set -euo pipefail

# ── Constants ──────────────────────────────────────────────────────────────
REPO_BASE="https://raw.githubusercontent.com/littlexia4-creator/nativelink-deploy/main"
DEPLOY_DIR="${DEPLOY_DIR:-/opt/nativelink}"

# ── Parse arguments ────────────────────────────────────────────────────────
usage() {
    cat <<'EOF'
Usage:
  install.sh server                    Deploy CAS + Scheduler
  install.sh worker <SERVER_IP>        Deploy worker connecting to SERVER_IP

Environment variables:
  DEPLOY_DIR=<path>        Install directory (default: /opt/nativelink)
  CAS_MAX_GB=<num>         CAS store max size in GB (default: 500)
  AC_MAX_GB=<num>          AC store max size in GB (default: 10)
  WORKER_CACHE_GB=<num>    Worker local cache in GB (default: 30)
  MAX_TASKS=<num>          Max concurrent tasks (default: nproc)
  RUST_LOG=<level>         Log verbosity: error|warn|info|debug (default: warn)
EOF
    exit 1
}

INSTALL_TYPE="${1:-}"
SERVER_IP="${2:-}"

if [[ -z "$INSTALL_TYPE" ]]; then
    usage
fi

if [[ "$INSTALL_TYPE" != "server" && "$INSTALL_TYPE" != "worker" ]]; then
    echo "Error: first argument must be 'server' or 'worker'"
    usage
fi

if [[ "$INSTALL_TYPE" == "worker" && -z "$SERVER_IP" ]]; then
    echo "Error: worker mode requires SERVER_IP as second argument"
    echo "  install.sh worker <SERVER_IP>"
    exit 1
fi

# ── Preflight checks ──────────────────────────────────────────────────────
check_docker() {
    if ! command -v docker &>/dev/null; then
        echo "Error: Docker is not installed."
        echo "Install it: https://docs.docker.com/engine/install/"
        exit 1
    fi
    if ! docker compose version &>/dev/null; then
        echo "Error: Docker Compose v2 is not available."
        echo "Install it: https://docs.docker.com/compose/install/"
        exit 1
    fi
    echo "[ok] Docker $(docker --version | sed 's/.*version \([0-9.]*\).*/\1/')"
    echo "[ok] $(docker compose version)"
}

check_arch() {
    local arch
    arch="$(uname -m)"
    if [[ "$arch" != "x86_64" ]]; then
        echo "Warning: NativeLink worker images are x86_64. Current arch: $arch"
        echo "The worker may not function correctly on this architecture."
        read -r -p "Continue anyway? [y/N] " confirm
        [[ "$confirm" =~ ^[Yy]$ ]] || exit 1
    fi
}

check_ports() {
    local ports=()
    if [[ "$INSTALL_TYPE" == "server" ]]; then
        ports=(50051 50052 50061)
    fi
    for port in "${ports[@]+"${ports[@]}"}"; do
        if ss -tlnp 2>/dev/null | grep -q ":${port} " || \
           netstat -tlnp 2>/dev/null | grep -q ":${port} "; then
            echo "Error: Port $port is already in use."
            echo "Stop the existing service or choose a different machine."
            exit 1
        fi
    done
}

echo "=== NativeLink Installer ==="
echo "Type: $INSTALL_TYPE"
[[ -n "$SERVER_IP" ]] && echo "Server: $SERVER_IP"
echo ""

check_docker
check_arch
check_ports

# ── Download configs ───────────────────────────────────────────────────────
echo ""
echo "Installing to: $DEPLOY_DIR"
mkdir -p "$DEPLOY_DIR"
cd "$DEPLOY_DIR"

download() {
    local url="$1" dest="$2"
    echo "  Downloading $dest ..."
    curl -fsSL "$url" -o "$dest"
}

if [[ "$INSTALL_TYPE" == "server" ]]; then
    download "$REPO_BASE/server/docker-compose.yml"     "docker-compose.yml"
    download "$REPO_BASE/server/local-storage-cas.json5" "local-storage-cas.json5"
    download "$REPO_BASE/server/scheduler.json5"         "scheduler.json5"
else
    download "$REPO_BASE/worker/docker-compose.yml" "docker-compose.yml"
    download "$REPO_BASE/worker/worker.json5"        "worker.json5"
fi

# ── Apply customizations ──────────────────────────────────────────────────
apply_server_config() {
    local cas_bytes ac_bytes
    cas_bytes=$(( ${CAS_MAX_GB:-500} * 1000000000 ))
    ac_bytes=$(( ${AC_MAX_GB:-10} * 1000000000 ))

    # CAS store size
    sed -i "s/max_bytes: 500000000000/max_bytes: ${cas_bytes}/" local-storage-cas.json5
    # AC store size
    sed -i "s/max_bytes: 10000000000/max_bytes: ${ac_bytes}/" local-storage-cas.json5

    echo "[ok] CAS: ${CAS_MAX_GB:-500} GB, AC: ${AC_MAX_GB:-10} GB"
}

apply_worker_config() {
    local cache_bytes max_tasks
    cache_bytes=$(( ${WORKER_CACHE_GB:-30} * 1000000000 ))
    max_tasks="${MAX_TASKS:-$(nproc 2>/dev/null || echo 4)}"

    # Worker local cache size
    sed -i "s/max_bytes: 30000000000/max_bytes: ${cache_bytes}/" worker.json5
    # Max concurrent tasks
    sed -i "s/max_inflight_tasks: 32/max_inflight_tasks: ${max_tasks}/" worker.json5

    echo "[ok] Worker cache: ${WORKER_CACHE_GB:-30} GB, max tasks: $max_tasks"
}

if [[ "$INSTALL_TYPE" == "server" ]]; then
    apply_server_config
else
    apply_worker_config
fi

# ── Create .env file ──────────────────────────────────────────────────────
create_env() {
    cat > .env <<ENVEOF
RUST_LOG=${RUST_LOG:-warn}
ENVEOF

    if [[ "$INSTALL_TYPE" == "worker" ]]; then
        cat >> .env <<ENVEOF
CAS_ENDPOINT=${SERVER_IP}
SCHEDULER_ENDPOINT=${SERVER_IP}
ENVEOF
    fi
    echo "[ok] .env created"
}

create_env

# ── Create management scripts ─────────────────────────────────────────────
cat > start.sh <<'SCRIPT'
#!/usr/bin/env bash
cd "$(dirname "$0")"
docker compose up -d
echo "NativeLink started. View logs: docker compose logs -f"
SCRIPT
chmod +x start.sh

cat > stop.sh <<'SCRIPT'
#!/usr/bin/env bash
cd "$(dirname "$0")"
docker compose down
echo "NativeLink stopped."
SCRIPT
chmod +x stop.sh

cat > logs.sh <<'SCRIPT'
#!/usr/bin/env bash
cd "$(dirname "$0")"
docker compose logs -f "$@"
SCRIPT
chmod +x logs.sh

cat > status.sh <<'SCRIPT'
#!/usr/bin/env bash
cd "$(dirname "$0")"
echo "=== Containers ==="
docker compose ps
echo ""
echo "=== Resource Usage ==="
docker stats --no-stream --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}" $(docker compose ps -q 2>/dev/null) 2>/dev/null || true
echo ""
echo "=== Cache Disk Usage ==="
du -sh .cache/nativelink/*/ 2>/dev/null || echo "(no cache data yet)"
SCRIPT
chmod +x status.sh

# ── Start ──────────────────────────────────────────────────────────────────
echo ""
echo "Starting NativeLink ($INSTALL_TYPE)..."
docker compose up -d

echo ""
echo "=== Installation Complete ==="
echo ""
echo "Deploy directory: $DEPLOY_DIR"
echo "Management commands:"
echo "  cd $DEPLOY_DIR"
echo "  ./start.sh     Start services"
echo "  ./stop.sh      Stop services"
echo "  ./logs.sh      Follow logs"
echo "  ./status.sh    Check status"
echo ""

if [[ "$INSTALL_TYPE" == "server" ]]; then
    local_ip=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "<this-server-ip>")
    echo "Ports exposed:"
    echo "  50051  CAS / AC / ByteStream"
    echo "  50052  Execution / Capabilities"
    echo "  50061  Worker API (for remote workers)"
    echo ""
    echo "To add a worker on another server:"
    echo "  curl -fsSL $REPO_BASE/install.sh | bash -s -- worker $local_ip"
else
    echo "Worker is connecting to: $SERVER_IP"
    echo "  CAS:       $SERVER_IP:50051"
    echo "  Scheduler: $SERVER_IP:50061"
    echo ""
    echo "Verify connectivity:"
    echo "  nc -zv $SERVER_IP 50051 && nc -zv $SERVER_IP 50061"
fi
