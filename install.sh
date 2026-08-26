#!/usr/bin/env bash
# NativeLink one-command installer
#
# Usage:
#   # Deploy CAS (content-addressable + action cache store)
#   curl -fsSL https://raw.githubusercontent.com/littlexia4-creator/nativelink-deploy/main/install.sh | bash -s -- cas
#
#   # Deploy a scheduler pointing at the CAS host
#   curl -fsSL https://raw.githubusercontent.com/littlexia4-creator/nativelink-deploy/main/install.sh | bash -s -- scheduler <CAS_IP>
#
#   # Deploy a worker pointing at CAS and scheduler
#   curl -fsSL https://raw.githubusercontent.com/littlexia4-creator/nativelink-deploy/main/install.sh | bash -s -- worker <CAS_IP> [SCHEDULER_IP]
#
# Options (via environment variables):
#   DEPLOY_DIR        Install directory (default: ~/nativelink-<type>)
#   CAS_MAX_GB        CAS store size in GB (default: 500, cas only)
#   AC_MAX_GB         AC store size in GB (default: 10, cas only)
#   WORKER_CACHE_GB   Worker local cache in GB (default: 50, worker only)
#   MAX_TASKS         Max concurrent tasks (default: auto-detect via nproc, worker only)
#   RUST_LOG          Log level (default: warn)

set -euo pipefail

# ── Constants ──────────────────────────────────────────────────────────────
REPO_BASE="https://raw.githubusercontent.com/littlexia4-creator/nativelink-deploy/main"
# ── Parse arguments ────────────────────────────────────────────────────────
usage() {
    cat <<'EOF'
Usage:
  install.sh cas                             Deploy CAS + AC store
  install.sh scheduler <CAS_IP>              Deploy scheduler connecting to CAS_IP
  install.sh worker <CAS_IP> [SCHEDULER_IP]  Deploy worker (SCHEDULER_IP defaults to CAS_IP)

Environment variables:
  DEPLOY_DIR=<path>        Install directory (default: ~/nativelink-<type>)
  CAS_MAX_GB=<num>         CAS store max size in GB (default: 500, cas only)
  AC_MAX_GB=<num>          AC store max size in GB (default: 10, cas only)
  WORKER_CACHE_GB=<num>    Worker local cache in GB (default: 30)
  MAX_TASKS=<num>          Max concurrent tasks (default: nproc)
  RUST_LOG=<level>         Log verbosity: error|warn|info|debug (default: warn)
EOF
    exit 1
}

INSTALL_TYPE="${1:-}"
CAS_IP="${2:-}"
SCHEDULER_IP="${3:-}"

if [[ -z "$INSTALL_TYPE" ]]; then
    usage
fi

case "$INSTALL_TYPE" in
    cas|scheduler|worker) ;;
    *)
        echo "Error: first argument must be 'cas', 'scheduler' or 'worker'"
        usage
        ;;
esac

if [[ "$INSTALL_TYPE" == "scheduler" && -z "$CAS_IP" ]]; then
    echo "Error: scheduler mode requires CAS_IP as second argument"
    echo "  install.sh scheduler <CAS_IP>"
    exit 1
fi

if [[ "$INSTALL_TYPE" == "worker" ]]; then
    if [[ -z "$CAS_IP" ]]; then
        echo "Error: worker mode requires CAS_IP as second argument"
        echo "  install.sh worker <CAS_IP> [SCHEDULER_IP]"
        exit 1
    fi
    # Co-located deployments run the scheduler on the CAS host.
    SCHEDULER_IP="${SCHEDULER_IP:-$CAS_IP}"
fi

# Endpoints are host[:port]; append the standard port when none is given.
# Plain IPs keep the defaults (50051/50061); pass host:port for anything
# else (e.g. an ingress on port 80).
if [[ "$INSTALL_TYPE" == "scheduler" || "$INSTALL_TYPE" == "worker" ]]; then
    [[ "$CAS_IP" == *:* ]] || CAS_IP="$CAS_IP:50051"
fi
if [[ "$INSTALL_TYPE" == "worker" ]]; then
    [[ "$SCHEDULER_IP" == *:* ]] || SCHEDULER_IP="$SCHEDULER_IP:50061"
fi

if [[ $EUID -ne 0 ]]; then
    echo "Error: run as root — the installer may create and mount an XFS store."
    echo "  sudo bash install.sh $*"
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
    case "$INSTALL_TYPE" in
        cas)       ports=(50051) ;;
        scheduler) ports=(50052 50061) ;;
    esac
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
if [[ "$INSTALL_TYPE" == "scheduler" ]]; then
    echo "CAS: $CAS_IP"
elif [[ "$INSTALL_TYPE" == "worker" ]]; then
    echo "CAS: $CAS_IP"
    echo "Scheduler: $SCHEDULER_IP"
fi
echo ""

check_docker
check_arch
check_ports

# ── Download configs ───────────────────────────────────────────────────────
github_raw_to_jsdelivr() {
  local url="$1"
  local owner repo branch file_path
  local CDN_BASE="https://cdn.jsdelivr.net/gh"

  # Check if the URL is from raw.githubusercontent.com
  if [[ $url =~ ^https://raw\.githubusercontent\.com/([^/]+)/([^/]+)/([^/]+)/(.+)$ ]]; then
    owner="${BASH_REMATCH[1]}"
    repo="${BASH_REMATCH[2]}"
    branch="${BASH_REMATCH[3]}"
    file_path="${BASH_REMATCH[4]}" # This captures the full path including subdirectories

    # Construct the jsDelivr URL
    echo "$CDN_BASE/${owner}/${repo}@${branch}/${file_path}"
  else
    # If the URL doesn't match, return the original (or handle error)
    return 1
  fi
}

github_raw_to_proxy() {
  local raw_url="$1"
  local PROXY_BASE="https://ghproxy.net/"

  # Check if an input URL was provided
  if [[ -z "$raw_url" ]]; then
    echo "Error: No GitHub Raw URL provided"
    return 1
  fi

  # Validate that the URL starts with the expected GitHub Raw format
  if [[ $raw_url =~ ^https://raw\.githubusercontent\.com/.+ ]]; then
    # Construct the proxied URL
    local proxied_url="${PROXY_BASE}${raw_url}"
    echo "$proxied_url"
  else
    echo "Error: Provided URL is not in a valid GitHub Raw URL format: $raw_url"
    return 1
  fi
}

download() {
    local url="$1" dest="$2"
    echo "  Downloading $dest ..."
    converted_url=$(github_raw_to_proxy "$url")
    if [[ -z "$converted_url" ]]; then
      converted_url=$(github_raw_to_jsdelivr "$url")
    fi

    if [[ -z "$converted_url" ]]; then
      echo "Error: Unable to convert URL: $url"
      return 1
    fi
    echo "  Using URL: $converted_url"
    curl -fsSL "$converted_url" -o "$dest"
}

DEFAULT_DEPLOY_DIR_NAME="nativelink-${INSTALL_TYPE}"
DEPLOY_DIR="${DEPLOY_DIR:-~/$DEFAULT_DEPLOY_DIR_NAME}"

echo ""
echo "Installing to: $DEPLOY_DIR"
if [[ "$DEPLOY_DIR" == ~* ]]; then
    cd ~
    mkdir -p "$DEFAULT_DEPLOY_DIR_NAME"
    cd "$DEFAULT_DEPLOY_DIR_NAME"
else
    mkdir -p "$DEPLOY_DIR"
    cd "$DEPLOY_DIR"
fi

# ── XFS store setup ──────────────────────────────────────────────────────
# Why XFS: NativeLink's filesystem store puts ALL blobs into ONE directory
# (content_path-cas/d/). ext4 caps a single directory at ~8-10M entries
# (htree depth 2 without large_dir); a 100+ GB CAS quota exceeds that and
# writes fail with ENOSPC despite plenty of free space. XFS has no
# practical per-directory limit.
#
# Why a loop file: most hosts have no spare disk; one loop file is a single
# entry in the host directory, and XFS inside it holds the millions of blobs.
#
# CRITICAL: the backing file must be PREALLOCATED (fallocate, not truncate).
# A sparse loop allocates backing extents on first write, which collapsed
# fsync throughput from ~225 MB/s to ~55 MB/s in production and stalled
# worker output uploads at 28-39 s per action.
require_int() {
    case "$2" in
        ''|*[!0-9]*)
            echo "Error: $1 must be a positive integer (got: '$2')"
            exit 1
            ;;
    esac
}

ensure_xfsprogs() {
    if command -v mkfs.xfs &>/dev/null; then
        echo "[ok] mkfs.xfs available"
        return
    fi
    echo "Installing xfsprogs ..."
    if command -v apt-get &>/dev/null; then
        DEBIAN_FRONTEND=noninteractive apt-get install -y xfsprogs
    elif command -v dnf &>/dev/null; then
        dnf install -y xfsprogs
    elif command -v yum &>/dev/null; then
        yum install -y xfsprogs
    else
        echo "Error: no package manager found to install xfsprogs."
        exit 1
    fi
    command -v mkfs.xfs &>/dev/null || { echo "Error: xfsprogs install failed"; exit 1; }
}

setup_xfs_store() {
    # $1 = store quota GB, $2 = extra headroom GB (staging/work scratch)
    local quota_gb=$1 headroom_gb=${2:-0}
    # +10% for temp-path staging and fs metadata.
    local loop_gb=$(( (quota_gb + headroom_gb) * 110 / 100 + 1 ))
    local img="$DEPLOY_DIR/cas-store.img"
    local mnt="$DEPLOY_DIR/store"

    NATIVELINK_DIR="$mnt"

    # Idempotent: already set up and mounted?
    if [[ -f "$img" ]] && mountpoint -q "$mnt" 2>/dev/null \
       && [[ "$(df -T "$mnt" | awk 'NR==2 {print $2}')" == "xfs" ]]; then
        echo "[ok] XFS store already mounted at $mnt"
        return
    fi

    ensure_xfsprogs

    # fallocate reserves the full loop size up front — check the disk fits it.
    local avail_kb avail_gb
    avail_kb=$(df -Pk "$DEPLOY_DIR" | awk 'NR==2 {print $4}')
    avail_gb=$(( avail_kb / 1024 / 1024 ))
    if (( loop_gb + 10 > avail_gb )); then
        echo "Error: XFS loop needs ${loop_gb} GB (+10 GB margin) but only ${avail_gb} GB free."
        echo "  Deploy dir: $PWD"
        echo "Lower CAS_MAX_GB / AC_MAX_GB / WORKER_CACHE_GB, or point DEPLOY_DIR at a bigger disk."
        exit 1
    fi
    echo "[ok] Disk budget: ${loop_gb} GB loop fits (${avail_gb} GB free)"

    echo "Creating ${loop_gb} GB preallocated XFS loop ..."
    fallocate -l "${loop_gb}G" "$img"
    local lo
    lo=$(losetup -f --show "$img")
    mkfs.xfs -f "$lo" >/dev/null
    mkdir -p "$mnt"
    mount "$lo" "$mnt"
    if ! grep -qsF "$img" /etc/fstab; then
        echo "$img $mnt xfs loop,nofail 0 0" >> /etc/fstab
        echo "[ok] fstab entry added (loop,nofail)"
    fi
    echo "[ok] XFS store mounted: $mnt ($(df -h "$mnt" | awk 'NR==2 {print $2}') total)"
}

# The scheduler holds no persistent data (it proxies to CAS over gRPC),
# so only cas and worker need an XFS store.
if [[ "$INSTALL_TYPE" == "cas" ]]; then
    require_int CAS_MAX_GB "${CAS_MAX_GB:-500}"
    require_int AC_MAX_GB "${AC_MAX_GB:-10}"
    setup_xfs_store "$(( ${CAS_MAX_GB:-500} + ${AC_MAX_GB:-10} ))" 0
elif [[ "$INSTALL_TYPE" == "worker" ]]; then
    require_int WORKER_CACHE_GB "${WORKER_CACHE_GB:-50}"
    # +20 GB for the action work_directory scratch.
    setup_xfs_store "${WORKER_CACHE_GB:-50}" 20
fi

if [[ "$INSTALL_TYPE" == "cas" ]]; then
    download "$REPO_BASE/cas/docker-compose.yml"      "docker-compose.yml"
    download "$REPO_BASE/cas/local-storage-cas.json5" "local-storage-cas.json5"
elif [[ "$INSTALL_TYPE" == "scheduler" ]]; then
    download "$REPO_BASE/scheduler/docker-compose.yml" "docker-compose.yml"
    download "$REPO_BASE/scheduler/scheduler.json5"    "scheduler.json5"
else
    download "$REPO_BASE/worker/docker-compose.yml" "docker-compose.yml"
    download "$REPO_BASE/worker/worker.json5"        "worker.json5"
fi

# ── Apply customizations ──────────────────────────────────────────────────
apply_cas_config() {
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
    local worker_cache_gb="${WORKER_CACHE_GB:-50}"
    cache_bytes=$(( ${worker_cache_gb} * 1000000000 ))
    max_tasks="${MAX_TASKS:-$(nproc 2>/dev/null || echo 4)}"

    # Worker local cache size
    sed -i "s/max_bytes: 30000000000/max_bytes: ${cache_bytes}/" worker.json5
    # Max concurrent tasks
    sed -i "s/max_inflight_tasks: 32/max_inflight_tasks: ${max_tasks}/" worker.json5

    echo "[ok] Worker cache: ${worker_cache_gb} GB, max tasks: $max_tasks"
}

if [[ "$INSTALL_TYPE" == "cas" ]]; then
    apply_cas_config
elif [[ "$INSTALL_TYPE" == "worker" ]]; then
    apply_worker_config
fi

# ── Create .env file ──────────────────────────────────────────────────────
create_env() {
    cat > .env <<ENVEOF
RUST_LOG=${RUST_LOG:-warn}
ENVEOF

    if [[ "$INSTALL_TYPE" == "cas" || "$INSTALL_TYPE" == "worker" ]]; then
        echo "NATIVELINK_DIR=${NATIVELINK_DIR}" >> .env
    fi

    if [[ "$INSTALL_TYPE" == "scheduler" ]]; then
        echo "CAS_ENDPOINT=${CAS_IP}" >> .env
    elif [[ "$INSTALL_TYPE" == "worker" ]]; then
        cat >> .env <<ENVEOF
CAS_ENDPOINT=${CAS_IP}
SCHEDULER_ENDPOINT=${SCHEDULER_IP}
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
SCRIPT

# The scheduler has no local store — skip the store health section.
if [[ "$INSTALL_TYPE" != "scheduler" ]]; then
cat >> status.sh <<'SCRIPT'
echo ""
echo "=== Store ==="
store_dir=$(sed -n 's/^NATIVELINK_DIR=//p' .env 2>/dev/null)
store_dir=${store_dir:-./.cache/nativelink}
if ! mountpoint -q "$store_dir" 2>/dev/null; then
    echo "WARNING: $store_dir is NOT mounted (loop not attached after reboot?)."
    echo "  Fix: sudo mount $store_dir   (fstab entry: cas-store.img ... loop,nofail)"
fi
df -hT "$store_dir" 2>/dev/null | tail -1
fstype=$(df -T "$store_dir" 2>/dev/null | awk 'NR==2 {print $2}')
if [[ -n "$fstype" && "$fstype" != "xfs" ]]; then
    echo "WARNING: store on '$fstype'. ext4 limits ONE directory to ~8-10M files;"
    echo "  NativeLink keeps all blobs in content_path-cas/d — use XFS (see install.sh)."
fi
# The failure mode block/inode checks miss: per-directory entry count.
for d in content_path-cas/d data-worker-test/content_path-cas; do
    dir="$store_dir/$d"
    [[ -d "$dir" ]] || continue
    n=$(ls -f "$dir" 2>/dev/null | wc -l)
    echo "$d: $n entries"
    if (( n > 6000000 )) && [[ "$fstype" != "xfs" ]]; then
        echo "WARNING: >6M entries in one $fstype directory — writes will start failing with ENOSPC."
    fi
done
SCRIPT
fi
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
echo "  ./start.sh     Start services"
echo "  ./stop.sh      Stop services"
echo "  ./logs.sh      Follow logs"
echo "  ./status.sh    Check status"
echo ""

if [[ "$INSTALL_TYPE" == "cas" ]]; then
    local_ip=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "<this-host-ip>")
    echo "Port exposed:"
    echo "  50051  CAS / AC / ByteStream"
    echo ""
    echo "Next: deploy a scheduler pointing at this host:"
    echo "  curl -fsSL $REPO_BASE/install.sh | bash -s -- scheduler $local_ip"
elif [[ "$INSTALL_TYPE" == "scheduler" ]]; then
    local_ip=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "<this-host-ip>")
    echo "Scheduler is connecting to CAS: $CAS_IP"
    echo "Ports exposed:"
    echo "  50052  Execution / Capabilities"
    echo "  50061  Worker API (for workers)"
    echo ""
    echo "To add a worker on another machine:"
    echo "  curl -fsSL $REPO_BASE/install.sh | bash -s -- worker $CAS_IP $local_ip"
else
    echo "Worker is connecting to:"
    echo "  CAS:       $CAS_IP"
    echo "  Scheduler: $SCHEDULER_IP"
    echo ""
    echo "Verify connectivity:"
    echo "  nc -zv ${CAS_IP%:*} ${CAS_IP##*:} && nc -zv ${SCHEDULER_IP%:*} ${SCHEDULER_IP##*:}"
fi
