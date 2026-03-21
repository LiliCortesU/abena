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

## Step 2 — Bind-Mount the Data Directory

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

## Step 3 — Install & Configure Samba

```bash
pct enter 101
```

Inside CT101:

```bash
apt update && apt install -y samba samba-common-bin

# Create the samba user (maps to a Linux user)
# 'shareuser' is the username you'll use when connecting from your devices
useradd -M -s /sbin/nologin shareuser
smbpasswd -a shareuser
# (enter your chosen Samba password twice — this is what you'll type on your phone/laptop)

# Write Samba config
cat > /etc/samba/smb.conf << 'EOF'
[global]
   workgroup = WORKGROUP
   server string = Abena
   security = user
   map to guest = bad user
   log file = /var/log/samba/log.%m
   max log size = 50
   dns proxy = no
   # Performance
   socket options = TCP_NODELAY IPTOS_LOWDELAY SO_RCVBUF=65536 SO_SNDBUF=65536

[Files]
   comment = Shared Files
   path = /mnt/samba
   valid users = shareuser
   read only = no
   browsable = yes
   create mask = 0664
   directory mask = 0775
   force user = shareuser

[Media]
   comment = Media Library
   path = /mnt/media
   valid users = shareuser
   read only = no
   browsable = yes
   create mask = 0664
   directory mask = 0775
   force user = shareuser
EOF

# Set ownership so the share user can write
chown -R shareuser:shareuser /mnt/samba /mnt/media 2>/dev/null || true

systemctl enable smbd nmbd
systemctl restart smbd nmbd

exit
```

---

## Step 4 — Verify the Share

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

## Step 5 — Optional: Persistent LAN Mount (Linux clients)

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
