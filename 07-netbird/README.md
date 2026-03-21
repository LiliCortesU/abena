# 07 — Netbird VPN (CT106)

## Why Netbird?

Netbird is a WireGuard-based peer-to-peer VPN. When you're away from home, your phone or laptop connects to the Netbird network and gets direct (or relayed) access to all your server services — as if you were on your LAN.

**Why it's safe and robust:**
- Uses WireGuard (battle-tested cryptography, minimal attack surface)
- Peer-to-peer when possible — no traffic flows through a third-party server except the initial handshake
- Even if the Netbird coordination server goes down, already-connected peers stay connected
- No open ports required on your router
- Free tier is generous for personal use (up to 5 peers)
- The Netbird client container routes traffic into your internal `vmbr1` network, making all internal services reachable remotely

---

## Architecture

```
Phone (outside) ──► Netbird STUN/relay ──► CT106 (netbird client)
                                                    │
                                               vmbr1 (internal)
                                                    │
                                    All other containers accessible
```

---

## Step 1 — Create a Netbird Account

1. Go to https://app.netbird.io and create a free account
2. You'll land on the Netbird dashboard — this is the control plane
3. No credit card needed for personal use

---

## Step 2 — Get a Setup Key

In the Netbird dashboard:

1. Go to **Setup Keys** → **Create Setup Key**
2. Name it `abena-server`
3. Type: **Reusable** (so you can add more peers later)
4. Copy the key — you'll need it in Step 4

---

## Step 3 — Create CT106

```bash
# ⚠️ Template version disclaimer: Debian template filenames change with each point release.
# Before running this, check the current name with:
#   pveam available --section system | grep debian-12
# Replace the template name below with whatever that command returns.

pct create 106 local:vztmpl/debian-12-standard_12.12-1_amd64.tar.zst \
  --hostname netbird \
  --memory 512 \
  --net0 name=eth0,bridge=vmbr0,ip=dhcp \
  --net1 name=eth1,bridge=vmbr1,ip=dhcp \
  --rootfs local-lvm:4 \
  --unprivileged 0 \
  --features tun=1,nesting=1 \
  --onboot 1 \
  --start 1
```

> `--features tun=1` is required for WireGuard/TUN interface support. `nesting=1` is required for systemd to run correctly in a privileged Debian container (suppresses the `Systemd 252 detected` warning). Both are needed here.

---

## Step 4 — Configure apt

The internal `vmbr1` bridge cannot reach external servers directly due to router restrictions. The solution is routing all apt traffic through `apt-cacher-ng` running on the Proxmox host, which has unrestricted internet access.

**One-time setup on the Proxmox host** (skip if already done for a previous container):

```bash
apt install -y apt-cacher-ng
systemctl enable --now apt-cacher-ng
ss -tlnp | grep 3142   # Should show apt-cacher-ng listening

# Allow containers to reach the proxy
iptables -A INPUT -i vmbr1 -p tcp --dport 3142 -j ACCEPT
netfilter-persistent save
```

**Inside CT106** — rewrite `sources.list` to route through the proxy directly:

```bash
pct enter 106

cat > /etc/apt/sources.list << 'EOF'
deb http://10.10.10.254:3142/deb.debian.org/debian bookworm main contrib non-free non-free-firmware
deb http://10.10.10.254:3142/deb.debian.org/debian bookworm-updates main contrib non-free non-free-firmware
deb http://10.10.10.254:3142/security.debian.org/debian-security bookworm-security main contrib non-free non-free-firmware
EOF
apt update
```

> This embeds the proxy address directly in the mirror URLs — the most reliable method. All package downloads go to `10.10.10.254:3142` which fetches them on behalf of the container using the host's unrestricted internet connection.

---

## Step 5 — Install Netbird Client

```bash
pct enter 106
```

```bash
# On Proxmox host — fetch Netbird install script and pipe into container
curl -fsSL https://pkgs.netbird.io/install.sh | pct exec 106 -- sh

# Authenticate with your setup key (replace with your actual key)
pct exec 106 -- netbird up --setup-key YOUR_SETUP_KEY_HERE --management-url https://api.netbird.io

# Verify connection
pct exec 106 -- netbird status
# Should show "Connected" and display your Netbird IP (100.x.x.x range)
```

Note the **Netbird IP** assigned to this peer — it's in the `100.64.x.x` range. This is the IP your devices will use to reach the server.

---

## Step 6 — Enable IP Routing (Route LAN Traffic Through VPN)

The key step: configure CT106 to route traffic from your Netbird devices into the internal network:

```bash
# Enable IP forwarding inside the container
echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
sysctl -p

# Add NAT so Netbird clients can reach internal vmbr1 containers
# wt0 is the Netbird WireGuard interface
iptables -t nat -A POSTROUTING -s '100.64.0.0/10' -o eth1 -j MASQUERADE
iptables -A FORWARD -i wt0 -o eth1 -j ACCEPT
iptables -A FORWARD -i eth1 -o wt0 -m state --state RELATED,ESTABLISHED -j ACCEPT

# Persist iptables rules
apt install -y iptables-persistent
netfilter-persistent save

exit
```

---

## Step 7 — Add Netbird Route in Dashboard

In the Netbird dashboard:

1. Go to **Network Routes** → **Add Route**
2. Network: `10.10.10.0/24`
3. Routing Peer: select `abena-server` (the peer you just added)
4. Save

This tells all your Netbird devices that traffic to `10.10.10.0/24` should go through the Abena server.

---

## Step 8 — Connect Your Devices

On each device (phone, laptop, etc.):

1. Install the Netbird client:
   - [Android](https://play.google.com/store/apps/details?id=io.netbird.client)
   - [iOS](https://apps.apple.com/app/netbird/id6463042989)
   - [Windows/macOS/Linux](https://netbird.io/download)

2. Log in with your Netbird account (same account you created in Step 1)

3. Your device will automatically join the network and the route to `10.10.10.0/24` will be applied

---

## Step 9 — Test Remote Access

With Netbird connected on your phone (ideally on mobile data, not WiFi, to simulate remote):

```
Obsidian LiveSync: http://10.10.10.14:5984
n8n:              http://10.10.10.13:5678
Jellyfin:         http://10.10.10.12:8096
Karakeep:         http://10.10.10.15:3000
Watchdog:         http://10.10.10.17:3001
```

---

## Step 10 — Make Netbird Persistent

```bash
pct enter 106

# Enable netbird service to start on boot
systemctl enable netbird
systemctl status netbird  # Should be active

exit
```

---

## Security Notes

- Your router has **zero new open ports** — Netbird uses outbound connections only
- The Netbird coordination server only handles key exchange — your actual traffic is encrypted peer-to-peer
- If you lose your Netbird account, regenerate setup keys from the dashboard — your WireGuard keys are on the device
- You can revoke any peer instantly from the Netbird dashboard

---

## Checkpoint

- [ ] Netbird account created
- [ ] CT106 running and connected (`netbird status` shows Connected)
- [ ] Network route `10.10.10.0/24` added in dashboard
- [ ] At least one remote device connected
- [ ] Can reach internal services by their `10.10.10.x` IPs from a remote device

**Next:** [08 — Watchdog Monitoring](../08-watchdog/README.md)
