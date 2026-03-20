# 04 — n8n Automation Server (CT103)

## What this sets up
n8n running as a persistent systemd service using SQLite for storage (no separate database container needed). Data persists on the 2 TB SSD.

---

## Step 1 — Create CT103

```bash
pct create 103 local:vztmpl/debian-12-standard_12.7-1_amd64.tar.zst \
  --hostname n8n \
  --memory 1024 \
  --net0 name=eth0,bridge=vmbr1,ip=dhcp \
  --net1 name=eth1,bridge=vmbr0,ip=dhcp \
  --rootfs local-lvm:8 \
  --unprivileged 1 \
  --onboot 1 \
  --start 1
```

> n8n is kept on both bridges — `vmbr1` for internal access and `vmbr0` so you can reach it from your LAN without needing Netbird for day-to-day use.

---

## Step 2 — Bind-Mount Data Directory

```bash
pct stop 103
pct set 103 --mp0 /mnt/data/n8n,mp=/mnt/n8n
pct start 103
```

---

## Step 3 — Install n8n

```bash
pct enter 103
```

```bash
# Install Node.js 20 (LTS)
curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
apt install -y nodejs

# Verify
node --version   # Should be v20.x.x
npm --version

# Install n8n globally
npm install -g n8n

# Create dedicated user
useradd -r -m -s /bin/bash n8n

# Set up data directory
mkdir -p /mnt/n8n
chown -R n8n:n8n /mnt/n8n
```

---

## Step 4 — Create systemd Service

```bash
cat > /etc/systemd/system/n8n.service << 'EOF'
[Unit]
Description=n8n Automation Server
After=network.target

[Service]
Type=simple
User=n8n
WorkingDirectory=/mnt/n8n
Environment=N8N_USER_FOLDER=/mnt/n8n
Environment=N8N_PORT=5678
Environment=N8N_PROTOCOL=http
Environment=N8N_HOST=0.0.0.0
Environment=EXECUTIONS_DATA_SAVE_ON_SUCCESS=last
Environment=EXECUTIONS_DATA_SAVE_ON_ERROR=all
Environment=N8N_BASIC_AUTH_ACTIVE=true
Environment=N8N_BASIC_AUTH_USER=admin
Environment=N8N_BASIC_AUTH_PASSWORD=changeme123
Environment=NODE_ENV=production
ExecStart=/usr/bin/n8n start
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now n8n
```

> ⚠️ **Change `N8N_BASIC_AUTH_PASSWORD`** to a strong password before enabling the service.

---

## Step 5 — Verify

```bash
systemctl status n8n
# Should show "active (running)"

# Check the port is listening
ss -tlnp | grep 5678

exit
```

Access n8n from your LAN:
```
http://<n8n-lan-ip>:5678
```

Get the LAN IP:
```bash
pct exec 103 -- ip addr show eth1 | grep 'inet '
```

---

## Step 6 — Secure the Config

The password in the systemd unit file is readable by root. For a more secure setup, use an environment file:

```bash
pct enter 103

# Move secrets to a protected env file
mkdir -p /etc/n8n
cat > /etc/n8n/env << 'EOF'
N8N_BASIC_AUTH_USER=admin
N8N_BASIC_AUTH_PASSWORD=your-strong-password-here
EOF
chmod 600 /etc/n8n/env
chown n8n:n8n /etc/n8n/env
```

Edit the service file to use it:
```bash
# Replace the inline auth env vars with:
# EnvironmentFile=/etc/n8n/env
systemctl daemon-reload && systemctl restart n8n

exit
```

---

## Resilience Notes

- n8n data (workflows, credentials, execution history) lives in `/mnt/n8n` on the 2 TB SSD — safe if the container is rebuilt.
- `Restart=always` and `RestartSec=10` mean n8n automatically recovers from crashes.
- SQLite is sufficient for a single-user home server. No Postgres needed unless you're running hundreds of concurrent workflows.

---

## Checkpoint

- [ ] CT103 running with LAN access
- [ ] n8n accessible at `http://<ip>:5678`
- [ ] Login works with your chosen credentials
- [ ] Data directory at `/mnt/n8n` (on 2 TB SSD)

**Next:** [05 — Obsidian LiveSync](../05-obsidian/README.md)
