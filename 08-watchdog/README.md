# 08 — Watchdog Monitoring (CT107)

## What this sets up
[Uptime Kuma](https://github.com/louislam/uptime-kuma) — a lightweight, self-hosted monitoring dashboard. It pings all your services every 60 seconds and alerts you (via Telegram, email, or a dozen other methods) when something goes down.

---

## Step 1 — Create CT107

```bash
# ⚠️ Template version disclaimer: Alpine template filenames change with each release.
# Before running this, check the current name with:
#   pveam available --section system | grep alpine
# Replace the template name below with whatever that command returns.

pct create 107 local:vztmpl/alpine-3.21-default_20241217_amd64.tar.xz \
  --hostname watchdog \
  --memory 128 \
  --net0 name=eth0,bridge=vmbr0,ip=dhcp \
  --net1 name=eth1,bridge=vmbr1,ip=dhcp \
  --rootfs local-lvm:4 \
  --unprivileged 1 \
  --features nesting=1 \
  --onboot 1 \
  --start 1
```

---

## Step 2 — Install Uptime Kuma

```bash
pct enter 107
```

```bash
# Alpine: install Node.js, npm and pm2
apk update && apk add nodejs npm

# Install pm2 (uses npm — internal, no external connection needed)
npm install -g pm2

exit
```

```bash
# On Proxmox host — clone Uptime Kuma and push into container
git clone https://github.com/louislam/uptime-kuma.git /tmp/uptime-kuma
tar -czf /tmp/uptime-kuma.tar.gz -C /tmp uptime-kuma
pct push 107 /tmp/uptime-kuma.tar.gz /tmp/uptime-kuma.tar.gz
pct exec 107 -- tar -xzf /tmp/uptime-kuma.tar.gz -C /opt/
pct exec 107 -- sh -c 'cd /opt/uptime-kuma && npm run setup'

# Start with PM2
pct exec 107 -- pm2 start /opt/uptime-kuma/server/server.js --name uptime-kuma
pct exec 107 -- pm2 save
pct exec 107 -- pm2 startup
```

---

## Step 3 — First Login

Get the LAN IP:
```bash
pct exec 107 -- ip addr show eth0 | grep 'inet '
```

Open `http://<watchdog-lan-ip>:3001`

Create your admin account on the first-run screen.

---

## Step 4 — Add Monitors

In the Uptime Kuma dashboard, click **Add New Monitor** for each service:

### Proxmox Host
- Type: `TCP Port`
- Hostname: `<proxmox-host-lan-ip>`, Port: `8006`
- Name: `Proxmox Web UI`

### CT100 — Gateway
- Type: `HTTP(s)`
- URL: `http://10.10.10.1` (or TCP ping)
- Name: `Gateway (dnsmasq)`

### CT101 — Samba
- Type: `TCP Port`
- Hostname: `10.10.10.11`, Port: `445`
- Name: `Samba`

### CT102 — Jellyfin
- Type: `HTTP(s)`
- URL: `http://10.10.10.12:8096`
- Name: `Jellyfin`

### CT102 — Sonarr
- Type: `HTTP(s)`
- URL: `http://10.10.10.12:8989`
- Name: `Sonarr`

### CT102 — Radarr
- Type: `HTTP(s)`
- URL: `http://10.10.10.12:7878`
- Name: `Radarr`

### CT102 — qBittorrent
- Type: `HTTP(s)`
- URL: `http://10.10.10.12:8080`
- Name: `qBittorrent`

### CT103 — n8n
- Type: `HTTP(s)`
- URL: `http://10.10.10.13:5678`
- Name: `n8n`

### CT104 — CouchDB
- Type: `HTTP(s)`
- URL: `http://10.10.10.14:5984`
- Name: `CouchDB (Obsidian)`

### CT105 — Karakeep
- Type: `HTTP(s)`
- URL: `http://10.10.10.15:3000`
- Name: `Karakeep`

### CT106 — Netbird
- Type: `TCP Port`
- Hostname: `10.10.10.16`, Port: `80`
- Name: `Netbird`

Set **Check Interval** to 60 seconds for all monitors.

---

## Step 5 — Set Up Alerts

Go to **Settings → Notifications** and add your preferred alert method:

### Telegram (recommended — free, instant)
1. Create a Telegram bot: message [@BotFather](https://t.me/botfather) → `/newbot`
2. Copy the bot token
3. Get your chat ID: message [@userinfobot](https://t.me/userinfobot)
4. In Uptime Kuma: Notifications → Add → Telegram
5. Enter bot token and chat ID
6. Test it — you should get a Telegram message

### Email (via Gmail SMTP)
- SMTP Host: `smtp.gmail.com`, Port: `587`
- Use a Gmail App Password (not your main password)

---

## Step 6 — Status Page (Optional)

Create a public or private status page:

1. **Status Pages** → **New Status Page**
2. Name it `Abena`
3. Add all your monitors to it
4. Access it at `http://<watchdog-ip>:3001/status/abena`

This gives you a clean overview dashboard you can check from any device (or share with household members).

---

## Resilience Notes

- PM2 automatically restarts Uptime Kuma if it crashes
- `pm2 startup` makes it survive container reboots
- Uptime Kuma's data (monitor history, settings) is stored inside the container at `/opt/uptime-kuma/data`. Consider backing this up in your backup strategy.

---

## Checkpoint

- [ ] CT107 running
- [ ] Uptime Kuma accessible at `http://<ip>:3001`
- [ ] All 12+ monitors added and showing green
- [ ] Alert notification tested and working

**Next:** [09 — Backups](../09-backups/README.md)
