# 01 — Networking: Internal Bridge & Stable IPs

## The Problem
Your router uses DHCP without static allocation. Containers need predictable IPs to talk to each other reliably. Hardcoding LAN IPs would break if the router ever changes assignments.

## The Solution
Create a **second internal-only network bridge** (`vmbr1`) that lives entirely inside Proxmox. A lightweight `dnsmasq` container (CT100) acts as the DHCP server on this bridge and assigns **fixed IPs to all containers based on their MAC addresses**. These IPs are always stable — your router has no say in them.

```
Internet → Router → [LAN: 192.168.x.x] → Proxmox host (vmbr0)
                                                  │
                                              vmbr1 (internal)
                                           10.10.10.0/24
                                                  │
                    ┌─────────────────────────────┤
                    │            │        │        │
               CT100         CT101    CT102    CT103...
              gateway        samba    media     n8n
             10.10.10.1    .11      .12       .13
```

---

## Step 1 — Create the Internal Bridge (vmbr1)

On the Proxmox host shell:

```bash
# Add vmbr1 to network config
cat >> /etc/network/interfaces << 'EOF'

auto vmbr1
iface vmbr1 inet static
    address 10.10.10.254/24
    bridge-ports none
    bridge-stp off
    bridge-fd 0
    # Internal-only bridge — no physical port attached
EOF

# Apply without reboot
ifreload -a
```

Verify it's up:
```bash
ip addr show vmbr1
# Should show 10.10.10.254/24
```

---

## Step 2 — Enable IP Forwarding & NAT

Containers on `vmbr1` need internet access (for package installs, updates, etc.):

```bash
# Enable IP forwarding permanently
# Using a dedicated drop-in file — more reliable than editing sysctl.conf
# which may not contain this line depending on the Proxmox version
echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-ip-forward.conf
sysctl -p /etc/sysctl.d/99-ip-forward.conf

# Verify
sysctl net.ipv4.ip_forward
# Must show: net.ipv4.ip_forward = 1

# NAT: masquerade internal traffic through vmbr0 (your LAN interface)
# Find your LAN interface name first:
ip route | grep default
# Example output: default via 192.168.1.1 dev vmbr0 ...
# Your LAN interface is likely "vmbr0" or "enp3s0" — use whatever appears after "dev"

# Add NAT rule (replace vmbr0 if your LAN interface differs)
iptables -t nat -A POSTROUTING -s '10.10.10.0/24' -o vmbr0 -j MASQUERADE

# Make it persist across reboots
apt install -y iptables-persistent
netfilter-persistent save
```

---

## Step 3 — Create CT100 (Gateway / dnsmasq)

In the Proxmox web UI, or via shell:

```bash
# ⚠️ Template version disclaimer: Alpine template filenames change with each release.
# Before running this, check the current name with:
#   pveam available --section system | grep alpine
# Replace the template name below with whatever that command returns.

pct create 100 local:vztmpl/alpine-3.21-default_20241217_amd64.tar.xz \
  --hostname gateway \
  --memory 256 \
  --net0 name=eth0,bridge=vmbr1,ip=10.10.10.1/24,gw=10.10.10.254 \
  --rootfs local-lvm:2 \
  --unprivileged 1 \
  --start 1 \
  --onboot 1
```

> `--onboot 1` means this container starts automatically when Proxmox boots. **All containers should have this set.**

---

## Step 4 — Configure dnsmasq Inside CT100

Enter the container:
```bash
pct enter 100
```

Inside CT100:
```bash
apk update && apk add dnsmasq

# Write the dnsmasq config
cat > /etc/dnsmasq.conf << 'EOF'
# Listen only on the internal bridge
interface=eth0
bind-interfaces

# DHCP range (for any unlisted containers — shouldn't be needed)
dhcp-range=10.10.10.100,10.10.10.200,12h

# Fixed IP assignments by MAC address
# Format: dhcp-host=<MAC>,<IP>,<hostname>
# MACs will be filled in after containers are created (see note below)
dhcp-host=BC:24:11:00:01:01,10.10.10.11,samba
dhcp-host=BC:24:11:00:01:02,10.10.10.12,media
dhcp-host=BC:24:11:00:01:03,10.10.10.13,n8n
dhcp-host=BC:24:11:00:01:04,10.10.10.14,obsidian
dhcp-host=BC:24:11:00:01:05,10.10.10.15,karakeep
dhcp-host=BC:24:11:00:01:06,10.10.10.16,netbird
dhcp-host=BC:24:11:00:01:07,10.10.10.17,watchdog

# Local DNS — containers resolve each other by name
address=/samba.local/10.10.10.11
address=/media.local/10.10.10.12
address=/n8n.local/10.10.10.13
address=/obsidian.local/10.10.10.14
address=/karakeep.local/10.10.10.15
address=/netbird.local/10.10.10.16
address=/watchdog.local/10.10.10.17

# Upstream DNS
server=1.1.1.1
server=8.8.8.8

# Default gateway — must point to Proxmox host (10.10.10.254) so traffic
# reaches Squid for internet access. Do NOT use 10.10.10.1 (dnsmasq itself).
dhcp-option=3,10.10.10.254

domain=local
expand-hosts
EOF

# Enable and start
rc-update add dnsmasq default
rc-service dnsmasq start

exit
```

> **Note on MACs:** When you create each container in the following steps, Proxmox auto-generates a MAC address. After creating all containers, run `pct config <ID> | grep hwaddr` to get each container's actual MAC and update the `dhcp-host=` lines above, then `rc-service dnsmasq restart` inside CT100.

---

## Step 5 — Verify Internal Networking

From Proxmox host:
```bash
# Ping the gateway container
ping 10.10.10.1

# Check dnsmasq is running inside CT100
pct exec 100 -- rc-service dnsmasq status
```

---

## MAC Address Update Script

After all containers are created, run this from the Proxmox host to get all MACs at once:

```bash
for id in 101 102 103 104 105 106 107; do
  echo "CT${id}: $(pct config $id | grep 'hwaddr' | head -1)"
done
```

Update the `dhcp-host=` lines in CT100's `/etc/dnsmasq.conf` with the real MACs, then restart dnsmasq.

---

## Checkpoint

- [ ] `vmbr1` bridge is up with IP `10.10.10.254`
- [ ] IP forwarding enabled
- [ ] NAT rule active and persisted
- [ ] CT100 (gateway) running with dnsmasq
- [ ] Containers can ping `10.10.10.1` from their `vmbr1` interface

**Next:** [01b — Squid Transparent Proxy](../01b-squid-proxy/README.md)

> ⚠️ Do not skip 01b. The router blocks most outbound traffic from containers — Squid fixes this permanently before you set up any services.
