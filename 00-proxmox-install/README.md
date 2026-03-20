# 00 — Proxmox Install & Storage Setup

## What you'll do here
- Install Proxmox VE on the 240 GB NVMe
- Configure the 2 TB SSD as a data volume
- Apply post-install hardening

---

## Step 1 — Download & Flash Proxmox VE

1. Download the latest Proxmox VE ISO from https://www.proxmox.com/en/downloads
2. Flash to a USB drive (8 GB+):
   ```bash
   # On Linux/macOS
   dd if=proxmox-ve_*.iso of=/dev/sdX bs=1M status=progress
   # Or use Balena Etcher on Windows
   ```
3. Boot the target machine from the USB (spam F12/F10/Del at startup for boot menu)

---

## Step 2 — Proxmox Installer

Work through the graphical installer:

| Field | Value |
|-------|-------|
| Target disk | Select your **240 GB NVMe** |
| Filesystem | `ext4` (reliable; no need for ZFS on single disk) |
| Country/Timezone | Set to yours |
| Hostname | `abena.local` |
| Password | Choose a strong root password — store it in a password manager |
| Email | Any valid address (used for alerts) |
| Network | Accept DHCP — you'll get a LAN IP automatically |

> ⚠️ **Double-check the target disk.** Make absolutely sure you select the NVMe and not the 2 TB SSD.

After install, remove the USB and let the machine reboot.

---

## Step 3 — Access the Web UI

From another machine on your LAN:

```
https://<proxmox-ip>:8006
```

The IP was shown at the end of the installer. Log in as `root` with the password you set.

> The browser will warn about an untrusted certificate. This is expected — proceed anyway.

---

## Step 4 — Post-Install: Remove Subscription Nag & Set Free Repos

Run these in the Proxmox shell (click your node → Shell in the web UI):

```bash
# Remove the enterprise (paid) repo
rm -f /etc/apt/sources.list.d/pve-enterprise.list

# Add the free/community repo
echo "deb http://download.proxmox.com/debian/pve bookworm pve-no-subscription" \
  > /etc/apt/sources.list.d/pve-no-subscription.list

# Update & upgrade
apt update && apt full-upgrade -y

# Remove subscription popup (cosmetic)
sed -i.bak "s/data.status !== 'Active'/false/g" \
  /usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js
systemctl restart pveproxy
```

---

## Step 5 — Configure the 2 TB SSD as Data Storage

### 5a — Identify the SSD

```bash
lsblk -o NAME,SIZE,MODEL,TRAN
```

Find your 2 TB SSD — it will be something like `/dev/sda`. Note the device name.

### 5b — Wipe & Partition

> ⚠️ This will **erase everything** on the 2 TB SSD.

```bash
# Replace /dev/sda with your actual device
wipefs -a /dev/sda
parted /dev/sda --script mklabel gpt
parted /dev/sda --script mkpart primary ext4 0% 100%
mkfs.ext4 /dev/sda1
```

### 5c — Mount the SSD

```bash
mkdir -p /mnt/data
echo "/dev/sda1  /mnt/data  ext4  defaults,nofail  0  2" >> /etc/fstab
mount -a
df -h /mnt/data   # Verify it mounted
```

### 5d — Create the Data Directory Structure

```bash
mkdir -p /mnt/data/{media,downloads,samba,n8n,obsidian,karakeep,backups}
mkdir -p /mnt/data/media/{movies,tv,music}
mkdir -p /mnt/data/downloads/{incomplete,complete}
chmod -R 755 /mnt/data
```

### 5e — Add as Proxmox Directory Storage

```bash
pvesm add dir data-ssd --path /mnt/data --content vztmpl,backup,iso
```

Or via the web UI: Datacenter → Storage → Add → Directory → path `/mnt/data`.

---

## Step 6 — Download LXC Templates

```bash
# Update template list
pveam update

# Download Debian 12 (Bookworm) template — used for all containers
pveam download local debian-12-standard_12.7-1_amd64.tar.zst

# Download Alpine 3.19 — used for lightweight containers (gateway, watchdog)
pveam download local alpine-3.19-default_20240207_amd64.tar.xz
```

---

## Step 7 — Harden Proxmox Host

```bash
# Disable IPv6 (simplifies networking, not needed here)
cat >> /etc/sysctl.conf << 'EOF'
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
EOF
sysctl -p

# Set automatic security updates
apt install -y unattended-upgrades
dpkg-reconfigure -f noninteractive unattended-upgrades

# Set timezone
timedatectl set-timezone America/Bogota   # Change to your timezone
```

---

## Checkpoint

At this point you should have:
- [ ] Proxmox web UI accessible at `https://<ip>:8006`
- [ ] 2 TB SSD mounted at `/mnt/data` with subdirectory structure
- [ ] Debian 12 and Alpine templates downloaded
- [ ] System updated

**Next:** [01 — Networking](../01-networking/README.md)
