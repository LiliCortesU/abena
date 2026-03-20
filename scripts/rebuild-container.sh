#!/bin/bash
# scripts/rebuild-container.sh
# Restores a container from its latest backup
# Usage: ./rebuild-container.sh <CT_ID>
# Example: ./rebuild-container.sh 103

set -e

ID="$1"
BACKUP_DIR="/mnt/data/backups/dump"

if [ -z "$ID" ]; then
  echo "Usage: $0 <container-id>"
  echo "Example: $0 103"
  exit 1
fi

# Find latest backup for this container
BACKUP=$(ls -t "${BACKUP_DIR}/vzdump-lxc-${ID}-"*.tar.zst 2>/dev/null | head -1)

if [ -z "$BACKUP" ]; then
  echo "ERROR: No backup found for CT${ID} in ${BACKUP_DIR}"
  exit 1
fi

echo "=== Rebuilding CT${ID} from backup ==="
echo "Backup file: $BACKUP"
echo ""
read -p "This will STOP and OVERWRITE CT${ID}. Continue? (yes/no): " confirm

if [ "$confirm" != "yes" ]; then
  echo "Aborted."
  exit 0
fi

echo "Stopping CT${ID}..."
pct stop "$ID" 2>/dev/null || true

echo "Restoring from backup..."
pct restore "$ID" "$BACKUP" --storage local-lvm --force

echo "Starting CT${ID}..."
pct start "$ID"

sleep 3
echo ""
echo "CT${ID} status: $(pct status $ID)"
echo ""
echo "Done. Remember to verify bind mounts are correct:"
pct config "$ID" | grep mp
