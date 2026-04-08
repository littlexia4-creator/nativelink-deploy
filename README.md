# NativeLink Deploy

One-command deployment of [NativeLink](https://github.com/TraceMachina/nativelink) for Chromium remote builds.

## Quick Start

### Deploy Server (CAS + Scheduler)

On the main Linux server:

```bash
curl -fsSL https://raw.githubusercontent.com/littlexia4-creator/nativelink-deploy/main/install.sh | bash -s -- server
```

### Deploy Worker

On any additional Linux server:

```bash
curl -fsSL https://raw.githubusercontent.com/littlexia4-creator/nativelink-deploy/main/install.sh | bash -s -- worker <SERVER_IP>
```

Replace `<SERVER_IP>` with the IP of the server running CAS + Scheduler.

## Requirements

| Requirement | Details |
|-------------|---------|
| OS | x86_64 Linux |
| Docker | Docker Engine + Compose v2 |
| Network | TCP access to server ports 50051, 50061 (worker only) |
| Disk | 30 GB+ free |

## Configuration

Set environment variables before the pipe to customize:

```bash
# Server with custom store sizes
CAS_MAX_GB=200 AC_MAX_GB=5 curl -fsSL .../install.sh | bash -s -- server

# Worker with custom cache and task limit
WORKER_CACHE_GB=50 MAX_TASKS=16 curl -fsSL .../install.sh | bash -s -- worker 10.0.0.1

# Custom install directory
DEPLOY_DIR=~/nativelink curl -fsSL .../install.sh | bash -s -- server
```

| Variable | Default | Applies to | Description |
|----------|---------|------------|-------------|
| `DEPLOY_DIR` | `~/nativelink-server` or `~/nativelink-worker` | both | Install directory |
| `CAS_MAX_GB` | `500` | server | CAS store max size (GB) |
| `AC_MAX_GB` | `10` | server | Action Cache max size (GB) |
| `WORKER_CACHE_GB` | `30` | worker | Worker local cache (GB) |
| `MAX_TASKS` | auto (`nproc`) | worker | Max concurrent compile tasks |
| `RUST_LOG` | `warn` | both | Log level: error, warn, info, debug |

## Management

After installation, helper scripts are created in `$DEPLOY_DIR`:

```bash
cd /opt/nativelink    # or your DEPLOY_DIR
./start.sh            # Start services
./stop.sh             # Stop services
./logs.sh             # Follow logs (pass service name to filter)
./status.sh           # Container status + resource usage + cache size
```

## Architecture

```
Mac (reproxy)
  +--> :50051 -----> CAS        (server)
  +--> :50052 -----> Scheduler  (server)
                        |
                        +--> :50061 <-- Worker A (server, local)
                        +--> :50061 <-- Worker B (remote server 1)
                        +--> :50061 <-- Worker C (remote server 2)
```

- **Server** runs CAS + Scheduler. One per cluster.
- **Workers** connect to the server. One per machine, `max_inflight_tasks` = CPU count.
- All components use host networking (`network_mode: host`).

## Ports

| Port | Service | Direction |
|------|---------|-----------|
| 50051 | CAS / AC / ByteStream | Mac -> Server, Worker -> Server |
| 50052 | Execution / Capabilities | Mac -> Server |
| 50061 | Worker API | Worker -> Server |
