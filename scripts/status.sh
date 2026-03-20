#!/bin/bash
# scripts/status.sh
# Run from Proxmox host to get a quick status of all Abena containers

echo "=== Abena Container Status ==="
echo ""
printf "%-6s %-15s %-10s %-20s\n" "ID" "Name" "Status" "Internal IP"
echo "------------------------------------------------------"

for id in 100 101 102 103 104 105 106 107; do
  name=$(pct config $id 2>/dev/null | grep '^hostname:' | awk '{print $2}')
  status=$(pct status $id 2>/dev/null | awk '{print $2}')
  ip=$(pct exec $id -- ip -4 addr show eth1 2>/dev/null | grep inet | awk '{print $2}' | cut -d/ -f1)
  [ -z "$ip" ] && ip=$(pct exec $id -- ip -4 addr show eth0 2>/dev/null | grep inet | awk '{print $2}' | cut -d/ -f1)
  printf "%-6s %-15s %-10s %-20s\n" "CT${id}" "${name:-unknown}" "${status:-unknown}" "${ip:-n/a}"
done

echo ""
echo "=== Data Disk Usage ==="
df -h /mnt/data | tail -1 | awk '{print "Used: " $3 " / " $2 " (" $5 " full)"}'

echo ""
echo "=== Recent Backups ==="
ls -t /mnt/data/backups/dump/*.tar.zst 2>/dev/null | head -5 | while read f; do
  echo "  $(basename $f) ($(du -sh $f | cut -f1))"
done
