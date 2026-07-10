# Transfer Watcher

**Transfer Watcher** is a highly efficient, lightweight containerized tool written in **Rust** that monitors a local directory for file changes and automatically transfers new or modified files to a remote host natively via **SFTP over SSH**. It’s ideal for automated offsite backups or syncing NAS directories efficiently with strict bandwidth control.

## Features

- 🕵️‍♂️ Watches for file changes natively using filesystem events.
- 🚀 Transfers files in batches via high-performance native SFTP.
- 🔐 Ultra-secure, shell-free Docker image (Google Distroless Static, under ~3MB!).
- 🌐 Configurable bandwidth limit natively built into the transfer engine.
- 🧹 Automatically removes source files after successful transfer.
- 🛡️ **Collision Handling**: Automatically detects if a remote file already exists and appends a timestamp (e.g., `file_20260710_115000.txt`) to prevent accidental overwrites.
- ⏰ Full timezone support for logs (just set the `TZ` environment variable).

## Environment Variables

| Variable | Description | Required | Default |
|-----------|-------------|-----------|----------|
| `REMOTE_DEST` | Remote SFTP destination (`user@hostname:/data/backup`). | ✅ | — |
| `SSH_PORT` | Remote server's SSH port | ❌ | `222` |
| `BWLIMIT_KB` | Bandwidth limit in KB/s | ❌ | `9375` |
| `SYNC_INTERVAL` | Interval between sync checks (seconds) | ❌ | `10` |
| `TZ` | Container timezone (e.g., `Australia/Melbourne`) for logs | ❌ | `UTC` |

## Docker Compose Example

```yaml
version: '3.8'
services:
  transfer-watcher:
    image: ghcr.io/buzzmoody/transfer-watcher:latest
    container_name: watcher
    restart: always
    environment:
      - REMOTE_DEST=user@hostname:/data/backup
      - SSH_PORT=222
      - BWLIMIT_KB=9375
      - SYNC_INTERVAL=10
      - TZ=Australia/Melbourne
    volumes:
      # the local directory you want to transfer files from
      - /path/to/local/source:/transfer
      # your SSH private key to the remote server
      - /path/to/ssh/key/id_rsa:/root/.ssh/id_rsa:ro
```

## Install from the command line

```console
docker pull ghcr.io/buzzmoody/transfer-watcher:latest
```
---

**License:** MIT  
**Author:** Buzz Moody  
