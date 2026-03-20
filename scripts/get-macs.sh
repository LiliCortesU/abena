#!/bin/bash
# scripts/get-macs.sh
# Run from Proxmox host AFTER creating all containers
# Outputs dnsmasq dhcp-host lines ready to paste into CT100's /etc/dnsmasq.conf

echo "# Paste these lines into /etc/dnsmasq.conf inside CT100"
echo "# Then run: rc-service dnsmasq restart"
echo ""

declare -A names=(
  [101]="samba"
  [102]="media"
  [103]="n8n"
  [104]="obsidian"
  [105]="karakeep"
  [106]="netbird"
  [107]="watchdog"
)

declare -A ips=(
  [101]="10.10.10.11"
  [102]="10.10.10.12"
  [103]="10.10.10.13"
  [104]="10.10.10.14"
  [105]="10.10.10.15"
  [106]="10.10.10.16"
  [107]="10.10.10.17"
)

for id in 101 102 103 104 105 106 107; do
  # Get the vmbr1 interface MAC (net1 for dual-homed, net0 for internal-only)
  mac=$(pct config $id 2>/dev/null | grep 'net1' | grep -o 'hwaddr=[^,]*' | cut -d= -f2)
  [ -z "$mac" ] && mac=$(pct config $id 2>/dev/null | grep 'net0' | grep -o 'hwaddr=[^,]*' | cut -d= -f2)

  if [ -n "$mac" ]; then
    echo "dhcp-host=${mac,,},${ips[$id]},${names[$id]}"
  else
    echo "# CT${id}: could not read MAC (is container created?)"
  fi
done
