# 05 — Obsidian LiveSync via CouchDB (CT104)

## How This Works
[Obsidian LiveSync](https://github.com/vrtmrz/obsidian-livesync) is an Obsidian community plugin that syncs your vault in real time across all your devices (phone, laptop, tablet) using a self-hosted CouchDB database as the relay.

```
Phone ──┐
        ├──► CouchDB (CT104) ◄──── sync ────► Desktop
Laptop ─┘
```

Your vault files live in Obsidian on each device. CouchDB holds the sync state. There's no "master copy" on the server — every device is equal.

---

## Step 1 — Create CT104

```bash
# ⚠️ Template version disclaimer: Debian template filenames change with each point release.
# Before running this, check the current name with:
#   pveam available --section system | grep debian-12
# Replace the template name below with whatever that command returns.

pct create 104 local:vztmpl/debian-12-standard_12.12-1_amd64.tar.zst \
  --hostname obsidian \
  --memory 512 \
  --net0 name=eth0,bridge=vmbr1,ip=dhcp \
  --net1 name=eth1,bridge=vmbr0,ip=dhcp \
  --rootfs local-lvm:4 \
  --unprivileged 1 \
  --features nesting=1 \
  --onboot 1 \
  --start 1
```

---

## Step 2 — Force apt to use IPv4

The internal `vmbr1` bridge is IPv4-only, and some routers block outbound HTTP (port 80) for IPs they did not assign. Both issues are fixed by forcing IPv4 and switching apt to HTTPS mirrors:

```bash
# Force IPv4
pct exec 104 -- bash -c 'echo "Acquire::ForceIPv4 \"true\";" > /etc/apt/apt.conf.d/99force-ipv4'

# Switch to HTTPS mirrors
pct exec 104 -- bash -c 'cat > /etc/apt/sources.list << EOF
deb https://deb.debian.org/debian bookworm main contrib non-free non-free-firmware
deb https://deb.debian.org/debian bookworm-updates main contrib non-free non-free-firmware
deb https://security.debian.org/debian-security bookworm-security main contrib non-free non-free-firmware
EOF'
```

---

## Step 3 — Bind-Mount Data

```bash
pct stop 104
pct set 104 --mp0 /mnt/data/obsidian,mp=/opt/couchdb/data
pct start 104
```

---

## Step 4 — Install CouchDB

```bash
pct enter 104
```

```bash
# Add CouchDB repo
curl https://couchdb.apache.org/repo/keys.asc | gpg --dearmor \
  > /usr/share/keyrings/couchdb-archive-keyring.gpg

echo "deb [signed-by=/usr/share/keyrings/couchdb-archive-keyring.gpg] \
  https://apache.jfrog.io/artifactory/couchdb-deb/ bookworm main" \
  > /etc/apt/sources.list.d/couchdb.list

apt update

# Install — select "standalone" mode when prompted
# Set admin password when asked — use something strong and save it
DEBIAN_FRONTEND=noninteractive apt install -y couchdb
```

During the install wizard:
- **Erlang cookie:** accept default (random)
- **Node type:** `standalone`
- **Bind address:** `0.0.0.0` (so all interfaces can reach it)
- **Admin password:** choose a strong password and note it

---

## Step 5 — Configure CouchDB for LiveSync

```bash
# Edit the CouchDB local config
cat >> /opt/couchdb/etc/local.ini << 'EOF'

[couch_peruser]
enable = true
delete_dbs = true

[chttpd]
require_valid_user = true
max_http_request_size = 4294967296

[couchdb]
max_document_size = 50000000

[httpd]
enable_cors = true

[cors]
origins = app://obsidian.md,capacitor://localhost,http://localhost
credentials = true
headers = accept, authorization, content-type, origin, referer
methods = GET, PUT, DELETE, POST, HEAD
max_age = 3600
EOF

systemctl restart couchdb

# Verify CouchDB is running
curl http://localhost:5984/
# Should return {"couchdb":"Welcome",...}
```

---

## Step 6 — Create a LiveSync Database & User

```bash
# Set your admin credentials from the install step
COUCH_ADMIN="admin"
COUCH_PASS="your-admin-password"
COUCH_URL="http://${COUCH_ADMIN}:${COUCH_PASS}@localhost:5984"

# Create a dedicated sync user (use a different password from admin)
SYNC_USER="obsidian"
SYNC_PASS="your-sync-password"

curl -X PUT "${COUCH_URL}/_users/org.couchdb.user:${SYNC_USER}" \
  -H "Content-Type: application/json" \
  -d "{\"name\":\"${SYNC_USER}\",\"password\":\"${SYNC_PASS}\",\"roles\":[],\"type\":\"user\"}"

# Create the sync database
curl -X PUT "${COUCH_URL}/obsidian-vault"

# Grant the sync user access to the database
curl -X PUT "${COUCH_URL}/obsidian-vault/_security" \
  -H "Content-Type: application/json" \
  -d "{\"admins\":{\"names\":[\"${COUCH_ADMIN}\"],\"roles\":[]},\"members\":{\"names\":[\"${SYNC_USER}\"],\"roles\":[]}}"

echo "CouchDB configured. Sync endpoint: http://<server-ip>:5984"

exit
```

---

## Step 7 — Install the Obsidian LiveSync Plugin

On each device (desktop, phone, tablet):

1. Open Obsidian → Settings → Community Plugins → Browse
2. Search for **"Self-hosted LiveSync"** → Install → Enable
3. Open the plugin settings:

| Field | Value |
|-------|-------|
| CouchDB URL | `http://<obsidian-lan-ip>:5984` |
| Database Name | `obsidian-vault` |
| Username | `obsidian` (the sync user you created) |
| Password | your sync password |

4. Click **"Test"** — should show green
5. Set sync mode to **"LiveSync"** for real-time sync, or **"Periodic"** to sync every few minutes

> For access outside your LAN, use the Netbird VPN (step 07). The CouchDB URL will then be `http://10.10.10.14:5984` via the VPN tunnel.

---

## Step 8 — Verify Sync

1. Open your vault on two devices
2. Create a test note on one
3. It should appear on the other within seconds

---

## Resilience Notes

- CouchDB data lives at `/mnt/data/obsidian` on the 2 TB SSD — container is stateless.
- If sync breaks, you can always start fresh: delete the CouchDB database, re-create it, and do a "fresh sync" from your main device. No data is lost from your local vaults.
- `require_valid_user = true` ensures no unauthenticated access to your notes.

---

## Checkpoint

- [ ] CT104 running
- [ ] CouchDB accessible at `http://<ip>:5984`
- [ ] LiveSync plugin installed on all devices
- [ ] Test note syncs between two devices

**Next:** [06 — Karakeep](../06-karakeep/README.md)
