# Abena — Proxmox Home Server

A resilient, isolated, self-hosted server stack built on Proxmox VE.

**Hardware:** Intel 8th Gen · 8 GB RAM · 2 TB SSD · 240 GB NVMe  
**Philosophy:** Every service lives in its own container. One failure cannot cascade. Data always outlives containers.

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────┐
│                  PROXMOX HOST (NVMe)                    │
│                                                         │
│  vmbr0 (LAN bridge)          vmbr1 (internal bridge)   │
│       │                             │                   │
│  ┌────┴────────────────────────────────────────────┐   │
│  │ CT100 · gateway  (dnsmasq — stable internal IPs) │   │
│  └──────────────────────────────────────────────────┘   │
│                             │                           │
│       ┌─────────────────────┼──────────────────────┐   │
│       │                     │                      │   │
│  CT101·samba          CT102·media            CT103·n8n  │
│  CT104·obsidian       CT105·karakeep         CT106·netbird│
│  CT107·watchdog                                         │
│                                                         │
│              2 TB SSD — /mnt/data (shared data volume)  │
└─────────────────────────────────────────────────────────┘
```

### Container Map

| ID  | Name       | RAM    | Role                                      |
|-----|------------|--------|-------------------------------------------|
| 100 | gateway    | 256 MB | dnsmasq — internal DHCP & DNS             |
| 101 | samba      | 512 MB | Samba file server                         |
| 102 | media      | 2 GB   | Jellyfin + Sonarr + Radarr + Prowlarr + qBittorrent + Bazarr |
| 103 | n8n        | 1 GB   | n8n automation                            |
| 104 | obsidian   | 512 MB | CouchDB (Obsidian LiveSync)               |
| 105 | karakeep   | 512 MB | Karakeep bookmark manager                 |
| 106 | netbird    | 512 MB | Netbird VPN — remote access               |
| 107 | watchdog   | 128 MB | Uptime Kuma — service monitoring          |

---

## Setup Order

Follow these guides in sequence. **Do not skip steps.**

1. [00 — Proxmox Install & Storage](./00-proxmox-install/README.md)
2. [01 — Networking (bridge + internal DNS)](./01-networking/README.md)
3. [01b — Squid Transparent Proxy](./01b-squid-proxy/README.md) ⚠️ **Do this before any container setup**
4. [02 — Samba File Server](./02-samba/README.md)
5. [03 — Media Server](./03-media/README.md)
6. [04 — n8n Automation](./04-n8n/README.md)
7. [05 — Obsidian LiveSync](./05-obsidian/README.md)
8. [06 — Karakeep](./06-karakeep/README.md)
9. [07 — Netbird VPN](./07-netbird/README.md)
10. [08 — Watchdog Monitoring](./08-watchdog/README.md)
11. [09 — Backups](./09-backups/README.md)

> 🔧 Running into errors? Check the **[Troubleshooting Guide](./TROUBLESHOOTING.md)** — it covers the most common issues encountered during setup.

> 📦 Adding a new service not listed here? See the **[New Container Appendix](./APPENDIX-new-containers.md)** — it covers proxy setup, apt config, and the correct way to install software in any new container.

> 🎬 Configuring the media stack (qBittorrent, Prowlarr, Sonarr, Radarr, Jellyfin)? See the **[Media Stack Configuration Guide](./APPENDIX-media-config.md)**.

---

## Users & Groups Reference

Every service runs under a dedicated, unprivileged Linux user — never as root. This limits the blast radius if a service is compromised. Below is the complete list of users and groups created across Abena, why they exist, and where in the guides they are created.

### Proxmox Host

No custom users are created on the Proxmox host itself. All work is done as `root`, which is standard for Proxmox administration.

---

### CT101 — Samba

| Account | Type | Purpose | Created in |
|---------|------|---------|-----------|
| `shareuser` | Linux user + Samba user | Read/write access to shares — this is the username and password you type on your devices | [02-samba → Step 4](./02-samba/README.md) |
| `nobody` | Built-in system account | Guest (unauthenticated) read-only access — Samba maps connections with no credentials to this account | Pre-exists on Debian, nothing to create |

**Why two users?** Samba maps network connections to Linux users for file permissions. `shareuser` owns the share directories and requires a password. `nobody` already exists on every Debian system with minimal permissions — we simply tell Samba to use it for guests, so devices like TVs and media players can browse without credentials.

---

### CT102 — Media Server

| Account | Type | Purpose | Created in |
|---------|------|---------|-----------|
| `media` | Group | Shared group for all download/media services — allows them to read each other's files | [03-media → Step 4, qBittorrent section](./03-media/README.md) |
| `qbt` | Linux user | Runs qBittorrent — member of `media` group | [03-media → Step 4, qBittorrent section](./03-media/README.md) |
| `sonarr` | Linux user | Runs Sonarr, Radarr, and Prowlarr — member of `media` group | [03-media → Step 4, Sonarr section](./03-media/README.md) |
| `bazarr` | Linux user | Runs Bazarr subtitle manager — member of `media` group | [03-media → Step 4, Bazarr section](./03-media/README.md) |

**Why a shared `media` group?** Sonarr and Radarr need to move files that qBittorrent downloaded. Without a shared group, `sonarr` cannot access files owned by `qbt` and imports would fail silently. By putting both users in `media` and setting directory permissions to `775`, all services can read and write to shared directories. Radarr and Prowlarr reuse the `sonarr` user — no separate accounts needed since they serve the same function and need the same file access.

**Why not just use root?** If qBittorrent or Sonarr were exploited, an attacker would only gain the limited permissions of `qbt` or `sonarr` — not root access to the container or the host.

---

### CT103 — n8n

| Account | Type | Purpose | Created in |
|---------|------|---------|-----------|
| `n8n` | Linux user | Runs the n8n automation server — owns the data directory at `/mnt/n8n` | [04-n8n → Step 4](./04-n8n/README.md) |

**Why a dedicated user?** n8n stores credentials and workflow data. Running it as a dedicated user means its data directory is only accessible to that user, adding a layer of isolation.

---

### CT104 — Obsidian LiveSync (CouchDB)

| Account | Type | Purpose | Created in |
|---------|------|---------|-----------|
| `admin` | CouchDB admin user | Full administrative access to CouchDB — set during `apt install couchdb` | [05-obsidian → Step 4](./05-obsidian/README.md) |
| `obsidian` | CouchDB sync user | Limited account used by the Obsidian LiveSync plugin on your devices — access restricted to the `obsidian-vault` database only | [05-obsidian → Step 6](./05-obsidian/README.md) |

**Why two CouchDB users?** The `admin` account has full database control and should never leave the server. The `obsidian` sync user has access only to the vault database — if your sync credentials were ever exposed, an attacker could not access CouchDB administration or other databases.

> Note: CouchDB manages its own users internally. These are not Linux system users.

---

### CT105 — Karakeep

No custom Linux users are created. Karakeep runs inside Docker containers which manage their own internal users. The first account registered in the Karakeep web UI becomes the owner.

---

### CT106 — Netbird

No custom Linux users are created. Netbird runs as a system service under root, which is standard for VPN clients that need to manage network interfaces.

---

### CT107 — Watchdog (Uptime Kuma)

No custom Linux users are created. Uptime Kuma runs under PM2 as root inside the Alpine container. The first account registered in the web UI becomes the admin.

---

### Summary Table

| Container | User/Group | Where created |
|-----------|-----------|---------------|
| CT101 | `shareuser` (Linux + Samba) | 02-samba Step 4 |
| CT101 | `nobody` (Samba guest) | Pre-exists, no action needed |
| CT102 | `media` group | 03-media Step 4 — qBittorrent |
| CT102 | `qbt` | 03-media Step 4 — qBittorrent |
| CT102 | `sonarr` | 03-media Step 4 — Sonarr |
| CT102 | `bazarr` | 03-media Step 4 — Bazarr |
| CT103 | `n8n` | 04-n8n Step 4 |
| CT104 | `admin` (CouchDB) | 05-obsidian Step 4 |
| CT104 | `obsidian` (CouchDB) | 05-obsidian Step 6 |



Your router assigns IPs dynamically and cannot reserve addresses. To work around this without touching the router:

- **Proxmox host** gets whatever IP the router hands it (this is fine — you only need it for initial setup and Proxmox web UI).
- **CT100 (gateway)** runs `dnsmasq` on an internal-only bridge (`vmbr1`) and assigns **fixed IPs to all containers** based on their MAC addresses. These IPs never change.
- Containers that need LAN access (Samba, Netbird, Watchdog) are **dual-homed**: they sit on both `vmbr0` (LAN) and `vmbr1` (internal).
- All inter-container traffic uses the stable `10.10.10.x` range on `vmbr1`.

---

## Resilience Principles

- **Isolated containers** — a broken container cannot affect others
- **Data on a separate disk** — rebuild any container without losing data
- **Watchdog monitoring** — Uptime Kuma alerts you before things get bad
- **Automated backups** — nightly snapshots stored on the 2 TB SSD
- **No single point of failure** — services restart automatically via `systemd`

---

## Quick Reference — Internal IPs

| Container  | Internal IP (vmbr1) |
|------------|---------------------|
| gateway    | 10.10.10.1          |
| samba      | 10.10.10.11         |
| media      | 10.10.10.12         |
| n8n        | 10.10.10.13         |
| obsidian   | 10.10.10.14         |
| karakeep   | 10.10.10.15         |
| netbird    | 10.10.10.16         |
| watchdog   | 10.10.10.17         |
