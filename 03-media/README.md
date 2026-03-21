# 03 — Media Server (CT102)

## Stack
| App | Role | Port |
|-----|------|------|
| Jellyfin | Media frontend — watch movies & TV | 8096 |
| Sonarr | TV show tracking & auto-download | 8989 |
| Radarr | Movie tracking & auto-download | 7878 |
| Prowlarr | Indexer manager — feeds Sonarr & Radarr | 9696 |
| qBittorrent | Download client | 8080 |

All apps share a unified `/data` layout (TRaSH Guides standard), which lets Sonarr/Radarr use **hardlinks** instead of copying files — no wasted disk space.

```
/mnt/data/
├── media/
│   ├── movies/      ← Radarr moves here
│   ├── tv/          ← Sonarr moves here
│   └── music/
└── downloads/
    ├── incomplete/   ← qBittorrent active downloads
    └── complete/     ← qBittorrent finishes here → Sonarr/Radarr grab from here
```

---

## Step 1 — Create CT102

```bash
# ⚠️ Template version disclaimer: Debian template filenames change with each point release.
# Before running this, check the current name with:
#   pveam available --section system | grep debian-12
# Replace the template name below with whatever that command returns.

pct create 102 local:vztmpl/debian-12-standard_12.12-1_amd64.tar.zst \
  --hostname media \
  --memory 2048 \
  --net0 name=eth0,bridge=vmbr1,ip=dhcp \
  --rootfs local-lvm:8 \
  --unprivileged 0 \
  --features nesting=1 \
  --onboot 1 \
  --start 1
```

---

## Step 2 — Configure apt

The internal `vmbr1` bridge cannot reach external servers directly due to router restrictions. The solution is routing all apt traffic through `apt-cacher-ng` running on the Proxmox host, which has unrestricted internet access.

**One-time setup on the Proxmox host** (skip if already done for a previous container):

```bash
apt install -y apt-cacher-ng
systemctl enable --now apt-cacher-ng
ss -tlnp | grep 3142   # Should show apt-cacher-ng listening
```

**Allow containers to reach the proxy:**

```bash
iptables -A INPUT -i vmbr1 -p tcp --dport 3142 -j ACCEPT
netfilter-persistent save
```

**Inside the container** — rewrite `sources.list` to route through the proxy directly:

```bash
cat > /etc/apt/sources.list << 'EOF'
deb http://10.10.10.254:3142/deb.debian.org/debian bookworm main contrib non-free non-free-firmware
deb http://10.10.10.254:3142/deb.debian.org/debian bookworm-updates main contrib non-free non-free-firmware
deb http://10.10.10.254:3142/security.debian.org/debian-security bookworm-security main contrib non-free non-free-firmware
EOF
apt update
```

> This embeds the proxy address directly in the mirror URLs — the most reliable method. All package downloads go to `10.10.10.254:3142` which fetches them on behalf of the container using the host's unrestricted internet connection.

---

## apt-cacher-ng one-time setup

If not already done, run this once on the **Proxmox host** before setting up any container:

```bash
apt install -y apt-cacher-ng
systemctl enable --now apt-cacher-ng
ss -tlnp | grep 3142   # Verify it is listening
```

---

## Step 3 — Bind-Mount Data Directories

```bash
pct stop 102

pct set 102 \
  --mp0 /mnt/data/media,mp=/mnt/media \
  --mp1 /mnt/data/downloads,mp=/mnt/downloads

pct start 102
```

---

## Step 4 — Install All Services

```bash
pct enter 102
```

### Base dependencies

```bash
apt install -y curl wget gnupg apt-transport-https ca-certificates python3
```

### Jellyfin

Jellyfin's install script fetches from external URLs — run it from the **Proxmox host** and pipe into the container:

```bash
# Exit CT102 first, run on Proxmox host
exit
curl -fsSL https://repo.jellyfin.org/install-debuntu.sh | pct exec 102 -- bash
pct exec 102 -- systemctl enable --now jellyfin
pct enter 102
```

### qBittorrent

```bash
apt install -y qbittorrent-nox

# Create a shared media group — all download/media services run under this group
# so they can read each other's files without permission conflicts
groupadd media

# Create a dedicated user for qBittorrent, add to media group
useradd -r -s /sbin/nologin -G media qbt

cat > /etc/systemd/system/qbittorrent.service << 'EOF'
[Unit]
Description=qBittorrent Web UI
After=network.target

[Service]
User=qbt
Group=media
ExecStart=/usr/bin/qbittorrent-nox --webui-port=8080
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# Give the media group ownership of download directories
chown -R qbt:media /mnt/downloads
chmod -R 775 /mnt/downloads

systemctl daemon-reload
systemctl enable --now qbittorrent
```

### Sonarr

Sonarr's install script downloads its binary from inside the container, which gets blocked by the router. Download the binary on the **Proxmox host** and push it in:

```bash
# Create sonarr user and add to shared media group
pct exec 102 -- groupadd media
pct exec 102 -- useradd -r -s /sbin/nologin -G media sonarr

# Add qbt to the media group too (so sonarr can access qbt's downloads)
pct exec 102 -- usermod -aG media qbt

# Download Sonarr binary on the host
curl -fsSL "https://services.sonarr.tv/v1/download/main/latest?version=4&os=linux&arch=x64" \
  -o /tmp/sonarr.tar.gz

# Push into CT102 and extract
pct push 102 /tmp/sonarr.tar.gz /tmp/sonarr.tar.gz
pct exec 102 -- tar -xzf /tmp/sonarr.tar.gz -C /opt/
pct exec 102 -- chown -R sonarr:media /opt/Sonarr
pct exec 102 -- mkdir -p /var/lib/sonarr
pct exec 102 -- chown -R sonarr:media /var/lib/sonarr

# Create systemd service
pct exec 102 -- bash -c 'cat > /etc/systemd/system/sonarr.service << EOF
[Unit]
Description=Sonarr Daemon
After=syslog.target network.target

[Service]
User=sonarr
Group=media
Type=simple
ExecStart=/opt/Sonarr/Sonarr -nobrowser -data=/var/lib/sonarr/
TimeoutStopSec=20
KillMode=process
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF'

pct exec 102 -- systemctl daemon-reload
pct exec 102 -- systemctl enable --now sonarr
pct exec 102 -- systemctl status sonarr
```

### Radarr

Same approach as Sonarr — download on the host, push in:

```bash
# Download Radarr binary on the host
curl -fsSL "https://radarr.servarr.com/v1/update/master/updatefile?os=linux&runtime=netcore&arch=x64" \
  -o /tmp/radarr.tar.gz

# Push into CT102 and extract
pct push 102 /tmp/radarr.tar.gz /tmp/radarr.tar.gz
pct exec 102 -- tar -xzf /tmp/radarr.tar.gz -C /opt/
pct exec 102 -- chown -R sonarr:media /opt/Radarr
pct exec 102 -- mkdir -p /var/lib/radarr
pct exec 102 -- chown -R sonarr:media /var/lib/radarr

# Create systemd service
pct exec 102 -- bash -c 'cat > /etc/systemd/system/radarr.service << EOF
[Unit]
Description=Radarr Daemon
After=syslog.target network.target

[Service]
User=sonarr
Group=media
Type=simple
ExecStart=/opt/Radarr/Radarr -nobrowser -data=/var/lib/radarr/
TimeoutStopSec=20
KillMode=process
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF'

pct exec 102 -- systemctl daemon-reload
pct exec 102 -- systemctl enable --now radarr
pct exec 102 -- systemctl status radarr
```

### Prowlarr

```bash
# Get latest Prowlarr release and download on the host
PROWLARR_URL=$(curl -s https://api.github.com/repos/Prowlarr/Prowlarr/releases/latest \
  | grep 'browser_download_url.*linux-core-x64.tar.gz' | cut -d '"' -f 4)
curl -fsSL "$PROWLARR_URL" -o /tmp/prowlarr.tar.gz

# Push into CT102 and extract
pct push 102 /tmp/prowlarr.tar.gz /tmp/prowlarr.tar.gz
pct exec 102 -- tar -xzf /tmp/prowlarr.tar.gz -C /opt/
pct exec 102 -- chown -R sonarr:media /opt/Prowlarr
pct exec 102 -- mkdir -p /var/lib/prowlarr
pct exec 102 -- chown -R sonarr:media /var/lib/prowlarr

# Create systemd service
pct exec 102 -- bash -c 'cat > /etc/systemd/system/prowlarr.service << EOF
[Unit]
Description=Prowlarr Daemon
After=syslog.target network.target

[Service]
User=sonarr
Group=media
Type=simple
ExecStart=/opt/Prowlarr/Prowlarr -nobrowser -data=/var/lib/prowlarr/
TimeoutStopSec=20
KillMode=process
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF'

pct exec 102 -- systemctl daemon-reload
pct exec 102 -- systemctl enable --now prowlarr
pct exec 102 -- systemctl status prowlarr
```

---

## Step 5 — Initial Configuration

Access each service from your LAN. First, get the container's internal IP:

```bash
# From Proxmox host — but this container is on vmbr1 (internal only)
# Access via Proxmox host as a proxy, or add vmbr0 temporarily for setup
# Easier: access from another container on vmbr1, or use SSH tunnel

# Quick way: add a temporary LAN interface for initial setup
pct set 102 --net1 name=eth1,bridge=vmbr0,ip=dhcp
pct exec 102 -- ip addr show eth1 | grep 'inet '
```

Then visit:
- Jellyfin: `http://<media-ip>:8096`
- qBittorrent: `http://<media-ip>:8080` (default login: `admin` / `adminadmin` — **change immediately**)
- Sonarr: `http://<media-ip>:8989`
- Radarr: `http://<media-ip>:7878`
- Prowlarr: `http://<media-ip>:9696`

### qBittorrent Setup

1. Log in → Tools → Options → Downloads
2. Set "Default Save Path" to `/mnt/downloads/complete`
3. Set "Keep incomplete torrents in" to `/mnt/downloads/incomplete`
4. Options → Web UI → change username and password

### Prowlarr Setup

1. Open Prowlarr → Settings → General → note the API key
2. Add your preferred indexers (public trackers: 1337x, RARBG mirrors, YTS, etc.)

### Sonarr Setup

1. Settings → Media Management → Root Folders → add `/mnt/media/tv`
2. Settings → Download Clients → add qBittorrent:
   - Host: `10.10.10.12`, Port: `8080`
3. Settings → Apps (in Prowlarr) → add Sonarr with its API key

### Radarr Setup

1. Settings → Media Management → Root Folders → add `/mnt/media/movies`
2. Settings → Download Clients → add qBittorrent (same as above)
3. In Prowlarr → Settings → Apps → add Radarr with its API key

### Jellyfin Setup

1. Follow the first-run wizard
2. Add media libraries:
   - Movies → `/mnt/media/movies`
   - TV Shows → `/mnt/media/tv`
3. Let it scan and build the library

---

## Step 6 — Remove Temporary LAN Interface

Once configured, remove the temporary eth1 to keep the media container internal-only:

```bash
pct set 102 --delete net1
```

Access Jellyfin through Netbird (remote) or Samba (LAN). Alternatively, keep eth1 if you want to cast to local devices.

---

## Checkpoint

- [ ] All 5 services running (`systemctl status jellyfin sonarr radarr prowlarr qbittorrent`)
- [ ] qBittorrent pointing to correct download directories
- [ ] Prowlarr connected to at least one indexer
- [ ] Sonarr and Radarr connected to both Prowlarr and qBittorrent
- [ ] Jellyfin library populated with your media

**Next:** [04 — n8n](../04-n8n/README.md)
