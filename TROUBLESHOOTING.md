# Troubleshooting Guide

Common errors encountered during Abena setup and how to resolve them.

---

## apt: `Unable to connect to deb.debian.org:http`

### Symptoms
```
E: Failed to fetch http://deb.debian.org/pool/...  Unable to connect to deb.debian.org:http:
E: Unable to fetch some archives, maybe run apt-get update or try with --fix-missing?
```

### Root Cause
Your router is blocking outbound **port 80 (HTTP)** for IPs it did not assign via DHCP. Containers on the internal `vmbr1` bridge get IPs from dnsmasq (`10.10.10.x`), which the router doesn't know about. The router sees this traffic as suspicious and drops it.

Note: `apt update` may succeed because it uses your `sources.list` (which we set to HTTPS), but `apt install` fetches the actual `.deb` package files from URLs embedded in package metadata — these still point to `http://`. The `ForceIPv4` config forces IPv4 but does **not** force HTTPS for package downloads.

### Fix A — Force HTTPS for all apt downloads

Run inside the affected container:

```bash
cat > /etc/apt/apt.conf.d/98force-https << 'EOF'
Acquire::http::Proxy "DIRECT";
Acquire::ForceIPv4 "true";
EOF
```

Then retry the install.

### Fix B — Switch to a mirror with full HTTPS support

Some mirrors serve `.deb` files natively over HTTPS without HTTP redirects:

```bash
cat > /etc/apt/sources.list << 'EOF'
deb https://mirror.debian.ikoula.com/debian/ bookworm main contrib non-free non-free-firmware
deb https://mirror.debian.ikoula.com/debian/ bookworm-updates main contrib non-free non-free-firmware
deb https://mirror.debian.ikoula.com/debian-security/ bookworm-security main contrib non-free non-free-firmware
EOF
apt update
```

Then retry the install.

### Fix C — Open port 80 on your router

All container traffic exits through the Proxmox host's LAN IP (via NAT). If your router allows it, add a rule permitting outbound port 80 from the Proxmox host's IP. This is the most permanent solution and requires no changes to containers.

### Fix D — apt-cacher-ng proxy on the Proxmox host

Run a caching apt proxy on the Proxmox host (which has full internet access). Containers route all apt traffic through it over the internal `vmbr1` network, bypassing the router restriction entirely.

```bash
# On Proxmox host
apt install -y apt-cacher-ng
systemctl enable --now apt-cacher-ng
# Listens on port 3142
```

Then in each container:
```bash
echo 'Acquire::http::Proxy "http://10.10.10.254:3142";' > /etc/apt/apt.conf.d/00proxy
```

---

## apt: `Unable to locate package software-properties-common`

### Symptoms
```
E: Unable to locate package software-properties-common
```

### Root Cause
`software-properties-common` is an Ubuntu-centric package for managing PPAs. It is not reliably available on all Debian versions and is not needed for any service in this stack.

### Fix
Simply omit it from the install command. None of the tools installed (Jellyfin, Sonarr, Radarr, Prowlarr, qBittorrent) require it on Debian.

---

## Container creation: `400 Parameter verification failed — no such template`

### Symptoms
```
400 Parameter verification failed.
template: no such template
```

### Root Cause
The template filename is version-pinned (e.g. `debian-12-standard_12.7-1`) but Proxmox's available list has moved to a newer version.

### Fix
Always query the live list before downloading:
```bash
pveam update
pveam available --section system | grep debian-12
# Use the exact name from the output above
pveam download local <exact-template-name>
```

---

## Container creation: `WARN: Systemd 252 detected. You may need to enable nesting.`

### Symptoms
```
WARN: Systemd 252 detected. You may need to enable nesting.
```

### Root Cause
Modern Debian 12+ containers use systemd 252+, which requires the `nesting` LXC feature to function correctly inside a container. Without it, systemd services may fail to start after reboots.

### Fix
If the container was already created without `--features nesting=1`:
```bash
pct stop <ID>
pct set <ID> --features nesting=1
pct start <ID>
```

For new containers, always include `--features nesting=1` in the `pct create` command. All container creation commands in this repo already include it.

---

## apt: Locale warnings during `systemctl enable`

### Symptoms
```
perl: warning: Setting locale failed.
perl: warning: Please check that your locale settings:
        LANG = "en_US.UTF-8"
    are supported and installed on your system.
perl: warning: Falling back to the standard locale ("C").
```

### Root Cause
Fresh LXC containers don't have locale data generated. This is cosmetic — it does not affect functionality.

### Fix
```bash
apt install -y locales
locale-gen en_US.UTF-8
update-locale LANG=en_US.UTF-8
```

---

## IP forwarding not working after reboot

### Symptoms
Containers can ping the gateway (`10.10.10.254`) but cannot reach the internet (`8.8.8.8`).

### Root Cause
The `sysctl.conf` file on some Proxmox versions does not contain the `net.ipv4.ip_forward` line, so the `sed` command to uncomment it silently does nothing. IP forwarding defaults to `0` after reboot.

### Fix
```bash
# On Proxmox host
echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-ip-forward.conf
sysctl -p /etc/sysctl.d/99-ip-forward.conf

# Verify
sysctl net.ipv4.ip_forward
# Must show: net.ipv4.ip_forward = 1
```

---

## systemd service: `status=203/EXEC`

### Symptoms
```
Active: activating (auto-restart) (Result: exit-code)
Main PID: xxx (code=exited, status=203/EXEC)
```

### Root Cause
systemd cannot find or execute the binary specified in `ExecStart`. This usually means the package install failed silently (due to a network error) and the binary was never installed.

### Fix
Verify the package is actually installed:
```bash
dpkg -l | grep <package-name>
```

If no output, the install failed. Fix the underlying apt connectivity issue (see above) and reinstall:
```bash
apt install -y <package-name>
```

Then find the correct binary path and update the service if needed:
```bash
which <binary-name>
```

---

## Container has no internet despite correct NAT rule

### Symptoms
- `ping 10.10.10.254` works (gateway reachable)
- `ping 8.8.8.8` fails (no internet)
- NAT rule exists: `iptables -t nat -L POSTROUTING` shows MASQUERADE rule

### Root Cause
IP forwarding is disabled (`net.ipv4.ip_forward = 0`). The NAT rule exists but packets aren't being forwarded between interfaces.

### Fix
See "IP forwarding not working after reboot" above.
