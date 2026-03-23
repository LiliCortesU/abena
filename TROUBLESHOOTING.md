# Troubleshooting Guide

Common errors encountered during Abena setup and how to resolve them.

---

## apt: `Unable to connect to deb.debian.org:http`

> ⚠️ **If you followed the setup order and completed `01b-squid-proxy`, this error should not occur.** The Squid transparent proxy handles all outbound HTTP/HTTPS from containers automatically. If you see this error, check that Squid is running on the Proxmox host and the iptables REDIRECT rules are in place — see [01b — Squid Transparent Proxy](../01b-squid-proxy/README.md).

### Symptoms
```
E: Failed to fetch http://deb.debian.org/pool/...  Unable to connect to deb.debian.org:http:
E: Unable to fetch some archives, maybe run apt-get update or try with --fix-missing?
```

### Root Cause Analysis

This error has a non-obvious root cause. Here is what was found through systematic debugging:

| Test | Result |
|------|--------|
| Container → ping `8.8.8.8` | ✅ Works |
| Container → `apt update` from `deb.debian.org` HTTPS | ✅ Works |
| Container → `apt install` `.deb` files from `deb.debian.org` HTTP | ❌ Blocked |
| Container → third-party HTTPS mirror | ❌ Blocked |
| Proxmox host → full internet | ✅ Works |

The router blocks outbound HTTP (port 80) **and** connections to unknown domains for IPs it did not assign via DHCP. Containers on `vmbr1` get IPs from dnsmasq (`10.10.10.x`) which the router doesn't know about.

Key distinction: `apt update` succeeds because it uses `sources.list` (set to HTTPS `deb.debian.org` which the router allows), but `apt install` fetches the actual `.deb` package files from URLs embedded in package metadata — these are hardcoded to `http://` and get blocked.

Switching to a third-party HTTPS mirror also fails because the router blocks unknown domains even on port 443.

### Fix A — Force HTTPS for apt downloads (did not work)
apt fetches `.deb` URLs from package metadata which are hardcoded to `http://`. The `ForceIPv4` config does not rewrite these URLs. This fix is ineffective for this specific issue.

### Fix B — Third-party HTTPS mirror (did not work)
The router blocks connections to unknown domains even on port 443. Only known/whitelisted domains like `deb.debian.org` are allowed.

### Fix C — Open port 80 on the router
If your router allows it, permit outbound port 80 from the Proxmox host's LAN IP. All container traffic is NATted through the host, so the router sees it as the host's IP. This is the most permanent fix but requires router access and depends on your router model.

### ✅ Fix D — apt-cacher-ng with direct proxy URLs in sources.list (confirmed working)

The most reliable solution. Run a caching apt proxy on the Proxmox host, which has unrestricted internet access, and embed the proxy address directly in `sources.list` URLs.

> Note: Using `Acquire::http::Proxy` in apt.conf did NOT work reliably — apt bypassed the proxy and connected directly. Embedding the proxy in `sources.list` URLs is the confirmed working method.

**On the Proxmox host (run once):**
```bash
apt install -y apt-cacher-ng
systemctl enable --now apt-cacher-ng
ss -tlnp | grep 3142   # Verify listening

# Allow containers to reach the proxy
iptables -A INPUT -i vmbr1 -p tcp --dport 3142 -j ACCEPT
netfilter-persistent save
```

**Inside each container:**
```bash
cat > /etc/apt/sources.list << 'EOF'
deb http://10.10.10.254:3142/deb.debian.org/debian bookworm main contrib non-free non-free-firmware
deb http://10.10.10.254:3142/deb.debian.org/debian bookworm-updates main contrib non-free non-free-firmware
deb http://10.10.10.254:3142/security.debian.org/debian-security bookworm-security main contrib non-free non-free-firmware
EOF
apt update
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

## Bazarr: `PermissionError(13, 'Permission denied')` saving subtitle files

### Symptoms
```
ERROR (download:118) - BAZARR Error saving Subtitles file to disk for this file
/mnt/media/movies/.../foo.mp4: PermissionError(13, 'Permission denied')
```
Bazarr downloads subtitles successfully but cannot write them next to the media files.

### Root Cause
The `bazarr` process has stale group membership. The `bazarr` user is in the `media` group in `/etc/group`, but the running process was started before that group membership existed — so the process's effective groups do not include `media`, and it cannot write to directories owned by `sonarr:media`.

You can confirm the process lacks the group:
```bash
cat /proc/$(pgrep -f "bazarr.py" | head -1)/status | grep Groups
# If media GID (1001) is missing, this is the cause
```

And confirm the user itself is correct:
```bash
id bazarr   # should show groups=...,media
su -s /bin/bash bazarr -c "touch /mnt/media/movies/test.txt && echo OK"
# If this prints OK, the user is fine — it's the running process that's stale
```

### Fix
Restart the service so the new process inherits current group membership:
```bash
systemctl restart bazarr
# Confirm the live process now has the media GID
cat /proc/$(pgrep -f "bazarr.py" | head -1)/status | grep Groups
```

### Prevention
Always verify `id bazarr` shows the `media` group **before** starting the service for the first time. If you add the user to a group after the service is already running, you must restart it.

---

## Bazarr: port 6767 already in use after restart / zombie child processes

### Symptoms
```
ERROR (server:64) - BAZARR cannot bind to default TCP port (6767) because it's already in use, exiting...
```
After `systemctl restart bazarr`, the new instance immediately exits. `pgrep -af bazarr` shows more than two processes.

### Root Cause
Bazarr's `bazarr.py` spawns `main.py` as a child process. With `KillMode=process` in the service file, systemd only kills the direct child (`bazarr.py`) on stop/restart — the grandchild (`main.py`) survives, continues holding port 6767, and blocks the new instance from binding.

### Fix
Kill the orphaned process manually and fix the service file:
```bash
# Find and kill the stale main.py
kill -9 $(pgrep -f "main.py" | head -1)

# Fix the service so this can't happen again
sed -i 's/KillMode=process/KillMode=control-group/' /etc/systemd/system/bazarr.service
systemctl daemon-reload
systemctl restart bazarr

# Verify only two processes remain (bazarr.py + main.py)
pgrep -af bazarr
```

`KillMode=control-group` tells systemd to kill every process in the service's cgroup on stop, not just the direct child.

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
