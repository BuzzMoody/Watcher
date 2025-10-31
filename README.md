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
| `SOURCE_DIR` | Local directory to monitor for changes | ✅ | — |
| `REMOTE_DEST` | Remote rsync destination (`user@host:/path`) | ✅ | — |
| `BWLIMIT_KB` | Bandwidth limit in KB/s | ❌ | `9375` |
| `SYNC_INTERVAL` | Interval between sync checks (seconds) | ❌ | `10` |

## Docker Compose Example

```yaml
version: "3.9"
services:
  transfer-watcher:
    build: .
    container_name: transfer-watcher
    environment:
      - SOURCE_DIR=/data/source
      - REMOTE_DEST=user@remotehost:/data/backup
      - BWLIMIT_KB=9375
      - SYNC_INTERVAL=10
    volumes:
      - /path/to/local/source:/data/source
      - /path/to/ssh/key/id_rsa_nas_backup:/root/.ssh/id_rsa_nas_backup:ro
    restart: unless-stopped
```

---

**License:** MIT  
**Author:** Buzz Moody  
