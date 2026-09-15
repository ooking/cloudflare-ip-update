# Cloudflare IP Update

English | [简体中文](readme.zh-CN.md)

Download Cloudflare IPv4 and IPv6 ranges and generate Nginx configuration for real client IPs and Cloudflare-only access. Update files and run configurable Nginx validation and reload/restart commands only when generated content changes.

## Features

- Download official Cloudflare ranges with retries and timeouts.
- Generate `cloudflare_realip.conf` to restore client IPs from `CF-Connecting-IP`.
- Generate `cloudflare_allow.conf` to identify Cloudflare connections using the original peer IP.
- Generate `cloudflare_guard.conf` to share the access restriction across servers.
- Skip Nginx validation and reload when all three files are unchanged.
- Restore previous files if Nginx configuration validation fails.

## Requirements

- Bash, curl, awk, and common Unix tools including cmp, mktemp, and wc.
- Nginx with the HTTP realip and geo modules.
- Permission to write the output directory and run Nginx validation and reload commands.
- The default reload command requires systemd; configure another command where needed.

## Installation and configuration

```bash
git clone https://github.com/ooking/cloudflare-ip-update.git
cd cloudflare-ip-update
```

Edit the settings near the top of `cloudflare-ip-update.sh`:

```bash
DIR="/etc/nginx/snippets"
NGINX_TEST_CMD=(nginx -t)
NGINX_RESTART_CMD=(systemctl reload nginx)
```

| Setting | Purpose |
| --- | --- |
| `DIR` | Output directory for all three generated files |
| `NGINX_TEST_CMD` | Nginx configuration validation command |
| `NGINX_RESTART_CMD` | Command executed after successful validation; defaults to graceful reload |

Commands are Bash arrays: use one element per argument, rather than quoting the entire command as one string. For a custom Nginx installation:

```bash
NGINX_TEST_CMD=(/usr/local/nginx/sbin/nginx -t -c /etc/nginx/nginx.conf)
NGINX_RESTART_CMD=(/usr/local/nginx/sbin/nginx -s reload -c /etc/nginx/nginx.conf)
```

For a full restart:

```bash
NGINX_RESTART_CMD=(systemctl restart nginx)
```

These settings are edited in the script; they are not environment variable overrides.

## Initial Nginx setup

### 1. Generate the files

Run the script before adding new includes so that Nginx does not reference missing files:

```bash
sudo bash cloudflare-ip-update.sh
```

The initial run also executes the configured validation and reload commands. Default output paths:

```text
/etc/nginx/snippets/cloudflare_realip.conf
/etc/nginx/snippets/cloudflare_allow.conf
/etc/nginx/snippets/cloudflare_guard.conf
```

### 2. Include the configuration

Merge this example into your existing `http` block. Do not create a second `http` block. The `server` block can remain in an existing site configuration file.

```nginx
http {
    include /etc/nginx/snippets/cloudflare_realip.conf;
    include /etc/nginx/snippets/cloudflare_allow.conf;

    server {
        listen 80;
        server_name example.com;

        include /etc/nginx/snippets/cloudflare_guard.conf;

        # Keep your existing location, root, or proxy_pass configuration.
    }
}
```

- Replace `example.com` with your domain. Adjust include paths if you change `DIR`.
- Include `cloudflare_allow.conf` once in `http`; its `geo` block cannot be placed in `server` or `location`.
- Include `cloudflare_guard.conf` in every protected `server`, including HTTPS servers on port 443. Keep existing certificates and application configuration.
- The guard contains an `if` directive and cannot be included in `http`. Sharing the file centralizes the rule, but each protected server still needs its include.
- Including only realip and allow does not block requests. If you only need real client IPs, include only `cloudflare_realip.conf`.
- To enable realip for selected sites only, include that file in the target `server` instead of `http`. Avoid duplicate includes at the same level.

### 3. Validate and reload

After manually editing site configuration, run the appropriate validation and reload commands. With the defaults:

```bash
sudo nginx -t && sudo systemctl reload nginx
```

Rerunning the script does not apply site configuration changes when all three generated files are unchanged: it exits without reloading.

## How the files work together

`cloudflare_realip.conf` trusts Cloudflare ranges to supply `CF-Connecting-IP`. It restores the visitor IP in `$remote_addr`, while `$realip_remote_addr` retains the original connection IP.

`cloudflare_allow.conf` generates a mapping with the following structure. The actual file contains all downloaded IPv4 and IPv6 ranges:

```nginx
geo $realip_remote_addr $is_cloudflare {
    default 0;

    173.245.48.0/20 1;
    2400:cb00::/32 1;
}
```

`$is_cloudflare` is `1` for Cloudflare ranges and `0` otherwise. Checking the original connection IP avoids rejecting visitors after realip rewrites `$remote_addr`.

`cloudflare_guard.conf` contains this shared rule:

```nginx
if ($is_cloudflare = 0) {
    return 403;
}
```

This setup assumes **Cloudflare connects directly to this Nginx instance**. An additional load balancer or proxy requires configuration tailored to that proxy chain. Protected sites must be accessed through Cloudflare's proxy; direct origin requests receive HTTP 403.

## Migration

### From an inline guard

Run the updated script to generate `cloudflare_guard.conf`, replace the inline `if` in each protected server with the guard include, then manually validate and reload Nginx.

### From the old allow / deny format

1. Move the `cloudflare_allow.conf` include from `server` / `location` to `http`.
2. Include `cloudflare_guard.conf` in each protected `server`.
3. Remove the old Cloudflare `allow` / `deny all` rules so they do not reject rewritten visitor IPs.
4. Run the updated script to generate the new format and validate/reload Nginx.

Coordinate the include locations and generated file format before validation and reload; the old and new formats cannot use the same include context.

## Scheduled updates

To update daily using root's crontab, assuming the script is installed in `/opt/cloudflare-ip-update`:

```bash
sudo crontab -e
```

Add:

```cron
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
0 4 * * * /bin/bash /opt/cloudflare-ip-update/cloudflare-ip-update.sh >> /var/log/cloudflare-ip-update.log 2>&1
```

Adjust the installation path, ensure configured commands are available in the cron environment, and avoid overlapping script runs.

## Failure handling and operational notes

- Download failures, empty lists, or lists below the basic line-count thresholds stop execution before existing configuration is updated.
- All three files participate in change detection, backup, and rollback. A missing guard file triggers an update even if IP ranges are unchanged.
- Changed configuration is temporarily backed up, replaced, and then validated with the configured Nginx command.
- Validation failure restores previous files and removes newly created files that had no previous version, then exits with a nonzero status.
- Reload/restart failure exits without automatically restoring the newly written files. After resolving the problem, manually validate and reload Nginx.
- Backups are temporary and removed when the script exits; they are not persistent backups.
- Generated files are overwritten. Keep custom site rules in your main or site configuration.

## References

- [Cloudflare IPv4 ranges](https://www.cloudflare.com/ips-v4/)
- [Cloudflare IPv6 ranges](https://www.cloudflare.com/ips-v6/)
- [Nginx realip module](https://nginx.org/en/docs/http/ngx_http_realip_module.html)
- [Nginx geo module](https://nginx.org/en/docs/http/ngx_http_geo_module.html)
- [Nginx if directive](https://nginx.org/en/docs/http/ngx_http_rewrite_module.html#if)
