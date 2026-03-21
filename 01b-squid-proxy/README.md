# 01b — Squid Transparent Proxy

## Why This Exists

Containers on `vmbr1` cannot reach most external servers directly. The router performs domain-based filtering on traffic from IPs it did not assign — only a small allowlist of domains (like `deb.debian.org`) is permitted outbound. Everything else is silently dropped.

This affects not just installation but **runtime** as well:
- Prowlarr cannot download indexer definitions
- Sonarr/Radarr cannot fetch metadata or RSS feeds
- n8n workflows cannot call external APIs
- Netbird cannot reach its coordination server
- Docker cannot pull image updates

The solution is a **Squid transparent proxy** running on the Proxmox host. It intercepts all outbound HTTP and HTTPS traffic from `vmbr1` and forwards it through the host's unrestricted internet connection. Containers require no configuration — they behave as if they have direct internet access.

---

## How It Works

```
Container (10.10.10.x)
    │
    │ HTTP/HTTPS request (port 80/443)
    │
    ▼
iptables REDIRECT rule on Proxmox host (vmbr1 interface)
    │
    │ redirects to Squid on port 3129
    │
    ▼
Squid proxy (listening on 10.10.10.254:3129)
    │
    │ forwards through host's unrestricted internet
    │
    ▼
External server (prowlarr.servarr.com, github.com, etc.)
```

For HTTP — Squid fetches content on behalf of the container.
For HTTPS — Squid establishes a TCP tunnel (CONNECT method) without decrypting — no certificate issues.

> **Critical:** Containers must use `10.10.10.254` (Proxmox host) as their default gateway, not `10.10.10.1` (dnsmasq). Traffic must reach the Proxmox host's PREROUTING chain to be intercepted by Squid. This is configured in Step 4.

---

## Conflict Analysis With Existing Setup

| Existing component | Conflict? | Notes |
|-------------------|-----------|-------|
| `apt-cacher-ng` (port 3142) | ✅ None | Different port — continues working unchanged |
| `sources.list` proxy URLs (`10.10.10.254:3142`) | ✅ None | Port 3142 not intercepted by Squid |
| MASQUERADE iptables rule | ✅ None | Still needed — Squid uses it to reach the internet |
| INPUT rule for port 3142 | ✅ None | Still needed for apt-cacher-ng |
| IP forwarding (`net.ipv4.ip_forward=1`) | ✅ None | Still required |
| dnsmasq in CT100 | ⚠️ Gateway | dnsmasq must advertise `10.10.10.254` as gateway, not itself — fixed in Step 4 |

---

## Step 1 — Install Squid on the Proxmox Host

```bash
apt install -y squid
```

---

## Step 2 — Configure Squid

```bash
# Back up the default config
cp /etc/squid/squid.conf /etc/squid/squid.conf.bak

# Write a clean config
cat > /etc/squid/squid.conf << 'EOF'
# Squid transparent proxy for Abena vmbr1 containers

# Standard port for explicit proxy
http_port 3128

# Intercept port for transparent HTTP
http_port 3129 intercept

# Access control
acl vmbr1_net src 10.10.10.0/24
acl Safe_ports port 80
acl Safe_ports port 443
acl Safe_ports port 3142
acl CONNECT method CONNECT

http_access deny !Safe_ports
http_access allow CONNECT vmbr1_net
http_access allow vmbr1_net
http_access allow localhost
http_access deny all

# Cache settings
cache_mem 64 MB
maximum_object_size 100 MB
cache_dir ufs /var/spool/squid 1000 16 256

# Logging
access_log /var/log/squid/access.log
cache_log /var/log/squid/cache.log

forwarded_for off
EOF
```

---

## Step 3 — Initialize Cache and Start Squid

```bash
squid -z
systemctl enable --now squid
systemctl status squid --no-pager
ss -tlnp | grep squid
# Should show squid listening on port 3129
```

---

## Step 4 — Fix the Default Gateway in dnsmasq (Critical)

By default dnsmasq advertises itself (`10.10.10.1`) as the gateway for containers. This means container traffic goes to CT100 (a container with no internet), never reaching the Proxmox host's PREROUTING chain where Squid intercepts it.

Fix dnsmasq to advertise the Proxmox host (`10.10.10.254`) as the gateway:

```bash
pct enter 100

cat >> /etc/dnsmasq.conf << 'EOF'

# Default gateway — point to Proxmox host so traffic reaches Squid
dhcp-option=3,10.10.10.254
EOF

rc-service dnsmasq restart
exit
```

Force all running containers to renew their DHCP lease:

```bash
for id in 101 102 103 104 105 106 107; do
  pct exec $id -- dhclient -r eth0 2>/dev/null || true
  pct exec $id -- dhclient eth0 2>/dev/null || true
  echo "CT${id}: $(pct exec $id -- ip route show 2>/dev/null | grep default)"
done
```

All containers should now show `default via 10.10.10.254`.

> Note: Dual-homed containers (CT101 Samba, CT103 n8n, etc.) that have `eth0` on `vmbr0` will show their LAN gateway — this is correct for those containers.

---

## Step 5 — Add iptables Redirect Rules

Redirect HTTP traffic from `vmbr1` containers through Squid:

```bash
# Redirect HTTP (port 80) to Squid intercept port
iptables -t nat -A PREROUTING -i vmbr1 -p tcp --dport 80 -j REDIRECT --to-port 3129

# Allow Squid traffic through INPUT chain
iptables -A INPUT -i vmbr1 -p tcp --dport 3129 -j ACCEPT

# Save all rules
netfilter-persistent save
```

> Note: HTTPS (port 443) traffic reaches external servers via the existing MASQUERADE rule without needing a separate redirect — Squid handles CONNECT tunnels for HTTPS automatically through port 3128.

---

## Step 6 — Verify

```bash
# Test HTTP interception
pct exec 102 -- curl -s --max-time 10 http://example.com | grep -o '<title>.*</title>'
# Should return: <title>Example Domain</title>

# Test HTTPS tunnel
pct exec 102 -- curl -s --max-time 10 https://prowlarr.servarr.com && echo "OK"
pct exec 102 -- curl -s --max-time 10 https://api.github.com && echo "OK"

# Verify Squid is logging traffic
tail -5 /var/log/squid/access.log
```

---

## Resilience

- `systemctl enable squid` ensures Squid starts on boot
- If Squid goes down, containers lose internet but internal communication (`vmbr1`) is unaffected
- `apt-cacher-ng` continues to serve cached packages independently

---

## Checkpoint

- [ ] Squid running on Proxmox host (port 3129)
- [ ] dnsmasq advertising `10.10.10.254` as gateway
- [ ] All containers showing `default via 10.10.10.254`
- [ ] iptables REDIRECT rule in place for port 80
- [ ] `curl http://example.com` from CT102 returns `Example Domain`
- [ ] `curl https://prowlarr.servarr.com` from CT102 returns OK
- [ ] Rules persisted with `netfilter-persistent save`

**Next:** [02 — Samba](../02-samba/README.md)

## Why This Exists

Containers on `vmbr1` cannot reach most external servers directly. The router performs domain-based filtering on traffic from IPs it did not assign — only a small allowlist of domains (like `deb.debian.org`) is permitted outbound. Everything else is silently dropped.

This affects not just installation but **runtime** as well:
- Prowlarr cannot download indexer definitions
- Sonarr/Radarr cannot fetch metadata or RSS feeds
- n8n workflows cannot call external APIs
- Netbird cannot reach its coordination server
- Docker cannot pull image updates

The solution is a **Squid transparent proxy** running on the Proxmox host. It intercepts all outbound HTTP and HTTPS traffic from `vmbr1` and forwards it through the host's unrestricted internet connection. Containers require no configuration — they behave as if they have direct internet access.

---

## How It Works

```
Container (10.10.10.x)
    │
    │ HTTP/HTTPS request (port 80/443)
    │
    ▼
iptables REDIRECT rule on Proxmox host
    │
    │ redirects to port 3128
    │
    ▼
Squid proxy (10.10.10.254:3128)
    │
    │ forwards through host's unrestricted internet
    │
    ▼
External server (deb.debian.org, prowlarr.servarr.com, etc.)
```

For HTTP — Squid fetches the content on behalf of the container.
For HTTPS — Squid establishes a TCP tunnel (CONNECT method) without decrypting — no certificate issues.

---

## Conflict Analysis With Existing Setup

| Existing component | Conflict? | Notes |
|-------------------|-----------|-------|
| `apt-cacher-ng` (port 3142) | ✅ None | Different port — continues working unchanged |
| `sources.list` proxy URLs (`10.10.10.254:3142`) | ✅ None | Port 3142 is not intercepted by Squid |
| MASQUERADE iptables rule | ✅ None | Still needed — Squid uses it to reach the internet |
| INPUT rule for port 3142 | ✅ None | Still needed for apt-cacher-ng |
| CT102 eth1 temporary LAN interface | ✅ None | Can be removed after Squid is working |
| IP forwarding (`net.ipv4.ip_forward=1`) | ✅ None | Still required |
| dnsmasq in CT100 | ✅ None | DNS unaffected |

After Squid is set up:
- `apt-cacher-ng` continues to serve apt packages via port 3142 (caching benefit)
- Squid handles all other HTTP/HTTPS traffic
- The `sources.list` proxy URLs are no longer strictly necessary but cause no harm — apt traffic hits apt-cacher-ng on 3142, which is not intercepted by Squid

---

## Step 1 — Install Squid on the Proxmox Host

```bash
apt install -y squid
```

---

## Step 2 — Configure Squid

```bash
# Back up the default config
cp /etc/squid/squid.conf /etc/squid/squid.conf.bak

# Write a clean config
cat > /etc/squid/squid.conf << 'EOF'
# Squid transparent proxy for Abena vmbr1 containers

# Ports
http_port 3128
http_port 3129 intercept
https_port 3130 intercept ssl-bump \
    cert=/etc/squid/ssl_cert/myCA.pem \
    key=/etc/squid/ssl_cert/myCA.pem \
    generate-host-certificates=on \
    dynamic_cert_mem_cache_size=4MB

# SSL bump — tunnel mode only, no decryption
ssl_bump tunnel all

# Access control
acl vmbr1_net src 10.10.10.0/24
acl SSL_ports port 443
acl Safe_ports port 80
acl Safe_ports port 443
acl Safe_ports port 3142
acl CONNECT method CONNECT

http_access deny !Safe_ports
http_access allow vmbr1_net
http_access allow localhost
http_access deny all

# Performance
cache_mem 64 MB
maximum_object_size 100 MB
cache_dir ufs /var/spool/squid 1000 16 256

# Logging
access_log /var/log/squid/access.log
cache_log /var/log/squid/cache.log

# Don't add X-Forwarded-For headers (privacy)
forwarded_for off
EOF
```

---

## Step 3 — Generate SSL Certificate for HTTPS Tunneling

Squid needs a certificate to handle HTTPS tunnel requests. This certificate is used for the tunnel handshake only — traffic is **not** decrypted.

```bash
mkdir -p /etc/squid/ssl_cert
cd /etc/squid/ssl_cert

# Generate a self-signed CA certificate
openssl req -new -newkey rsa:2048 -days 3650 -nodes -x509 \
  -subj "/C=CO/ST=Bogota/O=Abena/CN=AbenaProxy" \
  -keyout myCA.pem -out myCA.pem

chown proxy:proxy /etc/squid/ssl_cert/myCA.pem
chmod 600 /etc/squid/ssl_cert/myCA.pem

# Initialize SSL certificate cache
/usr/lib/squid/security_file_certgen -c -s /var/spool/squid/ssl_db -M 4MB
chown -R proxy:proxy /var/spool/squid/ssl_db
```

---

## Step 4 — Initialize Squid Cache and Start

```bash
# Initialize the cache directory
squid -z

# Start and enable Squid
systemctl enable --now squid

# Verify it's running
systemctl status squid --no-pager
ss -tlnp | grep squid
# Should show ports 3128, 3129, 3130
```

---

## Step 5 — Add iptables Redirect Rules

This is the key step — redirect all HTTP and HTTPS traffic from `vmbr1` containers through Squid before it hits the router:

```bash
# Redirect HTTP (port 80) from vmbr1 containers to Squid intercept port
iptables -t nat -A PREROUTING -i vmbr1 -p tcp --dport 80 -j REDIRECT --to-port 3129

# Redirect HTTPS (port 443) from vmbr1 containers to Squid SSL intercept port
iptables -t nat -A PREROUTING -i vmbr1 -p tcp --dport 443 -j REDIRECT --to-port 3130

# Allow Squid traffic through INPUT chain
iptables -A INPUT -i vmbr1 -p tcp --dport 3129 -j ACCEPT
iptables -A INPUT -i vmbr1 -p tcp --dport 3130 -j ACCEPT

# Save all rules
netfilter-persistent save
```

---

## Step 6 — Test From a Container

```bash
# Test HTTP
pct exec 102 -- curl -s --max-time 10 http://example.com | grep -o '<title>.*</title>'

# Test HTTPS
pct exec 102 -- curl -s --max-time 10 https://prowlarr.servarr.com && echo "OK" || echo "FAILED"

# Test that Prowlarr can now load indexers
pct exec 102 -- curl -s --max-time 10 https://apt.sonarr.tv && echo "OK" || echo "FAILED"
```

---

## Step 7 — Clean Up CT102

Now that containers have real internet access, remove the temporary workarounds from CT102:

```bash
# Remove the temporary LAN interface if still present
pct set 102 --delete net1 2>/dev/null || true

# The sources.list proxy URLs still work fine and can stay
# But standard URLs now also work — no action needed
```

---

## Step 8 — Update sources.list in Future Containers (Optional)

With Squid running, future containers can use standard Debian mirror URLs directly — no need for the proxy URL format. Either approach works:

**Standard (works with Squid):**
```bash
cat > /etc/apt/sources.list << 'EOF'
deb http://deb.debian.org/debian bookworm main contrib non-free non-free-firmware
deb http://deb.debian.org/debian bookworm-updates main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security bookworm-security main contrib non-free non-free-firmware
EOF
```

**Proxy URL format (also still works via apt-cacher-ng):**
```bash
# This continues to work exactly as before — no change needed
deb http://10.10.10.254:3142/deb.debian.org/debian bookworm main ...
```

Both are valid. The proxy URL format has the added benefit of caching packages.

---

## Resilience

```bash
# Squid auto-restarts on crash
systemctl status squid | grep Restart
# Should show: Restart=on-failure (set by the systemd unit)

# If Squid goes down, containers lose internet but can still:
# - Communicate with each other (vmbr1 internal traffic unaffected)
# - Be reached from LAN via dual-homed interfaces
# - Be reached via Netbird (once connected)
# apt-cacher-ng continues to serve cached packages
```

---

## Troubleshooting

**Squid not intercepting traffic:**
```bash
# Check iptables rules are present
iptables -t nat -L PREROUTING -n -v | grep REDIRECT

# Check Squid logs
tail -f /var/log/squid/access.log
```

**SSL certificate errors in containers:**
```bash
# This should not happen in tunnel mode — if it does, check ssl_bump config
grep ssl_bump /etc/squid/squid.conf
# Must show: ssl_bump tunnel all
```

**Squid using too much memory:**
```bash
# Reduce cache_mem in /etc/squid/squid.conf
# Default 64MB is conservative — safe for 8GB system
```

---

## Checkpoint

- [ ] Squid running on Proxmox host (ports 3128, 3129, 3130)
- [ ] iptables REDIRECT rules in place for ports 80 and 443 from vmbr1
- [ ] `pct exec 102 -- curl https://prowlarr.servarr.com` returns OK
- [ ] Prowlarr web UI can load indexer list
- [ ] apt-cacher-ng still working on port 3142
- [ ] Rules persisted with `netfilter-persistent save`
