#!/usr/bin/env bash
set -euo pipefail

# 生成文件用法（以下路径对应默认 DIR，修改 DIR 后请同步调整 include）：
#
# 1. cloudflare_realip.conf：信任 Cloudflare 网段发送的 CF-Connecting-IP，
#    将 $remote_addr 还原为访客真实 IP；$realip_remote_addr 保留原始连接 IP。
#    Nginx 需要启用 ngx_http_realip_module。
# 2. cloudflare_allow.conf：根据原始连接 IP 定义 $is_cloudflare，
#    Cloudflare 网段为 1，其他地址为 0。仅引入此文件不会自动拒绝请求。
#    文件含 geo 指令，必须在 http 块中引入一次，不能放进 server/location。
#
# 将下面内容合并到现有 nginx.conf 的 http 块，不要另建第二个 http 块：
#
# http {
#     include /etc/nginx/snippets/cloudflare_realip.conf;
#     include /etc/nginx/snippets/cloudflare_allow.conf;
#
#     server {
#         listen 80;
#         server_name example.com;
#
#         if ($is_cloudflare = 0) {
#             return 403;
#         }
#
#         # 此处保留站点原有的 location、root 或 proxy_pass 等配置。
#     }
# }
#
# HTTPS 站点在现有的 443 server 块内同样添加上述 if，保留原有证书配置。
# 每个需要限制来源的 server 都要添加 if；只需要获取真实 IP 时可不添加。
# realip 配置也可仅在目标 server 中引入，此时不要再在 http 中重复引入。
# 从旧版迁移时，将 server/location 中 cloudflare_allow.conf 的 include
# 移到 http 块，并添加上述 if；移除旧的 Cloudflare allow/deny all 规则。
# 本示例适用于 Cloudflare 直接连接此 Nginx；中间还有负载均衡/代理时，
# 需要根据实际代理链调整真实 IP 和来源判断配置。
# 首次接入：先运行脚本生成文件，再加入 include 和 if，随后检查并重载 Nginx。
# 后续运行脚本会在文件变化时自动执行下方配置的检查和重载/重启命令。
# 生成文件会被脚本覆盖，请将站点自定义配置写在 nginx.conf 或站点配置中。
# 官方说明：
# https://nginx.org/en/docs/http/ngx_http_realip_module.html
# https://nginx.org/en/docs/http/ngx_http_geo_module.html

DIR="/etc/nginx/snippets"

# Nginx 命令：使用 Bash 数组，命令和每个参数分别填写。
# 例如：NGINX_TEST_CMD=(/usr/local/nginx/sbin/nginx -t -c /etc/nginx/nginx.conf)
# 例如：NGINX_RESTART_CMD=(systemctl restart nginx)
# 默认沿用 reload；也可以改成 nginx -s reload 等命令。
NGINX_TEST_CMD=(nginx -t)
NGINX_RESTART_CMD=(systemctl reload nginx)

REALIP_FILE="$DIR/cloudflare_realip.conf"
ALLOW_FILE="$DIR/cloudflare_allow.conf"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

IPV4="$TMP_DIR/ips-v4"
IPV6="$TMP_DIR/ips-v6"

NEW_REALIP="$TMP_DIR/cloudflare_realip.conf"
NEW_ALLOW="$TMP_DIR/cloudflare_allow.conf"

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


#
# 基本验证
#

if [[ ! -s "$IPV4" || ! -s "$IPV6" ]]; then
    echo "ERROR: Cloudflare IP list is empty."
    exit 1
fi

# Cloudflare 当前应该有多个网段，避免错误页面被当配置
if [[ $(wc -l < "$IPV4") -lt 5 ]]; then
    echo "ERROR: IPv4 list looks invalid."
    exit 1
fi

if [[ $(wc -l < "$IPV6") -lt 3 ]]; then
    echo "ERROR: IPv6 list looks invalid."
    exit 1
fi


#
# 生成 realip.conf
#

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


#
# 生成 allow.conf
# 在 nginx 的 http 块中 include 此文件（geo 不能放在 server/location 中）。
# 此文件只定义变量；在需要保护的 server 块中添加：
# if ($is_cloudflare = 0) { return 403; }
# 使用 realip_remote_addr 判断原始连接来源，避免 realip 改写客户端 IP 后误判。
#

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


#
# 判断 IP 是否真的发生变化
#
# 不比较时间戳/注释，只比较实际配置
#

REALIP_CHANGED=1
ALLOW_CHANGED=1

if [[ -f "$REALIP_FILE" ]] && cmp -s "$NEW_REALIP" "$REALIP_FILE"; then
    REALIP_CHANGED=0
fi

if [[ -f "$ALLOW_FILE" ]] && cmp -s "$NEW_ALLOW" "$ALLOW_FILE"; then
    ALLOW_CHANGED=0
fi

if [[ "$REALIP_CHANGED" -eq 0 && "$ALLOW_CHANGED" -eq 0 ]]; then
    echo "Cloudflare IP ranges unchanged."
    exit 0
fi


#
# 有变化才更新
#

echo "Cloudflare IP ranges changed."

BACKUP_DIR="$TMP_DIR/backup"
mkdir -p "$BACKUP_DIR"

[[ -f "$REALIP_FILE" ]] && cp "$REALIP_FILE" "$BACKUP_DIR/realip.conf"
[[ -f "$ALLOW_FILE" ]] && cp "$ALLOW_FILE" "$BACKUP_DIR/allow.conf"

cp "$NEW_REALIP" "$REALIP_FILE"
cp "$NEW_ALLOW" "$ALLOW_FILE"


#
# 测试 nginx
#

if "${NGINX_TEST_CMD[@]}"; then

    "${NGINX_RESTART_CMD[@]}"

    echo "Cloudflare IP ranges updated."
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

    exit 1
fi
