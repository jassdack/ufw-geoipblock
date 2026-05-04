#!/bin/bash
# =================================================================
#  GeoIP Database Atomic Updater
#  Ensures zero-downtime and failsafe database updates.
# =================================================================

set -euo pipefail

DB_DIR="/usr/share/xt_geoip"
TMP_BUILD_DIR="/usr/share/xt_geoip_new"
LOG_TAG="geoip-updater"

# 失敗時のハンドラ
error_handler() {
    local exit_code=$?
    local line_number=$1
    logger -t "$LOG_TAG" -p user.err "ERROR: Database update failed at line $line_number with exit code $exit_code. Existing database preserved."
    # 後片付け
    [ -d "$TMP_BUILD_DIR" ] && rm -rf "$TMP_BUILD_DIR"
    exit "$exit_code"
}

trap 'error_handler $LINENO' ERR

# 0. 排他制御 (Exclusive Lock)
LOCK_FILE="/var/run/geoipblock_update.lock"
exec 9> "$LOCK_FILE"
if ! flock -n 9; then
    logger -t "$LOG_TAG" -p user.err "ERROR: Another update process is already running. Exiting."
    exit 1
fi

# 1. 作業用ディレクトリの準備
rm -rf "$TMP_BUILD_DIR"
mkdir -p "$TMP_BUILD_DIR"

# 2. 一時ディレクトリの作成と移動
TEMP_DL_DIR=$(mktemp -d)
cd "$TEMP_DL_DIR"

# 3. データのダウンロードと一時ディレクトリへのビルド
logger -t "$LOG_TAG" "Starting GeoIP database download and build..."

XT_GEOIP_DL=$(command -v xt_geoip_dl || find /usr/libexec/xtables-addons /usr/lib/xtables-addons -name xt_geoip_dl 2>/dev/null | head -n 1)
XT_GEOIP_BUILD=$(command -v xt_geoip_build || find /usr/libexec/xtables-addons /usr/lib/xtables-addons -name xt_geoip_build 2>/dev/null | head -n 1)

if [ -z "$XT_GEOIP_DL" ] || [ -z "$XT_GEOIP_BUILD" ]; then
    logger -t "$LOG_TAG" -p user.err "ERROR: xt_geoip_dl or xt_geoip_build not found. Is xtables-addons-common installed?"
    exit 1
fi

# Retry logic for download (resilience against remote API drops)
MAX_RETRIES=3
RETRY_COUNT=0
DOWNLOAD_SUCCESS=0

while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
    if "$XT_GEOIP_DL"; then
        DOWNLOAD_SUCCESS=1
        break
    fi
    RETRY_COUNT=$((RETRY_COUNT+1))
    logger -t "$LOG_TAG" -p user.warn "xt_geoip_dl failed. Retrying ($RETRY_COUNT/$MAX_RETRIES) in 15 seconds..."
    sleep 15
done

if [ "$DOWNLOAD_SUCCESS" -ne 1 ]; then
    logger -t "$LOG_TAG" -p user.err "ERROR: GeoIP database download failed after $MAX_RETRIES attempts. Aborting update. Your existing firewall rules and DB are completely untouched."
    exit 1
fi

"$XT_GEOIP_BUILD" -D "$TMP_BUILD_DIR"

# 4. アトミック・スワップ (ディレクトリの入れ替え)
# ビルドが成功した（ここまで到達した）場合のみ、本番環境を更新する
mkdir -p "$DB_DIR"
# 古いバックアップを消して、現在の本番をバックアップにする (もしもの時のため)
rm -rf "${DB_DIR}.old"
[ -d "$DB_DIR" ] && mv "$DB_DIR" "${DB_DIR}.old"

# 新しいビルドを本番にする
if mv "$TMP_BUILD_DIR" "$DB_DIR"; then
    # 5. 後始末
    cd /
    rm -rf "$TEMP_DL_DIR"
    # Note: We keep ${DB_DIR}.old for emergency manual rollbacks.
    
    # 6. 成功ログ
    logger -t "$LOG_TAG" "GeoIP Database updated successfully and atomically swapped. Backup preserved at ${DB_DIR}.old."
else
    # ロールバック
    logger -t "$LOG_TAG" -p user.err "ERROR: Failed to swap new database. Rolling back to previous version."
    [ -d "${DB_DIR}.old" ] && mv "${DB_DIR}.old" "$DB_DIR"
    rm -rf "$TMP_BUILD_DIR"
    rm -rf "$TEMP_DL_DIR"
    exit 1
fi
