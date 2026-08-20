# NativeLink Deploy

One-command deployment of [NativeLink](https://github.com/TraceMachina/nativelink) for Chromium remote builds.

## Quick Start

The installer needs **root** (it creates and mounts an XFS store).

### Deploy Server (CAS + Scheduler)

On the main Linux server:

```bash
curl -fsSL https://raw.githubusercontent.com/littlexia4-creator/nativelink-deploy/main/install.sh -o /tmp/nativelink-install.sh
sudo bash /tmp/nativelink-install.sh server
```

### Deploy Worker

On any additional Linux server:

```bash
curl -fsSL https://raw.githubusercontent.com/littlexia4-creator/nativelink-deploy/main/install.sh -o /tmp/nativelink-install.sh
sudo bash /tmp/nativelink-install.sh worker <SERVER_IP>
```

Replace `<SERVER_IP>` with the IP of the server running CAS + Scheduler.

## Requirements

| Requirement | Details |
|-------------|---------|
| OS | x86_64 Linux |
| Root | Installer mounts an XFS store and edits `/etc/fstab` |
| Docker | Docker Engine + Compose v2 |
| Network | TCP access to server ports 50051, 50061 (worker only) |
| Disk | Free space ≥ store quota × 1.1 + 10 GB (the XFS loop file is **preallocated** up front) |

## Configuration

Pass environment variables to the install command:

```bash
# Server with custom store sizes
sudo CAS_MAX_GB=200 AC_MAX_GB=5 bash /tmp/nativelink-install.sh server

# Worker with custom cache and task limit
sudo WORKER_CACHE_GB=50 MAX_TASKS=16 bash /tmp/nativelink-install.sh worker 10.0.0.1

# Custom install directory
sudo DEPLOY_DIR=/data/nativelink bash /tmp/nativelink-install.sh server
```

| Variable | Default | Applies to | Description |
|----------|---------|------------|-------------|
| `DEPLOY_DIR` | `~/nativelink-server` or `~/nativelink-worker` | both | Install directory |
| `CAS_MAX_GB` | `500` | server | CAS store max size (GB) |
| `AC_MAX_GB` | `10` | server | Action Cache max size (GB) |
| `WORKER_CACHE_GB` | `50` | worker | Worker local cache (GB) |
| `MAX_TASKS` | auto (`nproc`) | worker | Max concurrent compile tasks |
| `RUST_LOG` | `warn` | both | Log level: error, warn, info, debug |

## Storage design (XFS)

The installer puts the cache on an **XFS filesystem inside a preallocated
loop file** (`$DEPLOY_DIR/cas-store.img`, mounted at `$DEPLOY_DIR/store`,
persisted in `/etc/fstab` with `loop,nofail`). Do not point the store at a
plain ext4 directory. Two production incidents motivate this:

1. **ext4 per-directory limit.** NativeLink's filesystem store keeps ALL
   blobs in one directory (`content_path-cas/d/`). ext4's htree caps a
   single directory at ~8–10M entries without the `large_dir` feature;
   beyond that, inserts fail with `No space left on device` even with
   hundreds of GB free. A 100+ GB CAS quota exceeds the cap in days.
   XFS has no practical per-directory limit.
2. **Sparse loop files are slow.** The backing file must be created with
   `fallocate`, never `truncate`: a sparse loop allocates extents on first
   write, which collapsed fsync throughput from ~225 MB/s to ~55 MB/s and
   stalled worker output uploads at 28–39 s per action.

After any host reboot, confirm the store remounted: `df -T` on
`$DEPLOY_DIR/store` must show `xfs`. `./status.sh` warns if it did not.

## Management

After installation, helper scripts are created in `$DEPLOY_DIR`:

```bash
cd /opt/nativelink    # or your DEPLOY_DIR
./start.sh            # Start services
./stop.sh             # Stop services
./logs.sh             # Follow logs (pass service name to filter)
./status.sh           # Containers + resources + store health
                        (warns if store is not XFS, not mounted, or if a
                         single directory exceeds 6M entries)
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
