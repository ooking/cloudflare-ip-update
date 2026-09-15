#!/usr/bin/env bash
set -euo pipefail

# See readme.md for setup and usage.
DIR="/etc/nginx/snippets"

# Commands are Bash arrays: one element per argument.
NGINX_TEST_CMD=(nginx -t)
NGINX_RESTART_CMD=(systemctl reload nginx)

REALIP_FILE="$DIR/cloudflare_realip.conf"
ALLOW_FILE="$DIR/cloudflare_allow.conf"
GUARD_FILE="$DIR/cloudflare_guard.conf"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

IPV4="$TMP_DIR/ips-v4"
IPV6="$TMP_DIR/ips-v6"

NEW_REALIP="$TMP_DIR/cloudflare_realip.conf"
NEW_ALLOW="$TMP_DIR/cloudflare_allow.conf"
NEW_GUARD="$TMP_DIR/cloudflare_guard.conf"

mkdir -p "$DIR"

echo "Downloading Cloudflare IP ranges..."

curl \
    --fail \
    --silent \
    --show-error \
    --location \
    --retry 3 \
    --connect-timeout 10 \
    --max-time 30 \
    https://www.cloudflare.com/ips-v4/ \
    -o "$IPV4"

curl \
    --fail \
    --silent \
    --show-error \
    --location \
    --retry 3 \
    --connect-timeout 10 \
    --max-time 30 \
    https://www.cloudflare.com/ips-v6/ \
    -o "$IPV6"

if [[ ! -s "$IPV4" || ! -s "$IPV6" ]]; then
    echo "ERROR: Cloudflare IP list is empty."
    exit 1
fi

if [[ $(wc -l < "$IPV4") -lt 5 ]]; then
    echo "ERROR: IPv4 list looks invalid."
    exit 1
fi

if [[ $(wc -l < "$IPV6") -lt 3 ]]; then
    echo "ERROR: IPv6 list looks invalid."
    exit 1
fi

{
    echo "# Auto-generated Cloudflare IP ranges"
    echo "# DO NOT EDIT"
    echo

    awk 'NF {print "set_real_ip_from " $0 ";"}' "$IPV4"
    awk 'NF {print "set_real_ip_from " $0 ";"}' "$IPV6"

    echo
    echo "real_ip_header CF-Connecting-IP;"
    echo "real_ip_recursive on;"
} > "$NEW_REALIP"

{
    echo "# Auto-generated Cloudflare IP ranges"
    echo "# DO NOT EDIT"
    echo

    echo 'geo $realip_remote_addr $is_cloudflare {'
    echo '    default 0;'
    echo

    awk 'NF {print "    " $0 " 1;"}' "$IPV4"
    echo
    awk 'NF {print "    " $0 " 1;"}' "$IPV6"

    echo '}'
} > "$NEW_ALLOW"

cat > "$NEW_GUARD" <<'EOF'
# Auto-generated Cloudflare access guard
# DO NOT EDIT

if ($is_cloudflare = 0) {
    return 403;
}
EOF

REALIP_CHANGED=1
ALLOW_CHANGED=1
GUARD_CHANGED=1

if [[ -f "$REALIP_FILE" ]] && cmp -s "$NEW_REALIP" "$REALIP_FILE"; then
    REALIP_CHANGED=0
fi

if [[ -f "$ALLOW_FILE" ]] && cmp -s "$NEW_ALLOW" "$ALLOW_FILE"; then
    ALLOW_CHANGED=0
fi

if [[ -f "$GUARD_FILE" ]] && cmp -s "$NEW_GUARD" "$GUARD_FILE"; then
    GUARD_CHANGED=0
fi

if [[ "$REALIP_CHANGED" -eq 0 && "$ALLOW_CHANGED" -eq 0 && "$GUARD_CHANGED" -eq 0 ]]; then
    echo "Cloudflare configuration unchanged."
    exit 0
fi

echo "Cloudflare configuration changed."

BACKUP_DIR="$TMP_DIR/backup"
mkdir -p "$BACKUP_DIR"

[[ -f "$REALIP_FILE" ]] && cp "$REALIP_FILE" "$BACKUP_DIR/realip.conf"
[[ -f "$ALLOW_FILE" ]] && cp "$ALLOW_FILE" "$BACKUP_DIR/allow.conf"
[[ -f "$GUARD_FILE" ]] && cp "$GUARD_FILE" "$BACKUP_DIR/guard.conf"

cp "$NEW_REALIP" "$REALIP_FILE"
cp "$NEW_ALLOW" "$ALLOW_FILE"
cp "$NEW_GUARD" "$GUARD_FILE"

if "${NGINX_TEST_CMD[@]}"; then

    "${NGINX_RESTART_CMD[@]}"

    echo "Cloudflare configuration updated."
    echo "Nginx restart/reload command completed."

else

    echo "ERROR: nginx configuration test failed."
    echo "Restoring old configuration..."

    if [[ -f "$BACKUP_DIR/realip.conf" ]]; then
        cp "$BACKUP_DIR/realip.conf" "$REALIP_FILE"
    else
        rm -f "$REALIP_FILE"
    fi

    if [[ -f "$BACKUP_DIR/allow.conf" ]]; then
        cp "$BACKUP_DIR/allow.conf" "$ALLOW_FILE"
    else
        rm -f "$ALLOW_FILE"
    fi

    if [[ -f "$BACKUP_DIR/guard.conf" ]]; then
        cp "$BACKUP_DIR/guard.conf" "$GUARD_FILE"
    else
        rm -f "$GUARD_FILE"
    fi

    exit 1
fi
