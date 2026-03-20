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

Use the community post-install script — it handles repo switching, the subscription nag, and the update in one interactive run. Run this in the Proxmox shell (click your node → Shell in the web UI):

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/tools/pve/post-pve-install.sh)"
```

Answer **yes (y) to all prompts**. The script will:
- Disable the enterprise (paid) repo
- Enable the no-subscription (free) repo
- Remove the subscription nag popup
- Run a full system update
- Offer to reboot — accept it

> This script is the community-maintained successor to tteck's original Proxmox helper scripts, widely used in the homelab community.

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
# Install parted (not included in Proxmox base install)
apt install -y parted

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

The template list on Proxmox's servers updates regularly and version numbers change (e.g. `12.7-1` becomes `12.12-1`). Always query the live list to get the current name rather than hardcoding a version:

```bash
# Update the template list
pveam update

# Find the current Debian 12 template name
pveam available --section system | grep debian-12

# Download it — copy the exact name from the output above
# Example (your version number may differ):
pveam download local debian-12-standard_12.12-1_amd64.tar.zst

# Find the current Alpine 3.x template name
pveam available --section system | grep alpine-3

# Download Alpine (for gateway and watchdog containers)
# Example:
pveam download local alpine-3.21-default_20241217_amd64.tar.xz
```

> If `pveam download` returns `400 Parameter verification failed / no such template`, it means the version in your command doesn't match what's currently available. Re-run `pveam available --section system | grep debian-12` to get the exact current name and use that.

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
