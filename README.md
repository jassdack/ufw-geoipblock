# geoipblock

A script to automate GeoIP filtering for Linux servers using `xtables-addons` and `UFW`. It manages country-based blocking/allowing by injecting rules into UFW's `before.rules`.

## 🛡️ Architecture

The script adds a multi-phase filtering block to UFW without overwriting existing configurations:

1.  **Phase 1: ipset Blacklist**: Drops traffic from IPs matched in the `persistent_offenders` ipset.
2.  **Phase 2: State Management**: Uses `conntrack` (`RELATED,ESTABLISHED`) to allow existing active sessions.
3.  **Phase 3: Local Network**: Automatically detects and allows traffic from the host's directly attached local subnets.
4.  **Phase 4: GeoIP Filtering**: Uses `xt_geoip` to match countries. Non-permitted TCP/UDP traffic is logged (with rate limits) and dropped.

## ✨ Features

- **Auto-Rollback (Dead Man's Switch)**: If you do not run `geoipblock-confirm` within 3 minutes of installation, the firewall changes are automatically reverted to prevent accidental SSH lockouts.
- **Daily Updates**: GeoIP databases are updated daily via a systemd timer. Updates are built in a temporary directory and swapped atomically using `mv`.
- **Download Retries**: If the GeoIP database download fails, it retries 3 times before aborting safely.
- **CSV Configuration**: Manage ports and ranges using a simple CSV file.

## 🎯 Target Use Case & Sweet Spot

This tool is designed for a specific "sweet spot" in server management:

### Ideal Environment
1.  **Debian/Ubuntu Standalone Servers**: Best for "pet" servers where you manage the OS directly (VPS providers like DigitalOcean, Linode, Vultr, or bare metal).
2.  **Bare-Metal Services**: Optimized for environments where services (sshd, nginx, postfix, etc.) run directly on the host OS rather than in containers.
3.  **Direct Internet Connection**: Best for servers that interact directly with client IP addresses at the transport layer (L4).
4.  **Solo Devs & Small Teams**: Perfect for those who need a practical, quick solution to stop overseas brute-force attacks and port scans without the complexity of enterprise-grade IaC.

### 🙅 When NOT to use this tool
- **Docker-based environments**: Docker bypasses the UFW rules used by this script.
- **Behind CDNs (Cloudflare, etc.)**: You will likely block the CDN's edge nodes, affecting legitimate users.
- **Cloud-Native Managed Infrastructure**: If you are on AWS/GCP/Azure, use Security Groups or cloud WAFs which are more efficient at the infrastructure level.

## 📋 Prerequisites

The `install.sh` script attempts to install the following dependencies via `apt-get` on Debian/Ubuntu systems:
- `xtables-addons-common`, `libtext-csv-xs-perl`, `ipset`, `pkg-config`, `ufw`, `curl`

## 🚀 Installation

```bash
git clone https://github.com/jassdack/geoipblock.git
cd geoipblock

# Option A: Dry-Run (Print rules without applying)
sudo ./install.sh --dry-run JP ports.csv

# Option B: Apply configuration from CSV
sudo ./install.sh JP ports.csv

# Option C: Apply configuration from command line
sudo ./install.sh JP 22,80,443

# Option D: Allow multiple countries
# Separate country codes with commas
sudo ./install.sh JP,US,TW ports.csv
```

### 🚨 Installation Workflow & Rollback
To prevent accidental lockouts, the script uses a 3-minute confirmation window:
1. Run `./install.sh`.
2. Open a **NEW** terminal window and verify you can still SSH into your server.
3. If successful, run the following command in your original terminal to keep the rules:
   ```bash
   sudo geoipblock-confirm
   ```
4. If you fail to run the confirm command within 3 minutes, the GeoIP rules are automatically removed and UFW is reloaded.

### 📝 CSV Configuration Example (`ports.csv`)
The format is `port_range,memo,status`.
```csv
22,SSH Access,block
80,HTTP Web,block
443,HTTPS Secure,block
3000:3010,Dev Web Servers,pass
```
*To disable GeoIP filtering for a rule, change its status to `pass` (or anything other than `block`) and re-run `install.sh`.*

## ⚙️ Configuration Overrides

To manually override the auto-detected local trusted networks, pass the `TRUSTED_SUBNETS` environment variable:
```bash
sudo TRUSTED_SUBNETS="10.0.0.0/8 192.168.1.0/24" ./install.sh JP ports.csv
```

### Note on Rule Priority
The GeoIP block is injected at the top of UFW's `before.rules`. Because Phase 3 (Local Network Trust) uses an `ACCEPT` rule, any local traffic matching these subnets will bypass the GeoIP block and any subsequent rules in UFW. 
- If you need to **deny** specific local IPs, you must either:
  1. Define those deny rules manually *above* the geoipblock markers in `before.rules`.
  2. Or, narrow down `TRUSTED_SUBNETS` to only include the specific management IPs you trust.
- Setting `TRUSTED_SUBNETS=""` (empty string) will disable the automatic local trust phase entirely.

## 🛠️ Maintenance & Monitoring

```bash
# Check timer status
systemctl status update-geoip.timer

# View update logs
journalctl -u update-geoip.service
```

## 🖤 Manual Blacklisting (ipset)

Phase 1 of the defense system uses a high-performance `ipset` named `persistent_offenders`. You can use this to manually block specific IPs (even those from your allowed country) for 30 days:

```bash
# Block an IP
sudo ipset add persistent_offenders 1.2.3.4

# Remove an IP from blacklist
sudo ipset del persistent_offenders 1.2.3.4

# List all blacklisted IPs
sudo ipset list persistent_offenders
```

## 🤝 Integration with Fail2Ban

You can integrate Fail2Ban with this tool to achieve multi-layered defense. By pointing Fail2Ban to the `persistent_offenders` ipset, you can block brute-force attackers at Phase 1 (the fastest layer).

### Sample Fail2Ban Action (`/etc/fail2ban/action.d/geoipblock.conf`)
```ini
[Definition]
actionban = ipset add persistent_offenders <ip> -exist
actionunban = ipset del persistent_offenders <ip> -exist
```

## 🔐 Let's Encrypt (Certbot) Compatibility
If you use HTTP-01 validation, use these hooks to temporarily bypass the GeoIP block during renewal:
```bash
--pre-hook "iptables -I ufw-before-input 1 -p tcp --dport 80 -j ACCEPT; ip6tables -I ufw6-before-input 1 -p tcp --dport 80 -j ACCEPT" \
--post-hook "iptables -D ufw-before-input -p tcp --dport 80 -j ACCEPT; ip6tables -D ufw6-before-input -p tcp --dport 80 -j ACCEPT"
```

## 🧹 Uninstallation
```bash
sudo ./uninstall.sh
```

## ⚠️ Known Limitations & Compatibility

### 1. Docker Bypass
Docker directly manipulates `iptables` and routes traffic through the `PREROUTING` and `DOCKER` chains, effectively **bypassing UFW's `INPUT` chain**. 
- Ports published via Docker (e.g., `docker run -p 80:80`) will **NOT** be protected by this GeoIP script.

### 2. CDNs and Reverse Proxies (Cloudflare, etc.)
This script operates at Layer 4 (iptables). If your server is behind a CDN like Cloudflare, `iptables` will only see Cloudflare's Edge IPs, not the real visitor's IP.
- If you use a CDN, you must set your HTTP/HTTPS ports to `pass` in `ports.csv` and rely on the CDN's own WAF for GeoIP filtering. Otherwise, legitimate traffic may be blocked if the CDN edge node is located outside your allowed country.

## ⚠️ Troubleshooting
- **Database Download Fails**: Modern `xt_geoip_dl` uses DB-IP. If your system still attempts to download from MaxMind and fails, update your `xtables-addons` version or provide a MaxMind license key.
- **Rules Not Applying**: Run `lsmod | grep xt_geoip` to ensure the kernel module is loaded. Some VPS kernels (like OpenVZ) may not support custom kernel modules.
- **UFW Errors**: Check `/var/log/syslog` for iptables syntax errors.

## ⚖️ Disclaimer (免責事項)
**USE AT YOUR OWN RISK.** This tool modifies your system's firewall rules. 
- The author is **NOT responsible** for any damage, data loss, or server lockouts caused by the use of this script.
- 本ツールの使用によるいかなる損害（サーバーへのアクセス不能等）についても、作者は一切の責任を負いません。自己責任でご利用ください。

## 📜 Acknowledgments & Data Sources
This tool relies on the `xt_geoip` module provided by `xtables-addons`. 
- This product uses the DB-IP IP to City Lite database available from [https://db-ip.com](https://db-ip.com), licensed under CC-BY 4.0.
- Alternately, this product may include GeoLite2 data created by MaxMind, available from [https://www.maxmind.com](https://www.maxmind.com).

## 🔮 Future Considerations & Technical Outlook

As the Linux infrastructure landscape evolves, users should be aware of the following long-term trends:

1.  **The Sunset of iptables**: Linux is steadily migrating from `iptables` to `nftables`. Since this tool depends on `xtables-addons` (a Netfilter extension), it will reach its end-of-life when major distributions eventually drop support for the legacy `xtables` framework.
2.  **Container Orchestration (Kubernetes, etc.)**: The gap between host-level firewalling and container orchestration is widening. In environments like Kubernetes, managing firewall rules manually on the host OS can interfere with complex network policies and pod-to-pod communication.
3.  **The Shift to Edge Defense**: Modern cloud best practices favor "Edge Defense" (filtering at the CDN/WAF level like Cloudflare or AWS WAF). Dropping packets at the origin server after they have already consumed network bandwidth and CPU cycles is becoming a legacy approach compared to stopping threats at the network edge.

*This tool remains a powerful and practical solution for the "standalone VPS" era, but users should consider native cloud firewalls for new, large-scale cloud-native architectures.*
