# 06 — Karakeep (CT105)

## What this sets up
[Karakeep](https://karakeep.app) — a self-hosted bookmark manager and read-it-later app. Save links, articles, and notes from any device.

---

## Step 1 — Create CT105

```bash
# ⚠️ Template version disclaimer: Debian template filenames change with each point release.
# Before running this, check the current name with:
#   pveam available --section system | grep debian-12
# Replace the template name below with whatever that command returns.

pct create 105 local:vztmpl/debian-12-standard_12.12-1_amd64.tar.zst \
  --hostname karakeep \
  --memory 512 \
  --net0 name=eth0,bridge=vmbr1,ip=dhcp \
  --net1 name=eth1,bridge=vmbr0,ip=dhcp \
  --rootfs local-lvm:8 \
  --unprivileged 1 \
  --features nesting=1 \
  --onboot 1 \
  --start 1
```

---

## Step 2 — Bind-Mount Data

```bash
pct stop 105
pct set 105 --mp0 /mnt/data/karakeep,mp=/mnt/karakeep
pct start 105
```

---

## Step 3 — Install Docker

Karakeep is distributed as a Docker image. We'll run it with Docker Compose inside the LXC container.

```bash
pct enter 105
```

```bash
# Install Docker
curl -fsSL https://get.docker.com | sh
systemctl enable --now docker

# Install Docker Compose plugin
apt install -y docker-compose-plugin

# Verify
docker --version
docker compose version
```

---

## Step 4 — Configure & Launch Karakeep

```bash
mkdir -p /opt/karakeep
cat > /opt/karakeep/docker-compose.yml << 'EOF'
version: "3.8"

services:
  karakeep:
    image: ghcr.io/karakeep-app/karakeep:latest
    container_name: karakeep
    restart: unless-stopped
    ports:
      - "3000:3000"
    volumes:
      - /mnt/karakeep:/data
    environment:
      - NEXTAUTH_SECRET=change-this-to-a-random-string-at-least-32-chars
      - NEXTAUTH_URL=http://localhost:3000
      - DATA_DIR=/data
    healthcheck:
      test: ["CMD", "wget", "-q", "--spider", "http://localhost:3000"]
      interval: 30s
      timeout: 10s
      retries: 3

  chrome:
    image: gcr.io/zenika-hub/alpine-chrome:123
    container_name: karakeep-chrome
    restart: unless-stopped
    command: chromium-browser --no-sandbox --disable-gpu --disable-dev-shm-usage --remote-debugging-address=0.0.0.0 --remote-debugging-port=9222 --hide-scrollbars
    cap_add:
      - SYS_ADMIN

networks:
  default:
    driver: bridge
EOF

# Generate a random secret
SECRET=$(openssl rand -base64 32)
sed -i "s/change-this-to-a-random-string-at-least-32-chars/${SECRET}/" \
  /opt/karakeep/docker-compose.yml

cd /opt/karakeep
docker compose up -d

# Check it's running
docker compose ps
```

---

## Step 5 — Connect Chrome to Karakeep

```bash
# Update docker-compose to link chrome to karakeep
cat > /opt/karakeep/docker-compose.yml << 'EOF'
version: "3.8"

services:
  karakeep:
    image: ghcr.io/karakeep-app/karakeep:latest
    container_name: karakeep
    restart: unless-stopped
    ports:
      - "3000:3000"
    volumes:
      - /mnt/karakeep:/data
    environment:
      - NEXTAUTH_SECRET=${KARAKEEP_SECRET}
      - NEXTAUTH_URL=http://localhost:3000
      - DATA_DIR=/data
      - BROWSER_WEB_URL=http://chrome:9222
    depends_on:
      - chrome

  chrome:
    image: gcr.io/zenika-hub/alpine-chrome:123
    container_name: karakeep-chrome
    restart: unless-stopped
    command: chromium-browser --no-sandbox --disable-gpu --disable-dev-shm-usage --remote-debugging-address=0.0.0.0 --remote-debugging-port=9222 --hide-scrollbars

networks:
  default:
    driver: bridge
EOF

# Store secret in env file
echo "KARAKEEP_SECRET=$(openssl rand -base64 32)" > /opt/karakeep/.env
chmod 600 /opt/karakeep/.env

cd /opt/karakeep
docker compose up -d

exit
```

---

## Step 6 — First Login

Get the LAN IP:
```bash
pct exec 105 -- ip addr show eth1 | grep 'inet '
```

Open `http://<karakeep-lan-ip>:3000` in your browser.

Create an account on the first-run screen. There's no default admin — the first registered user becomes the owner.

---

## Step 7 — Browser Extension

Install the Karakeep browser extension for one-click saving:

- [Chrome / Chromium](https://chrome.google.com/webstore/detail/karakeep)
- [Firefox](https://addons.mozilla.org/en-US/firefox/addon/karakeep/)

In the extension settings, set the server URL to `http://<karakeep-lan-ip>:3000` (or the Netbird VPN IP for remote access).

---

## Auto-Update

To keep Karakeep updated:

```bash
pct enter 105
cd /opt/karakeep
docker compose pull && docker compose up -d
exit
```

You can automate this with a weekly cron job or an n8n workflow.

---

## Checkpoint

- [ ] CT105 running
- [ ] Karakeep accessible at `http://<ip>:3000`
- [ ] Account created and working
- [ ] Browser extension installed and connected

**Next:** [07 — Netbird VPN](../07-netbird/README.md)
