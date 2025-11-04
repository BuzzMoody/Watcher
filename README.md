# Transfer Watcher

**Transfer Watcher** is a lightweight containerized tool that monitors a local directory for file changes and automatically transfers new or modified files to a remote host via `rsync` over SSH. It’s ideal for automated offsite backups or syncing NAS directories efficiently with bandwidth control.

## Features

- 🕵️‍♂️ Watches for file changes using `inotifywait`
- 🚀 Transfers files in batches using `rsync`
- 🔐 Uses SSH key authentication for secure transfers
- 🌐 Configurable bandwidth limit via environment variable
- 🧹 Automatically removes source files after successful transfer

## Environment Variables

| Variable | Description | Required | Default |
|-----------|-------------|-----------|----------|
| `REMOTE_DEST` | Remote rsync destination (`user@host:/path`). It's better to use an IP instead of a hostname if possible. | ✅ | — |
| `SSH_PORT` | Remote server's SSH port | ❌ | `222` |
| `BWLIMIT_KB` | Bandwidth limit in KB/s | ❌ | `9375` |
| `SYNC_INTERVAL` | Interval between sync checks (seconds) | ❌ | `10` |

## Docker Compose Example

```yaml
version: '3.8'
services:
  rsync-watcher:
    image: ghcr.io/buzzmoody/transfer-watcher:latest
    container_name: watcher
    restart: always
    environment:
      - REMOTE_DEST=user@remotehost:/data/backup
	  - SSH_PORT=222
      - BWLIMIT_KB=9375
      - SYNC_INTERVAL=10
    volumes:
	  # the local directory you want to transfer files from
      - /path/to/local/source:/transfer
	  # your ssh private key to the remote server
      - /path/to/ssh/key/id_rsa:/root/.ssh/id_rsa:ro
```

## Install from the command line

```console
docker pull ghcr.io/buzzmoody/transfer-watcher:latest
```
---

**License:** MIT  
**Author:** Buzz Moody  
