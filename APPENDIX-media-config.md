# Appendix — Media Stack Configuration Guide

This guide covers the initial configuration of all five services in CT102 after installation. Follow this order — each service depends on the previous one being configured first.

> Access all services via the temporary LAN interface added during setup. The LAN IP changes each time you add the interface — always get the current one with:

> ```bash
> pct exec 102 -- ip addr show eth1 | grep 'inet '
> ```
> If eth1 is not present, add it first: `pct set 102 --net1 name=eth1,bridge=vmbr0,ip=dhcp && pct exec 102 -- dhclient eth1`

---

## 1. qBittorrent (port 8080)

qBittorrent is the download client. Configure it first since Sonarr and Radarr need to connect to it.

### First Login
- URL: `http://<media-ip>:8080`
- Default credentials: `admin` / `adminadmin`

### Change Password (required)
Tools → Options → Web UI → Authentication → set a strong password → Save

### Set Download Paths
Tools → Options → Downloads:

| Setting | Value |
|---------|-------|
| Default Save Path | `/mnt/downloads/complete` |
| Keep incomplete torrents in | `/mnt/downloads/incomplete` |
| Append `.!qB` extension to incomplete | ✅ Enabled |

### Network Settings (recommended)
Tools → Options → Connection:
- Set a random port for incoming connections (avoid 6881 — commonly blocked by ISPs)
- Enable UPnP/NAT-PMP: ✅

### Speed Limits (optional)
Tools → Options → Speed — set upload limits if you want to avoid saturating your connection.

---

## 2. Prowlarr (port 9696)

Prowlarr manages indexers and feeds them to Sonarr and Radarr automatically.

### Add Indexers
Indexers → Add Indexer → search for your preferred public trackers. Recommended starting points:
- **1337x** — general content
- **YTS** — movies (high quality small size)
- **EZTV** — TV shows
- **The Pirate Bay** — general

For each indexer: click the name → Test → Save.

### Get the API Key
Settings → General → Security → API Key — copy this, you'll need it when connecting Sonarr and Radarr.

### Connect to Sonarr and Radarr
Settings → Apps → Add Application:

> All three services run inside CT102, so use `localhost` here — `10.10.10.12` is only reachable after the internal vmbr1 interface is fully configured, which happens later in the networking setup.

**For Sonarr:**
| Field | Value |
|-------|-------|
| Application | Sonarr |
| Prowlarr Server | `http://localhost:9696` |
| Sonarr Server | `http://localhost:8989` |
| API Key | (from Sonarr → Settings → General) |

**For Radarr:**
| Field | Value |
|-------|-------|
| Application | Radarr |
| Prowlarr Server | `http://localhost:9696` |
| Radarr Server | `http://localhost:7878` |
| API Key | (from Radarr → Settings → General) |

Click Test → Save for each. Prowlarr will automatically sync indexers to both apps.

---

## 3. Sonarr (port 8989)

Sonarr monitors and auto-downloads TV shows.

### Add Root Folder
Settings → Media Management → Root Folders → Add → `/mnt/media/tv`

### Rename Settings (recommended)
Settings → Media Management → Episode Naming:
- Rename Episodes: ✅ Enabled
- Standard Episode Format: `{Series Title} - S{season:00}E{episode:00} - {Episode Title}`

### Connect qBittorrent
Settings → Download Clients → Add → qBittorrent:

| Field | Value |
|-------|-------|
| Host | `localhost` |
| Port | `8080` |
| Username | `admin` |
| Password | (your qBittorrent password) |
| Category | `sonarr` |

Click Test → Save.

### Quality Profile
Settings → Quality → choose your preferred profile. **HD-1080p** is a good default for most setups.

### Verify Prowlarr Sync
Settings → Indexers — your Prowlarr indexers should appear here automatically after the Prowlarr app connection above.

---

## 4. Radarr (port 7878)

Radarr is the movie equivalent of Sonarr. Configuration is nearly identical.

### Add Root Folder
Settings → Media Management → Root Folders → Add → `/mnt/media/movies`

### Rename Settings (recommended)
Settings → Media Management → Movie Naming:
- Rename Movies: ✅ Enabled
- Standard Movie Format: `{Movie Title} ({Release Year})`

### Connect qBittorrent
Settings → Download Clients → Add → qBittorrent:

| Field | Value |
|-------|-------|
| Host | `localhost` |
| Port | `8080` |
| Username | `admin` |
| Password | (your qBittorrent password) |
| Category | `radarr` |

Click Test → Save.

### Quality Profile
Settings → Quality → **HD-1080p** recommended. Enable **HD Bluray** if you want higher quality rips.

### Verify Prowlarr Sync
Settings → Indexers — should show your Prowlarr indexers automatically.

---

## 5. Jellyfin (port 8096)

Jellyfin is the media frontend — this is what you use to watch your content.

### Setup Wizard
On first visit, the wizard will guide you through:

1. **Create admin account** — choose a username and password
2. **Add media libraries:**

| Library | Type | Folder |
|---------|------|--------|
| Movies | Movies | `/mnt/media/movies` |
| TV Shows | Shows | `/mnt/media/tv` |

3. **Metadata language** — set to your preferred language
4. **Allow remote connections** — ✅ Yes (needed for Netbird access)

### Transcoding (optional)
Dashboard → Playback → Transcoding:
- Your Intel 8th Gen CPU supports **Intel Quick Sync** hardware acceleration
- Set Hardware Acceleration to `Intel QuickSync (QSV)`
- This offloads transcoding from the CPU — important if multiple people stream simultaneously

### Clients
Install Jellyfin on your devices:
- **Android/iOS** — Jellyfin app from the respective app store
- **TV** — Jellyfin for Android TV, or use the web browser
- **Desktop** — browser at `http://<server-ip>:8096` or the Jellyfin Media Player app

For remote access outside your home, connect via Netbird VPN first, then use `http://10.10.10.12:8096`.

---

## 6. Bazarr (port 6767)

Bazarr monitors Sonarr and Radarr libraries and automatically downloads subtitles for your content.

### Connect to Sonarr and Radarr

Settings → Sonarr:

| Field | Value |
|-------|-------|
| Address | `localhost` |
| Port | `8989` |
| API Key | (from Sonarr → Settings → General) |

Click Test → Save. Repeat under Settings → Radarr with port `7878`.

### Add a Subtitle Provider

Settings → Subtitles → Subtitle Providers → Add Provider. Recommended options:

| Provider | Notes |
|----------|-------|
| **OpenSubtitles.com** | Free account required — high volume |
| **Subscene** | No account needed — good coverage |
| **YIFY Subtitles** | Movies only, no account needed |

Add at least one, click Test → Save.

### Configure Languages

Settings → Languages → Languages Filter → enable your preferred language(s) (e.g. English).

Then set a default language profile:
- Settings → Languages → Add New Profile → give it a name, add your language(s)
- Under "Default Settings" enable the profile for both Series and Movies

### Manual Subtitle Search (on-demand)

- **Sonarr series**: Bazarr → Series → click a show → Episodes → click the subtitle icon on any episode
- **Radarr movies**: Bazarr → Movies → click the subtitle icon on any film

---

## End-to-End Test

Once everything is configured, run a quick test to verify the full pipeline works:

1. In **Radarr** → Movies → Add Movie → search for any movie → set quality profile → Add
2. Radarr should find it via Prowlarr and send it to qBittorrent automatically
3. **qBittorrent** → check the Torrents tab — the download should appear under the `radarr` category
4. Once complete, Radarr imports it to `/mnt/media/movies/`
5. **Jellyfin** → refresh the Movies library — the film should appear

If step 2 doesn't happen automatically, go to Radarr → Movies → select the movie → Search Now to trigger a manual search.

---

## Removing the Temporary LAN Interface

Once configuration is done, remove the temporary eth1 interface to keep CT102 internal-only:

```bash
pct set 102 --delete net1
```

After this, access the services through Netbird (remote) or by temporarily re-adding eth1 if you need to make changes.
