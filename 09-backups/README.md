# 09 — Backups

## Strategy

| What | Where | How Often | Retention |
|------|-------|-----------|-----------|
| All LXC containers | 2 TB SSD (`/mnt/data/backups`) | Nightly 2 AM | 3 copies |
| `/mnt/data` (your actual data) | External drive (manual) | Weekly | Keep all |

**Philosophy:** Containers are cheap to rebuild — but your data (media, notes, workflows, bookmarks) is irreplaceable. The nightly container backups let you restore a broken service in minutes. The weekly data backup is your disaster recovery.

---

## Part 1 — Automated Container Backups (Proxmox Built-in)

Proxmox has native backup scheduling. It stops each container briefly, snapshots it, and saves a compressed archive.

### 1a — Add Backup Storage

The backup target must be registered in Proxmox:

```bash
# The 2TB SSD is already mounted at /mnt/data
# Add the backups subfolder as a Proxmox backup store
pvesm add dir backups --path /mnt/data/backups --content backup
```

Or via web UI: Datacenter → Storage → Add → Directory → path `/mnt/data/backups`, content: VZDump backup file.

### 1b — Create Backup Schedule

Via web UI:

1. Datacenter → Backup → Add
2. Settings:

| Field | Value |
|-------|-------|
| Storage | `backups` |
| Schedule | `0 2 * * *` (2 AM every day) |
| Mode | `Snapshot` |
| Compress | `zstd` |
| VMs/CTs | Select all (100, 101, 102, 103, 104, 105, 106, 107) |
| Max Backups | `3` |
| Send email | your email |

3. Save

The job will run at 2 AM nightly. You'll get an email summary. Each container backup is roughly 200–800 MB compressed.

### 1c — Test a Backup Now

```bash
# Run a manual backup of CT103 (n8n) to test
vzdump 103 --storage backups --compress zstd --mode snapshot
# Check the result
ls -lh /mnt/data/backups/dump/
```

### 1d — Test a Restore

Practice restoring before you need to:

```bash
# List available backups
ls /mnt/data/backups/dump/

# Restore CT103 from a backup (replace filename with actual)
pct restore 103 /mnt/data/backups/dump/vzdump-lxc-103-*.tar.zst \
  --storage local-lvm \
  --force
```

---

## Part 2 — Data Backup (Your Files)

Container backups include the container OS + config, but **not the bind-mounted 2 TB SSD data** (that's the point — the data lives independently). Back up `/mnt/data` separately.

### Option A — External USB Drive (Recommended for most people)

```bash
# Plug in an external drive, identify it
lsblk
# Example: /dev/sdb

# Format it (once)
mkfs.ext4 /dev/sdb1
mkdir -p /mnt/external

# Mount it
mount /dev/sdb1 /mnt/external

# Sync your data (rsync — only copies changes)
rsync -av --progress --delete \
  /mnt/data/samba/ /mnt/external/samba/

rsync -av --progress --delete \
  /mnt/data/n8n/ /mnt/external/n8n/

rsync -av --progress --delete \
  /mnt/data/obsidian/ /mnt/external/obsidian/

rsync -av --progress --delete \
  /mnt/data/karakeep/ /mnt/external/karakeep/

# Unmount safely when done
umount /mnt/external
```

> Media files (movies, TV) are large and usually re-downloadable — decide for yourself if they need backing up.

### Option B — Automate with a Weekly Script

```bash
cat > /usr/local/bin/abena-backup.sh << 'SCRIPT'
#!/bin/bash
# Weekly data backup to external drive
# Plug in the drive before running, or set it up in /etc/fstab

EXTERNAL="/mnt/external"
DATA="/mnt/data"
LOG="/var/log/abena-backup.log"

echo "=== Abena backup started $(date) ===" >> "$LOG"

# Mount external (adjust device as needed)
mount /dev/sdb1 "$EXTERNAL" 2>> "$LOG"

if ! mountpoint -q "$EXTERNAL"; then
  echo "ERROR: External drive not mounted. Aborting." >> "$LOG"
  exit 1
fi

for dir in samba n8n obsidian karakeep; do
  echo "Syncing $dir..." >> "$LOG"
  rsync -a --delete "$DATA/$dir/" "$EXTERNAL/$dir/" >> "$LOG" 2>&1
done

echo "Backup complete $(date)" >> "$LOG"
umount "$EXTERNAL"
SCRIPT

chmod +x /usr/local/bin/abena-backup.sh

# Add to cron (runs every Sunday at 3 AM)
echo "0 3 * * 0 root /usr/local/bin/abena-backup.sh" > /etc/cron.d/abena-backup
```

---

## Part 3 — Restore Procedures

### Restore a Container from Backup

```bash
# Stop the broken container
pct stop <ID>

# Restore it (--force overwrites existing)
pct restore <ID> /mnt/data/backups/dump/vzdump-lxc-<ID>-<date>.tar.zst \
  --storage local-lvm \
  --force

# Start it back up
pct start <ID>
```

### Restore Data Files

```bash
# From external drive
mount /dev/sdb1 /mnt/external
rsync -av /mnt/external/n8n/ /mnt/data/n8n/
umount /mnt/external
```

### Nuclear Option — Full Server Rebuild

If the NVMe dies:

1. Reinstall Proxmox on a new NVMe (Step 00)
2. Recreate the network bridges (Step 01)
3. Restore containers from external drive backups:
   ```bash
   pct restore 101 /path/to/backup.tar.zst --storage local-lvm
   ```
4. Your data on the 2 TB SSD is completely untouched — just re-bind-mount it

This is why the separation of OS/config (NVMe) and data (SSD) matters.

---

## Backup Verification Checklist (Run Monthly)

```bash
# 1. Check last backup ran successfully
ls -lt /mnt/data/backups/dump/ | head -20

# 2. Check backup sizes look reasonable (not suspiciously small)
du -sh /mnt/data/backups/dump/*

# 3. Verify a container backup integrity
zstd -t /mnt/data/backups/dump/vzdump-lxc-103-*.tar.zst

# 4. Check backup storage space
df -h /mnt/data
```

---

## Checkpoint

- [ ] Proxmox backup job scheduled (nightly, all containers)
- [ ] First automated backup completed successfully
- [ ] Manual restore tested on at least one container
- [ ] External drive backup script working
- [ ] Calendar reminder set for monthly backup verification

---

## 🎉 Setup Complete

Your Abena server is fully operational. Here's your service summary:

| Service | Access (LAN) | Access (Remote via Netbird) |
|---------|-------------|---------------------------|
| Proxmox UI | `https://<proxmox-ip>:8006` | `https://10.10.10.254:8006` |
| Samba | `\\<samba-lan-ip>` | Not needed (use Netbird LAN) |
| Jellyfin | `http://<media-ip>:8096` | `http://10.10.10.12:8096` |
| n8n | `http://<n8n-ip>:5678` | `http://10.10.10.13:5678` |
| Obsidian Sync | `http://<obsidian-ip>:5984` | `http://10.10.10.14:5984` |
| Karakeep | `http://<karakeep-ip>:3000` | `http://10.10.10.15:3000` |
| Watchdog | `http://<watchdog-ip>:3001` | `http://10.10.10.17:3001` |
