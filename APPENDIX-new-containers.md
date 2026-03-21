# Appendix — Adding New Containers to Abena

This guide covers everything needed to set up any new LXC container on Abena so it works correctly within the existing network and proxy infrastructure.

---

## Background: Network Access for Containers

Containers on `vmbr1` (`10.10.10.0/24`) have full internet access routed through two layers:

- **Squid transparent proxy** (Proxmox host, port 3129/3130) — intercepts all HTTP/HTTPS traffic from `vmbr1` and forwards it through the host's unrestricted internet connection. Containers require no special configuration — they behave as if they have direct internet access.
- **apt-cacher-ng** (Proxmox host, port 3142) — caching proxy for apt packages. `sources.list` is configured to use proxy URLs for faster repeated installs.

**If Squid is running correctly**, containers can make direct HTTP/HTTPS connections to any external server. Install scripts, `curl`, `wget`, and service API calls all work normally.

**If Squid is not running** (e.g. not yet set up, or crashed), fall back to the host-as-intermediary approach: download files on the Proxmox host and push them into containers with `pct push`. See [01b — Squid Transparent Proxy](../01b-squid-proxy/README.md) to set up or restore Squid.

---

## Step 1 — Create the Container

```bash
# Check the current template name first
pveam available --section system | grep debian-12

# Create the container (adjust ID, name, RAM, and disk to your needs)
pct create <ID> local:vztmpl/debian-12-standard_<version>_amd64.tar.zst \
  --hostname <name> \
  --memory <MB> \
  --net0 name=eth0,bridge=vmbr1,ip=dhcp \
  --rootfs local-lvm:<GB> \
  --unprivileged 1 \
  --features nesting=1 \
  --onboot 1 \
  --start 1
```

**Network options:**
- Internal only: `--net0 name=eth0,bridge=vmbr1,ip=dhcp`
- LAN + internal (dual-homed): add `--net1 name=eth1,bridge=vmbr0,ip=dhcp`
- Privileged (for bind mounts): change `--unprivileged 1` to `--unprivileged 0`

---

## Step 2 — Configure apt

### On the Proxmox host

Ensure `apt-cacher-ng` is running (only needed once across all containers):

```bash
systemctl status apt-cacher-ng
# If not running:
apt install -y apt-cacher-ng
systemctl enable --now apt-cacher-ng

# Ensure containers can reach it
iptables -C INPUT -i vmbr1 -p tcp --dport 3142 -j ACCEPT 2>/dev/null \
  || iptables -A INPUT -i vmbr1 -p tcp --dport 3142 -j ACCEPT
netfilter-persistent save
```

### Inside the container

```bash
pct enter <ID>

# Rewrite sources.list to route through the proxy
cat > /etc/apt/sources.list << 'EOF'
deb http://10.10.10.254:3142/deb.debian.org/debian bookworm main contrib non-free non-free-firmware
deb http://10.10.10.254:3142/deb.debian.org/debian bookworm-updates main contrib non-free non-free-firmware
deb http://10.10.10.254:3142/security.debian.org/debian-security bookworm-security main contrib non-free non-free-firmware
EOF

apt update
```

---

## Step 3 — Fix Locale (optional but recommended)

```bash
apt install -y locales
dpkg-reconfigure locales
# Select en_US.UTF-8, set as default, then:
reboot
```

---

## Step 4 — Register the Container's MAC in dnsmasq

For a stable internal IP, add the container's MAC to CT100's dnsmasq config.

```bash
# Get the MAC from the Proxmox host
pct config <ID> | grep hwaddr

# Enter CT100 and add the entry
pct enter 100
vi /etc/dnsmasq.conf

# Add a line in the dhcp-host section:
# dhcp-host=<MAC>,10.10.10.<X>,<hostname>
# And a DNS entry:
# address=/<hostname>.local/10.10.10.<X>

rc-service dnsmasq restart
exit
```

Choose an IP in the `10.10.10.18`–`10.10.10.99` range (outside the DHCP pool of `.100`–`.200`).

---

## Step 5 — Installing Software

### apt packages (straightforward)

```bash
# Inside the container — works via proxy
apt install -y <package>
```

### Third-party apt repos

Always fetch GPG keys and add repo sources from the **Proxmox host**:

```bash
# On Proxmox host — fetch key and push into container
curl -fsSL <key-url> \
  | gpg --dearmor \
  | pct exec <ID> -- tee /usr/share/keyrings/<name>.gpg > /dev/null

# Add repo through proxy (replace <repo-domain> with the actual domain)
pct exec <ID> -- bash -c \
  'echo "deb [signed-by=/usr/share/keyrings/<name>.gpg] \
  http://10.10.10.254:3142/<repo-domain>/<path> bookworm main" \
  > /etc/apt/sources.list.d/<name>.list'

pct exec <ID> -- apt update
pct exec <ID> -- apt install -y <package>
```

### Install scripts (curl | bash)

Be cautious with install scripts. Some scripts download additional binaries from inside the container after they start running — those downloads will fail because the container can't reach external servers directly, even if the script itself was piped from the host.

**Safe — script doesn't download anything internally:**
```bash
# On Proxmox host
curl -fsSL <script-url> | pct exec <ID> -- bash
```

**Unsafe — script downloads binaries internally (e.g. Sonarr, Radarr):**
In this case, skip the install script entirely. Download the binary directly on the host and push it in:
```bash
# On Proxmox host
curl -fsSL <binary-url> -o /tmp/<file>
pct push <ID> /tmp/<file> /tmp/<file>
pct exec <ID> -- tar -xzf /tmp/<file> -C /opt/
# Then create systemd service manually
```

### Binaries and release archives

Download on the host, push into the container:

```bash
# On Proxmox host
curl -fsSL <binary-url> -o /tmp/<file>
pct push <ID> /tmp/<file> /tmp/<file>
pct exec <ID> -- <extract or install command>
```

### Git repositories

Clone on the host, archive, push into container:

```bash
# On Proxmox host
git clone <repo-url> /tmp/<repo>
tar -czf /tmp/<repo>.tar.gz -C /tmp <repo>
pct push <ID> /tmp/<repo>.tar.gz /tmp/<repo>.tar.gz
pct exec <ID> -- tar -xzf /tmp/<repo>.tar.gz -C /opt/
```

### npm / pip packages

These work inside the container if they only pull from the package registry (npm, PyPI) using HTTP, which goes through `npm`/`pip`'s own mechanisms. If they fail, install from the host side:

```bash
# npm — runs inside container (usually fine)
pct exec <ID> -- npm install -g <package>

# pip — runs inside container (usually fine)
pct exec <ID> -- pip install <package>
```

If either fails with a connection error, download the package on the host and push it in manually.

---

## Step 6 — Add to Watchdog Monitoring

Add a monitor in Uptime Kuma (`http://<watchdog-lan-ip>:3001`):

- **Type:** HTTP(s) or TCP Port depending on the service
- **URL/Host:** `http://10.10.10.<X>:<port>` (internal IP)
- **Name:** descriptive name
- **Interval:** 60 seconds

---

## Step 7 — Add to Backup Schedule

In the Proxmox web UI: Datacenter → Backup → select your backup job → Edit → add the new container ID to the list.

---

## Quick Reference Card

| Task | Where to run | Method |
|------|-------------|--------|
| `apt install` | Inside container | Direct (via proxy in sources.list) |
| GPG key fetch | Proxmox host | `curl \| gpg \| pct exec tee` |
| Install script | Proxmox host | `curl \| pct exec bash` |
| Binary/archive | Proxmox host | `curl -o` then `pct push` |
| Git repo | Proxmox host | `git clone` then `tar + pct push` |
| npm/pip packages | Inside container | Direct (usually works) |
| Third-party apt repo | Proxmox host | Proxy URL in sources.list |

---

## Checklist for Every New Container

- [ ] Created with `--features nesting=1`
- [ ] `sources.list` rewritten to use `10.10.10.254:3142` proxy URLs
- [ ] No direct external connections made from inside the container
- [ ] MAC registered in CT100 dnsmasq for stable IP
- [ ] Monitor added to Uptime Kuma
- [ ] Container ID added to backup schedule
- [ ] `--onboot 1` set so it starts on Proxmox reboot
