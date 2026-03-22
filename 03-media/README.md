# 03 — Media Server (CT102)

## Stack
| App | Role | Port |
|-----|------|------|
| Jellyfin | Media frontend — watch movies & TV | 8096 |
| Sonarr | TV show tracking & auto-download | 8989 |
| Radarr | Movie tracking & auto-download | 7878 |
| Prowlarr | Indexer manager — feeds Sonarr & Radarr | 9696 |
| qBittorrent | Download client | 8080 |
| Bazarr | Subtitle automation — fetches subs for Sonarr & Radarr | 6767 |
| FlareSolverr | Cloudflare bypass proxy for protected indexers | 8191 |

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

Jellyfin's install script fetches a signing key from inside the container (blocked by router), and the apt-cacher-ng proxy runs out of memory trying to proxy the Jellyfin apt repo. The correct approach is to download all three `.deb` packages on the **Proxmox host** and install them with `apt` inside the container, which handles dependency resolution automatically.

```bash
# On Proxmox host — get current version and download all three debs
VERSION=$(curl -s https://api.github.com/repos/jellyfin/jellyfin/releases/latest \
  | grep '"tag_name"' | cut -d '"' -f 4 | tr -d 'v')
echo "Version: $VERSION"

curl -fsSL "https://repo.jellyfin.org/files/server/debian/latest-stable/amd64/jellyfin-server_${VERSION}+deb12_amd64.deb" \
  -o /tmp/jellyfin-server.deb

curl -fsSL "https://repo.jellyfin.org/files/server/debian/latest-stable/amd64/jellyfin-web_${VERSION}+deb12_all.deb" \
  -o /tmp/jellyfin-web.deb

FFMPEG_URL=$(curl -s https://api.github.com/repos/jellyfin/jellyfin-ffmpeg/releases/latest \
  | grep 'browser_download_url.*bookworm_amd64.deb' | cut -d '"' -f 4)
curl -fsSL "$FFMPEG_URL" -o /tmp/jellyfin-ffmpeg.deb

# Verify all three downloaded (should be 30-55 MB each)
ls -lh /tmp/jellyfin-server.deb /tmp/jellyfin-web.deb /tmp/jellyfin-ffmpeg.deb

# Push into CT102 and install
pct push 102 /tmp/jellyfin-server.deb /tmp/jellyfin-server.deb
pct push 102 /tmp/jellyfin-web.deb /tmp/jellyfin-web.deb
pct push 102 /tmp/jellyfin-ffmpeg.deb /tmp/jellyfin-ffmpeg.deb

pct exec 102 -- apt install -y \
  /tmp/jellyfin-server.deb \
  /tmp/jellyfin-web.deb \
  /tmp/jellyfin-ffmpeg.deb

# Verify — should show active (running) with ffmpeg path in logs
pct exec 102 -- systemctl status jellyfin --no-pager
```

> The deb install creates the `jellyfin` system user, systemd service, and ffmpeg path automatically — no manual configuration needed.

### qBittorrent

```bash
apt install -y qbittorrent-nox

# Create a shared media group — all download/media services run under this group
# so they can read each other's files without permission conflicts
groupadd media

# Create a dedicated user for qBittorrent with a home directory
# (qbittorrent-nox requires /home/qbt/.cache to exist)
useradd -r -m -s /sbin/nologin -G media qbt

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
# Create sonarr user and add to the media group (already created in qBittorrent step)
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

### Bazarr

Bazarr is Python-based. Debian 12 requires pip packages to be installed in a virtual environment.

```bash
# Inside CT102
apt install -y unzip python3-full

# Download and extract Bazarr (Squid proxies the request transparently)
curl -fsSL "$(curl -s https://api.github.com/repos/morpheus65535/bazarr/releases/latest \
  | grep 'browser_download_url.*bazarr.zip' | cut -d '"' -f 4)" -o /tmp/bazarr.zip
mkdir -p /opt/bazarr
unzip -q /tmp/bazarr.zip -d /opt/bazarr

# Create a venv and install dependencies into it
python3 -m venv /opt/bazarr/venv
/opt/bazarr/venv/bin/pip install -r /opt/bazarr/requirements.txt

# Create dedicated user and set permissions
useradd -r -s /sbin/nologin -G media bazarr
chown -R bazarr:media /opt/bazarr
mkdir -p /var/lib/bazarr
chown -R bazarr:media /var/lib/bazarr

# Create systemd service
cat > /etc/systemd/system/bazarr.service << 'EOF'
[Unit]
Description=Bazarr Subtitle Manager
After=syslog.target network.target sonarr.service radarr.service

[Service]
User=bazarr
Group=media
Type=simple
WorkingDirectory=/opt/bazarr
ExecStart=/opt/bazarr/venv/bin/python3 /opt/bazarr/bazarr.py --config /var/lib/bazarr/
TimeoutStopSec=20
KillMode=process
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now bazarr
systemctl status bazarr
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

### FlareSolverr

FlareSolverr is a proxy that bypasses Cloudflare protection on indexers. Some indexers in Prowlarr require it to function. It uses Chromium headlessly via a virtual display (Xvfb).

> **Note:** The pre-built FlareSolverr binary requires glibc 2.38, but Debian 12 (bookworm) ships glibc 2.36. Install from source instead — this is the confirmed working approach.

```bash
# Inside CT102
apt install -y python3 python3-pip chromium chromium-driver git xvfb

cd /opt
git clone https://github.com/FlareSolverr/FlareSolverr.git
cd FlareSolverr
pip3 install -r requirements.txt --break-system-packages

cat > /etc/systemd/system/flaresolverr.service << 'EOF'
[Unit]
Description=FlareSolverr
After=network.target

[Service]
ExecStart=/usr/bin/python3 /opt/FlareSolverr/src/flaresolverr.py
Restart=on-failure
Environment=LOG_LEVEL=info

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now flaresolverr

# Verify
curl -s http://localhost:8191/health
# Should return: {"status": "ok"}
```

---

## Step 5 — Initial Configuration

CT102 is internal-only (`vmbr1`). To access the web UIs from your browser you need to temporarily add a LAN interface. Run from the **Proxmox host**:

```bash
# Add temporary LAN interface
pct set 102 --net1 name=eth1,bridge=vmbr0,ip=dhcp

# Get the LAN IP — this is what you use in your browser
pct exec 102 -- dhclient eth1
pct exec 102 -- ip addr show eth1 | grep 'inet '
```

Use the IP shown (e.g. `192.168.0.x`) to access all services:

| Service | URL |
|---------|-----|
| Jellyfin | `http://<lan-ip>:8096` |
| qBittorrent | `http://<lan-ip>:8080` |
| Sonarr | `http://<lan-ip>:8989` |
| Radarr | `http://<lan-ip>:7878` |
| Prowlarr | `http://<lan-ip>:9696` |
| Bazarr | `http://<lan-ip>:6767` |
| FlareSolverr | `http://localhost:8191` (internal only) |

> ⚠️ The LAN IP changes every time you add the interface. Always run `pct exec 102 -- ip addr show eth1 | grep 'inet '` to get the current IP rather than assuming it's the same as last time.

> See **[APPENDIX-media-config.md](../APPENDIX-media-config.md)** for detailed configuration steps for each service.
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

### Bazarr Setup

1. Open Bazarr → Settings → Sonarr — enter `localhost` and the Sonarr API key, click Test & Save
2. Settings → Radarr — same for Radarr
3. Settings → Subtitles → add at least one provider (e.g. OpenSubtitles.com, Subscene)
4. Settings → Languages — enable your preferred subtitle languages

> See **[APPENDIX-media-config.md](../APPENDIX-media-config.md)** for detailed Bazarr configuration.

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

- [ ] All 7 services running (`systemctl status jellyfin sonarr radarr prowlarr qbittorrent bazarr flaresolverr`)
- [ ] qBittorrent pointing to correct download directories
- [ ] Prowlarr connected to at least one indexer
- [ ] Sonarr and Radarr connected to both Prowlarr and qBittorrent
- [ ] Bazarr connected to Sonarr and Radarr with at least one subtitle provider configured
- [ ] Jellyfin library populated with your media

**Next:** [04 — n8n](../04-n8n/README.md)
