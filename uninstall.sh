#!/bin/bash

# =================================================================
#  GeoIP Multi-Layer Defense System - Uninstaller (OSS Modern)
# =================================================================

set -euo pipefail

# 1. Root check
if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root."
   exit 1
fi

echo "--- [1/3] Surgically removing GeoIP rules from UFW ---"
# Remove only the block between markers
[ -f /etc/ufw/before.rules ] && sed -i '/# === BEGIN GEOIPBLOCK ===/,/# === END GEOIPBLOCK ===/d' /etc/ufw/before.rules
[ -f /etc/ufw/before6.rules ] && sed -i '/# === BEGIN GEOIPBLOCK ===/,/# === END GEOIPBLOCK ===/d' /etc/ufw/before6.rules

ufw reload

echo "--- [2/3] Cleaning up ipsets and persistence ---"
[ -f /etc/ufw/before.init ] && sed -i '/# === BEGIN GEOIPBLOCK-INIT ===/,/# === END GEOIPBLOCK-INIT ===/d' /etc/ufw/before.init
ipset destroy persistent_offenders 2>/dev/null || true
ipset destroy persistent_offenders6 2>/dev/null || true

echo "--- [3/3] Removing systemd automation and scripts ---"
systemctl disable --now update-geoip.timer 2>/dev/null || true
rm -f /etc/systemd/system/update-geoip.timer
rm -f /etc/systemd/system/update-geoip.service
systemctl daemon-reload

rm -f /usr/local/bin/update-geoip.sh

echo "--- [4/4] Removing GeoIP databases ---"
rm -rf /usr/share/xt_geoip
rm -rf /usr/share/xt_geoip_new

echo "==============================================================="
echo " Uninstallation Complete!"
echo " GeoIP rules have been surgically removed from UFW rules."
echo " GeoIP databases have been deleted."
echo " Note: Dependencies (xtables-addons, ipset, etc.) were not removed."
echo "==============================================================="
