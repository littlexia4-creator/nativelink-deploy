# NativeLink Deploy

One-command deployment of [NativeLink](https://github.com/TraceMachina/nativelink) for Chromium remote builds.

## Quick Start

The installer needs **root** (cas/worker modes create and mount an XFS store).

### Deploy CAS

On the Linux host that will store build artifacts:

```bash
curl -fsSL https://raw.githubusercontent.com/littlexia4-creator/nativelink-deploy/main/install.sh -o /tmp/nativelink-install.sh
sudo bash /tmp/nativelink-install.sh cas
```

### Deploy Scheduler

On the same or another Linux host (replace `<CAS_IP>` with the CAS host's IP):

```bash
curl -fsSL https://raw.githubusercontent.com/littlexia4-creator/nativelink-deploy/main/install.sh -o /tmp/nativelink-install.sh
sudo bash /tmp/nativelink-install.sh scheduler <CAS_IP>
```

### Deploy Worker

On any additional Linux server:

```bash
curl -fsSL https://raw.githubusercontent.com/littlexia4-creator/nativelink-deploy/main/install.sh -o /tmp/nativelink-install.sh
sudo bash /tmp/nativelink-install.sh worker <CAS_IP> [SCHEDULER_IP]
```

`SCHEDULER_IP` defaults to `CAS_IP` (for co-located CAS + scheduler setups).

## Requirements

| Requirement | Details |
|-------------|---------|
| OS | x86_64 Linux |
| Root | Installer mounts an XFS store and edits `/etc/fstab` |
| Docker | Docker Engine + Compose v2 |
| Network | TCP access to CAS port 50051 and scheduler port 50061 (scheduler/worker only) |
| Disk | Free space ≥ store quota × 1.1 + 10 GB (the XFS loop file is **preallocated** up front) |

## Configuration

Pass environment variables to the install command:

```bash
# CAS with custom store sizes
sudo CAS_MAX_GB=200 AC_MAX_GB=5 bash /tmp/nativelink-install.sh cas

# Worker with custom cache and task limit
sudo WORKER_CACHE_GB=50 MAX_TASKS=16 bash /tmp/nativelink-install.sh worker 10.0.0.1

# Custom install directory
sudo DEPLOY_DIR=/data/nativelink bash /tmp/nativelink-install.sh cas
```

| Variable | Default | Applies to | Description |
|----------|---------|------------|-------------|
| `DEPLOY_DIR` | `~/nativelink-<type>` | all | Install directory |
| `CAS_MAX_GB` | `500` | cas | CAS store max size (GB) |
| `AC_MAX_GB` | `10` | cas | Action Cache max size (GB) |
| `WORKER_CACHE_GB` | `50` | worker | Worker local cache (GB) |
| `MAX_TASKS` | auto (`nproc`) | worker | Max concurrent compile tasks |
| `RUST_LOG` | `warn` | all | Log level: error, warn, info, debug |

## Storage design (XFS)

For cas and worker, the installer puts the cache on an **XFS filesystem
inside a preallocated loop file** (`$DEPLOY_DIR/cas-store.img`, mounted at
`$DEPLOY_DIR/store`, persisted in `/etc/fstab` with `loop,nofail`). The
scheduler holds no persistent data and needs no store. Do not point the
store at a plain ext4 directory. Three production incidents motivate this:

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
3. **Discards punch holes.** On a file-backed loop device, a discard is
   implemented by punching holes in the backing file. `mkfs.xfs` issues a
   device-wide discard **by default**, so the installer passes `-K`
   (`mkfs.xfs -f -K`) — without it, a freshly `fallocate`d 1 GB img comes
   out 11 MB allocated. Never run `fstrim` on the store mount for the
   same reason. (A sparse img was measured at 45 ms per 4 KB write+fsync
   vs ~15 ms once refilled.)

After any host reboot, confirm the store remounted: `df -T` on
`$DEPLOY_DIR/store` must show `xfs`. `./status.sh` warns if it did not.

### Growing the store

Grow the CAS quota when the store fills. The critical rule: extend the
loop file with `fallocate`, never `truncate` or `dd` — a sparse extension
leaves holes that the underlying filesystem allocates one block at a time
*inside every fsync* (incident 2 above; measured 45 ms vs ~15 ms per 4 KB
write+fsync on a production CAS, and small sync writes are exactly the
blob-upload workload).

From the CAS host, as root:

```bash
cd $DEPLOY_DIR
docker compose down                                  # brief outage; workers retry
fallocate -l 500G cas-store.img                      # fills holes AND extends, fully allocated
losetup -c "$(losetup -j cas-store.img | cut -d: -f1)"   # loop re-reads the new size
xfs_growfs ./store                                   # XFS picks up the new size
# bump max_bytes in local-storage-cas.json5, then:
docker compose up -d
```

`fallocate` reserves the full new size immediately, so check host disk
free space first (quota × 1.1, as in Requirements). `./status.sh` warns
if the backing file ever becomes sparse.

If an existing store needs its holes filled (or the filesystem recreated),
fill them with `fallocate --keep-size -l <img-size> <img>` while the
container is stopped — and when recreating with `mkfs.xfs`, always pass
`-K` (see incident 3 above). Do not run `fstrim` on the store.

## Management

After installation, helper scripts are created in `$DEPLOY_DIR`:

```bash
cd /opt/nativelink    # or your DEPLOY_DIR
./start.sh            # Start services
./stop.sh             # Stop services
./logs.sh             # Follow logs (pass service name to filter)
./status.sh           # Containers + resources + store health
                        (warns if store is not XFS, not mounted, the backing
                         file is sparse, or a single directory exceeds 6M entries)
```

## Architecture

```
Mac (reproxy)
  +--> :50051 -----> CAS        (cas host)
  +--> :50052 -----> Scheduler  (scheduler host) -- :50051 --> CAS
                        |
                        +--> :50061 <-- Worker A (local)
                        +--> :50061 <-- Worker B (remote host 1)
                        +--> :50061 <-- Worker C (remote host 2)
```

- **CAS** stores all blobs and action results. One per cluster.
- **Scheduler** dispatches actions and proxies CAS/AC to the CAS host. One per cluster; can run on the CAS host or its own host.
- **Workers** connect to both CAS (50051) and the scheduler (50061). One per machine, `max_inflight_tasks` = CPU count.
- All components use host networking (`network_mode: host`).

## Ports

| Port | Service | Direction |
|------|---------|-----------|
| 50051 | CAS / AC / ByteStream | Mac -> CAS, Scheduler -> CAS, Worker -> CAS |
| 50052 | Execution / Capabilities | Mac -> Scheduler |
| 50061 | Worker API | Worker -> Scheduler |
