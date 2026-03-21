# 02 — Samba File Server (CT101)

## What this sets up
A Samba share that exposes the 2 TB SSD's data directories to your LAN. Windows, macOS, and Linux can all access files without any special software.

---

## Step 1 — Create CT101

```bash
# ⚠️ Template version disclaimer: Debian template filenames change with each point release.
# Before running this, check the current name with:
#   pveam available --section system | grep debian-12
# Replace the template name below with whatever that command returns.

pct create 101 local:vztmpl/debian-12-standard_12.12-1_amd64.tar.zst \
  --hostname samba \
  --memory 512 \
  --net0 name=eth0,bridge=vmbr0,ip=dhcp \
  --net1 name=eth1,bridge=vmbr1,ip=dhcp \
  --rootfs local-lvm:4 \
  --unprivileged 0 \
  --features nesting=1 \
  --onboot 1 \
  --start 1
```

> This container is **privileged** (`--unprivileged 0`) because it needs to bind-mount host directories. `--features nesting=1` is required to suppress the `Systemd 252 detected` warning and ensure systemd services (smbd, nmbd) start correctly inside the container.

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

## Step 3 — Bind-Mount the Data Directory

The 2 TB SSD data is on the **Proxmox host** at `/mnt/data`. We bind-mount it into the container so Samba can serve it:

```bash
# Stop the container first
pct stop 101

# Add bind mounts
pct set 101 --mp0 /mnt/data/samba,mp=/mnt/samba
pct set 101 --mp1 /mnt/data/media,mp=/mnt/media

# Start it back up
pct start 101
```

---

## Step 4 — Install & Configure Samba

Two users are created:

| User | Access | Password |
|------|--------|----------|
| `shareuser` | Read + Write | Yes — set by you |
| `guest` | Read only | None |

This lets media players, TVs, and other devices on your LAN browse files without credentials, while only you can make changes.

```bash
pct enter 101
```

Inside CT101:

```bash
apt update && apt install -y samba samba-common-bin

# --- Read-write user ---
# 'shareuser' is the username you'll use from your laptop/phone when writing files
useradd -M -s /sbin/nologin shareuser
smbpasswd -a shareuser
# (enter your chosen Samba password twice — this is what you'll type on your devices)

# --- Read-only guest ---
# No Linux account needed — Samba maps unauthenticated connections to nobody
# 'nobody' already exists on Debian, nothing to create

# Write Samba config
cat > /etc/samba/smb.conf << 'EOF'
[global]
   workgroup = WORKGROUP
   server string = Abena
   security = user
   # Unauthenticated connections are mapped to the guest account
   map to guest = bad user
   guest account = nobody
   log file = /var/log/samba/log.%m
   max log size = 50
   dns proxy = no
   # Performance
   socket options = TCP_NODELAY IPTOS_LOWDELAY SO_RCVBUF=65536 SO_SNDBUF=65536

[Files]
   comment = Shared Files
   path = /mnt/samba
   # Read-write for shareuser, read-only for guests
   valid users = shareuser, guest
   write list = shareuser
   read only = yes
   browsable = yes
   guest ok = yes
   create mask = 0664
   directory mask = 0775
   force create mode = 0664
   force directory mode = 0775

[Media]
   comment = Media Library
   path = /mnt/media
   # Guests can browse and play media; only shareuser can add/delete files
   valid users = shareuser, guest
   write list = shareuser
   read only = yes
   browsable = yes
   guest ok = yes
   create mask = 0664
   directory mask = 0775
   force create mode = 0664
   force directory mode = 0775
EOF

# Set ownership — shareuser owns the directories for writes
# nobody (guest) only needs read permission, which 755 provides
chown -R shareuser:shareuser /mnt/samba /mnt/media 2>/dev/null || true
chmod -R 755 /mnt/samba /mnt/media

systemctl enable smbd nmbd
systemctl restart smbd nmbd

exit
```

---

## Step 5 — Verify the Share

From another machine on your LAN:

**Linux:**
```bash
smbclient -L //<samba-lan-ip> -U shareuser
# You should see the Files and Media shares listed
```

**Windows:** Open File Explorer → address bar → `\\<samba-lan-ip>`

**macOS:** Finder → Go → Connect to Server → `smb://<samba-lan-ip>`

### Finding the Samba container's LAN IP

```bash
# From Proxmox host
pct exec 101 -- ip addr show eth0 | grep 'inet '
```

---

## Step 6 — Optional: Persistent LAN Mount (Linux clients)

```bash
# Add to /etc/fstab on a Linux client
//<samba-ip>/Files  /mnt/abena-files  cifs  username=shareuser,password=<pass>,uid=1000,gid=1000,iocharset=utf8  0  0
```

---

## Resilience Notes

- Samba has **no state** — if the container breaks, rebuild it from scratch. Your files are safe on the 2 TB SSD.
- `systemctl enable smbd nmbd` ensures Samba restarts automatically after a container reboot.
- The bind mount definition is stored in the Proxmox container config (`/etc/pve/lxc/101.conf`), so it survives container rebuilds as long as you restore the config.

---

## Checkpoint

- [ ] CT101 running with dual network interfaces
- [ ] `/mnt/samba` and `/mnt/media` accessible inside container
- [ ] Samba shares visible from LAN devices
- [ ] `shareuser` can read and write to both shares

**Next:** [03 — Media Server](../03-media/README.md)
