# 🚀 transfer-watcher-rsync

The **transfer-watcher-rsync** project is a robust, lightweight solution for monitoring a local directory for file changes and efficiently transferring new or modified files to a remote destination (via SSH/rsync) in manageable batches. It's designed to be run as a **Docker container**, making deployment simple and isolated.

---

## ✨ Features

- **Real-time Monitoring:** Uses `inotify-tools` to monitor the source directory for `close_write` and `moved_to` events.
- **Batch Transfer:** Collects file changes over a configurable interval and transfers them in a single `rsync` batch.
- **Source Removal:** Configured with the `--remove-source-files` flag, effectively moving the files from the source directory upon successful transfer.
- **Bandwidth Limiting:** Transfers are limited using `rsync`’s built-in bandwidth throttling for controlled usage.
- **Secure:** Transfers utilize `rsync` over SSH with a specified private key.
- **Lightweight:** Built on a minimal Alpine Linux base.

---

## 🛠️ Usage with Docker Compose

The easiest way to run this watcher is using **Docker Compose**.

### 1. Project Structure

Ensure you have the following files in your project directory:

.
├── transfer_watcher.sh
├── Dockerfile
└── docker-compose.yml  <-- We will create this

---

### 2. Configure Your SSH Key

The script requires an SSH private key to connect to the remote server.

- Place your private key file in the root directory of your project, or in a secure location that can be volume-mounted.
- The script expects the key at: `/root/.ssh/id_rsa_nas_backup` inside the container.

---

### 3. Create `docker-compose.yml`

Create a `docker-compose.yml` file with your configuration:

version: '3.8'

services:
  file_watcher:
    build: .
    container_name: transfer_watcher
    restart: unless-stopped
    environment:
      # --- REQUIRED VARIABLES ---
      # The local directory *inside the container* that is monitored.
      # Must be the same path as the source volume mount.
      SOURCE_DIR: "/data/transfer" 
      
      # The remote destination in rsync format: [user]@[host]:/[path]
      REMOTE_DEST: "backup_user@my.remote.server.com:/mnt/nas/incoming_data"

      # --- OPTIONAL VARIABLES ---
      # Bandwidth limit in KB/s (default is 9375 KB/s ≈ 75 Mbit/s)
      BWLIMIT_KB: 9375
      
      # Time between sync attempts in seconds (default is 10s)
      SYNC_INTERVAL: 10

    volumes:
      # 1. Mount the local directory to be monitored (e.g., /home/user/files_to_send) 
      #    to the SOURCE_DIR inside the container (/data/transfer).
      - /home/user/files_to_send:/data/transfer:ro

      # 2. Mount your SSH private key to the path the script expects.
      #    (SSH_KEY: /root/.ssh/id_rsa_nas_backup)
      - ./id_rsa_nas_backup:/root/.ssh/id_rsa_nas_backup:ro

---

### 4. Run the Watcher

Build the image:

docker compose build

Start the container:

docker compose up -d

Check the logs to ensure it's running correctly:

docker logs transfer_watcher -f

---

### 5. Transferring Files

Place files into your local monitored directory (e.g., `/home/user/files_to_send`).

The watcher will automatically:
1. Detect the new file.
2. Wait for the `SYNC_INTERVAL` (10 seconds by default).
3. Execute an `rsync` transfer batch to the `REMOTE_DEST`.
4. Remove the file from the local directory if the transfer is successful.

---

## ⚙️ Configuration

The watcher is configured using **environment variables** set in the `docker-compose.yml` file:

| Variable       | Description                                                        | Default               | Mandatory |
|----------------|--------------------------------------------------------------------|-----------------------|-----------|
| `SOURCE_DIR`   | The full path inside the container to the directory to monitor.    | None                  | ✅ Yes    |
| `REMOTE_DEST`  | The remote rsync destination (`user@host:/path`).                  | None                  | ✅ Yes    |
| `BWLIMIT_KB`   | The maximum transfer speed in KB/s.                                | 9375 (≈75 Mbit/s)     | ❌ No     |
| `SYNC_INTERVAL`| The time in seconds between sync attempts.                         | 10                    | ❌ No     |

---
