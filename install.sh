#!/bin/bash

# =================================================================
#  GeoIP Multi-Layer Defense System - Installer (OSS Modern Edition)
# =================================================================

set -euo pipefail

# Configuration
DRY_RUN=0
SOURCE_COUNTRY="JP"
PORT_CONFIG="ports.csv"
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# Argument Parsing
POSITIONAL_ARGS=()
while [[ $# -gt 0 ]]; do
  case $1 in
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    -*)
      echo "Unknown option $1"
      exit 1
      ;;
    *)
      POSITIONAL_ARGS+=("$1")
      shift
      ;;
  esac
done

[ ${#POSITIONAL_ARGS[@]} -gt 0 ] && SOURCE_COUNTRY="${POSITIONAL_ARGS[0]}"
[ ${#POSITIONAL_ARGS[@]} -gt 1 ] && PORT_CONFIG="${POSITIONAL_ARGS[1]}"

# 1. Root check and Lock
if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root."
   exit 1
fi

LOCK_FILE="/var/run/geoipblock_install.lock"
exec 9> "$LOCK_FILE"
if ! flock -n 9; then
    echo "ERROR: Another instance of geoipblock installation is already running."
    exit 1
fi

# 2. Parse Ports (Handle CSV or String)
GEN_RULES_V4=""
GEN_RULES_V6=""

process_port_entry() {
    local port_range=$1
    local memo=${2:-}
    local status=${3:-block}
    local country=$4
    
    # Only process ports marked for blocking
    status=$(echo "$status" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
    if [[ "$status" != "block" ]]; then
        return 0
    fi

    # Clean up
    port_range=$(echo "$port_range" | tr -d '[:space:]')
    memo=$(echo "$memo" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    
    local comment_part=""
    [ ! -z "$memo" ] && comment_part="-m comment --comment \"$memo\""

    local log_limit="-m limit --limit 3/min --limit-burst 10"

    for proto in tcp udp; do
        # IPv4 Rules
        GEN_RULES_V4+="-A ufw-before-input -p $proto --dport $port_range -m geoip ! --src-cc $country $log_limit -j LOG --log-prefix \"[UFW BLOCK GeoIP $port_range] \" $comment_part"$'\n'
        GEN_RULES_V4+="-A ufw-before-input -p $proto --dport $port_range -m geoip ! --src-cc $country $comment_part -j DROP"$'\n'
        
        # IPv6 Rules
        GEN_RULES_V6+="-A ufw6-before-input -p $proto --dport $port_range -m geoip ! --src-cc $country $log_limit -j LOG --log-prefix \"[UFW BLOCK6 GeoIP $port_range] \" $comment_part"$'\n'
        GEN_RULES_V6+="-A ufw6-before-input -p $proto --dport $port_range -m geoip ! --src-cc $country $comment_part -j DROP"$'\n'
    done
}

if [ -f "$PORT_CONFIG" ]; then
    echo "--- Reading port configuration from $PORT_CONFIG ---"
    # Sanitize CRLF (\r) and read. Using awk to properly parse basic CSV without breaking on commas in memo.
    while read -r prange pmemo pstatus || [ -n "$prange" ]; do
        # Skip empty lines or comments
        [[ -z "${prange// /}" ]] && continue
        [[ "$prange" =~ ^[[:space:]]*# ]] && continue
        process_port_entry "$prange" "${pmemo:-}" "${pstatus:-enabled}" "$SOURCE_COUNTRY"
    done < <(awk -F, '/^[^#]/ && NF>=1 { 
        # Attempt to handle commas in memo by assuming last field is status, first is port, rest is memo
        if (NF >= 3) {
            port = $1
            status = $NF
            memo = ""
            for (i=2; i<NF; i++) { memo = memo (i==2?"":",") $i }
            print port "\t" memo "\t" status
        } else if (NF == 2) {
            print $1 "\t" $2 "\t" "block"
        } else {
            print $1 "\t\t" "block"
        }
    }' "$PORT_CONFIG" | tr -d '\r')
else
    echo "--- Using manual port list: $PORT_CONFIG ---"
    IFS=',' read -ra ADDR <<< "$PORT_CONFIG"
    for p in "${ADDR[@]}"; do
        process_port_entry "$p" "" "enabled" "$SOURCE_COUNTRY"
    done
fi

# -- Dry-Run Mode Output --
if [ "$DRY_RUN" -eq 1 ]; then
    echo "==============================================================="
    echo " [DRY-RUN MODE] The following UFW rules would be generated:"
    echo "==============================================================="
    echo "--- IPv4 Rules ---"
    echo -e "${GEN_RULES_V4:-(No IPv4 rules generated)}"
    echo "--- IPv6 Rules ---"
    echo -e "${GEN_RULES_V6:-(No IPv6 rules generated)}"
    echo "==============================================================="
    echo " Dry-run complete. No system changes were made."
    exit 0
fi

# 3. Safety Check (Self-Lockout Prevention)
CURRENT_IP=$(echo "${SSH_CLIENT:-}" | awk '{print $1}')
if [ -z "$CURRENT_IP" ]; then
    CURRENT_IP=$(who am i 2>/dev/null | awk '{print $NF}' | tr -d '()')
fi
if [ ! -z "$CURRENT_IP" ]; then
    echo "==============================================================="
    echo " !!! WARNING: SELF-LOCKOUT RISK !!!"
    echo " Your current connection is from: $CURRENT_IP"
    echo " If your IP is NOT in $SOURCE_COUNTRY, you WILL be PERMANENTLY LOCKED OUT."
    echo "==============================================================="
    read -r -p "Are you sure you want to proceed? (type 'yes' to continue): " CONFIRM
    if [ "$CONFIRM" != "yes" ]; then
        echo "Installation cancelled."
        exit 1
    fi
fi

echo "--- [1/5] Checking dependencies ---"
DEPENDENCIES=(xtables-addons-common libtext-csv-xs-perl pkg-config ipset ufw curl)
MISSING_PKGS=()
for pkg in "${DEPENDENCIES[@]}"; do
    if ! dpkg -l "$pkg" >/dev/null 2>&1; then
        MISSING_PKGS+=("$pkg")
    fi
done

if [ ${#MISSING_PKGS[@]} -gt 0 ]; then
    echo "Installing missing packages: ${MISSING_PKGS[*]}"
    apt-get update
    apt-get install -y "${MISSING_PKGS[@]}"
else
    echo "All dependencies are already satisfied."
fi

# 4. GeoIP Database Setup
echo "--- [2/5] Setting up GeoIP database ---"
mkdir -p /usr/share/xt_geoip
cp "$SCRIPT_DIR/update-geoip.sh" /usr/local/bin/update-geoip.sh
chmod +x /usr/local/bin/update-geoip.sh
/usr/local/bin/update-geoip.sh

# 5. ipset initialization & Persistence
echo "--- [3/5] Initializing ipset blacklists and persistence ---"
# Check for IPv6 support
KERNEL_IPV6_SUPPORT=$( [ -f /proc/net/if_inet6 ] && echo "yes" || echo "" )

# Create ipsets immediately
ipset create persistent_offenders hash:ip timeout 2592000 -exist
[ ! -z "$KERNEL_IPV6_SUPPORT" ] && ipset create persistent_offenders6 hash:ip family inet6 timeout 2592000 -exist

# Ensure ipsets are recreated on boot before UFW loads
# We use /etc/ufw/before.init which is executed by UFW before rules are applied
INIT_FILE="/etc/ufw/before.init"
if [ ! -f "$INIT_FILE" ]; then
    echo "#!/bin/sh" > "$INIT_FILE"
    chmod +x "$INIT_FILE"
fi

# Idempotent injection into before.init
sed -i '/# === BEGIN GEOIPBLOCK-INIT ===/,/# === END GEOIPBLOCK-INIT ===/d' "$INIT_FILE"
cat << 'EOF' >> "$INIT_FILE"
# === BEGIN GEOIPBLOCK-INIT ===
ipset create persistent_offenders hash:ip timeout 2592000 -exist
if [ -f /proc/net/if_inet6 ]; then
    ipset create persistent_offenders6 hash:ip family inet6 timeout 2592000 -exist
fi
# === END GEOIPBLOCK-INIT ===
EOF

# 6. Non-destructive UFW Rules Injection
echo "--- [4/5] Injecting GeoIP Rules into UFW ---"

# Check if IPv6 is enabled in UFW
UFW_IPV6_ENABLED=$(grep -Ei "^IPV6=yes" /etc/default/ufw || true)

inject_rules() {
    local file=$1
    local rules_block=$2
    local template=$3
    
    if [ ! -f "$file" ]; then
        echo "Warning: $file not found, skipping..."
        return 0
    fi

    # Generate Trusted Subnets Rules dynamically (separate for v4 and v6)
    local trusted_rules=""
    local proto_flag="inet"
    [[ "$file" == *"before6.rules"* ]] && proto_flag="inet6"

    local detected_subnets
    detected_subnets=$(ip -o -f "$proto_flag" addr show | awk '/scope global/ {print $4}')
    local trusted_subnets=${TRUSTED_SUBNETS:-$detected_subnets}
    
    for subnet in $trusted_subnets; do
        # Basic validation: only use subnets that match the protocol
        if [[ "$proto_flag" == "inet6" && "$subnet" == *":"* ]]; then
            trusted_rules+="-A ufw-before-input -s $subnet -j ACCEPT"$'\n'
        elif [[ "$proto_flag" == "inet" && "$subnet" != *":"* ]]; then
            trusted_rules+="-A ufw-before-input -s $subnet -j ACCEPT"$'\n'
        fi
    done

    # Generate full block from template
    export RULES_BLOCK="$rules_block"
    export TRUSTED_RULES="$trusted_rules"
    local full_block
    full_block=$(perl -pe 's/\{\{RULES\}\}/$ENV{RULES_BLOCK}/g; s/\{\{TRUSTED_SUBNETS_RULES\}\}/$ENV{TRUSTED_RULES}/g' "$template")
    
    # Remove existing block if any (idempotency)
    sed -i '/# === BEGIN GEOIPBLOCK ===/,/# === END GEOIPBLOCK ===/d' "$file"
    
    # Inject after chain definitions
    if grep -q ":ufw.*-before-forward" "$file"; then
        sed -i "/:ufw.*-before-forward/r /dev/stdin" "$file" <<< "$full_block"
    else
        sed -i "/\*filter/r /dev/stdin" "$file" <<< "$full_block"
    fi
}

echo "Applying IPv4 rules..."
inject_rules "/etc/ufw/before.rules" "$GEN_RULES_V4" "$SCRIPT_DIR/ufw/geoip-rules.template"

if [ ! -z "$KERNEL_IPV6_SUPPORT" ] && [ ! -z "$UFW_IPV6_ENABLED" ]; then
    echo "Applying IPv6 rules..."
    inject_rules "/etc/ufw/before6.rules" "$GEN_RULES_V6" "$SCRIPT_DIR/ufw/geoip-rules6.template"
else
    echo "==============================================================="
    echo " NOTICE: IPv6 GeoIP rules SKIPPED."
    if [ -z "$KERNEL_IPV6_SUPPORT" ]; then
        echo " Reason: IPv6 is not supported by the kernel."
    else
        echo " Reason: IPv6 is disabled in UFW configuration."
    fi
    echo " Your IPv6 traffic is NOT protected by GeoIP blocks."
    echo "==============================================================="
fi

# 7. Enable Automation via systemd Timer
echo "--- [5/5] Finalizing and Enabling systemd services ---"
cp "$SCRIPT_DIR/update-geoip.service" /etc/systemd/system/
cp "$SCRIPT_DIR/update-geoip.timer" /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now update-geoip.timer

ufw reload

# --- DEAD MAN'S SNITCH (Auto-Rollback) ---
# Create confirmation wrapper
cat << 'EOF' > /usr/local/bin/geoipblock-confirm
#!/bin/bash
touch /tmp/geoip_rollback.cancel
echo "GeoIP rules CONFIRMED! Rollback cancelled."
EOF
chmod +x /usr/local/bin/geoipblock-confirm

# Create and schedule rollback script
ROLLBACK_SCRIPT="/tmp/geoip_rollback.sh"
cat << 'EOF' > "$ROLLBACK_SCRIPT"
#!/bin/bash
sleep 180
if [ -f "/tmp/geoip_rollback.cancel" ]; then
    rm -f "/tmp/geoip_rollback.cancel"
    exit 0
fi
echo "!!! AUTO ROLLBACK TRIGGERED !!! GeoIP block reverted to prevent lockout." | wall
sed -i '/# === BEGIN GEOIPBLOCK ===/,/# === END GEOIPBLOCK ===/d' /etc/ufw/before.rules
[ -f /etc/ufw/before6.rules ] && sed -i '/# === BEGIN GEOIPBLOCK ===/,/# === END GEOIPBLOCK ===/d' /etc/ufw/before6.rules
ufw reload
EOF
chmod +x "$ROLLBACK_SCRIPT"

# Ensure clean state
rm -f /tmp/geoip_rollback.cancel

# Run rollback in background
nohup "$ROLLBACK_SCRIPT" >/dev/null 2>&1 &

echo "==============================================================="
echo " Installation Applied! UFW Reloaded."
echo " Target Country for ALLOW: $SOURCE_COUNTRY"
echo " GeoIP update is scheduled via systemd timer."
echo " -------------------------------------------------------------"
echo " ⚠️  DEAD MAN'S SWITCH IS ACTIVE ⚠️"
echo " Please test your SSH connection right now."
echo " If you are locked out, rules will AUTO-REVERT in 3 minutes."
echo " To CONFIRM and KEEP these rules, you MUST run within 3 minutes:"
echo "   sudo geoipblock-confirm"
echo "==============================================================="
