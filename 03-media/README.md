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
pct create 102 local:vztmpl/debian-12-standard_12.7-1_amd64.tar.zst \
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

## Step 2 — Bind-Mount Data Directories

```bash
pct stop 102

pct set 102 \
  --mp0 /mnt/data/media,mp=/mnt/media \
  --mp1 /mnt/data/downloads,mp=/mnt/downloads

pct start 102
```

---

## Step 3 — Install All Services

```bash
pct enter 102
```

### Base dependencies

```bash
apt update && apt install -y curl wget gnupg2 apt-transport-https \
  ca-certificates software-properties-common python3 python3-pip
```

### Jellyfin

```bash
curl -fsSL https://repo.jellyfin.org/install-debuntu.sh | bash
systemctl enable --now jellyfin
```

### qBittorrent

```bash
apt install -y qbittorrent-nox

# Create a dedicated user
useradd -r -s /sbin/nologin qbt

cat > /etc/systemd/system/qbittorrent.service << 'EOF'
[Unit]
Description=qBittorrent Web UI
After=network.target

[Service]
User=qbt
ExecStart=/usr/bin/qbittorrent-nox --webui-port=8080
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# Give qbt user access to download directories
chown -R qbt:qbt /mnt/downloads
chmod -R 775 /mnt/downloads

systemctl daemon-reload
systemctl enable --now qbittorrent
```

### Sonarr

```bash
apt-key adv --keyserver hkp://keyserver.ubuntu.com:80 --recv-keys 2009837CBFFD68F45BC180471F4F90DE2A9B4BF8
echo "deb https://apt.sonarr.tv/debian bookworm main" > /etc/apt/sources.list.d/sonarr.list
apt update && apt install -y sonarr
systemctl enable --now sonarr
```

### Radarr

```bash
wget -qO- https://raw.githubusercontent.com/Radarr/Radarr/develop/distribution/debian/install.sh | bash
```

### Prowlarr

```bash
wget -qO /tmp/prowlarr.tar.gz \
  "$(curl -s https://api.github.com/repos/Prowlarr/Prowlarr/releases/latest \
  | grep 'browser_download_url.*linux-x64.tar.gz' | cut -d '"' -f 4)"

tar -xzf /tmp/prowlarr.tar.gz -C /opt/
chown -R root:root /opt/Prowlarr

cat > /etc/systemd/system/prowlarr.service << 'EOF'
[Unit]
Description=Prowlarr
After=network.target

[Service]
ExecStart=/opt/Prowlarr/Prowlarr -nobrowser -data=/var/lib/prowlarr
Restart=always
RestartSec=5
User=root

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now prowlarr
```

```bash
exit
```

---

## Step 4 — Initial Configuration

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

## Step 5 — Remove Temporary LAN Interface

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
