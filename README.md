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
| 102 | media      | 2 GB   | Jellyfin + Sonarr + Radarr + Prowlarr + qBittorrent |
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
3. [02 — Samba File Server](./02-samba/README.md)
4. [03 — Media Server](./03-media/README.md)
5. [04 — n8n Automation](./04-n8n/README.md)
6. [05 — Obsidian LiveSync](./05-obsidian/README.md)
7. [06 — Karakeep](./06-karakeep/README.md)
8. [07 — Netbird VPN](./07-netbird/README.md)
9. [08 — Watchdog Monitoring](./08-watchdog/README.md)
10. [09 — Backups](./09-backups/README.md)

> 🔧 Running into errors? Check the **[Troubleshooting Guide](./TROUBLESHOOTING.md)** — it covers the most common issues encountered during setup.

> 📦 Adding a new service not listed here? See the **[New Container Appendix](./APPENDIX-new-containers.md)** — it covers proxy setup, apt config, and the correct way to install software in any new container.

---

## DHCP Resilience Strategy

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
