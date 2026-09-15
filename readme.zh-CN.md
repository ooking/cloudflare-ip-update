# Cloudflare IP Update

[English](readme.md) | 简体中文

自动下载 Cloudflare 的 IPv4 / IPv6 网段，为 Nginx 生成真实 IP 配置和来源判断配置。仅在生成内容变化时更新文件，并执行可配置的 Nginx 检查、重载或重启命令。

## 功能

- 从 Cloudflare 官方接口下载 IPv4 和 IPv6 网段，支持超时和重试。
- 生成 `cloudflare_realip.conf`，通过 `CF-Connecting-IP` 获取访客真实 IP。
- 生成 `cloudflare_allow.conf`，使用原始连接 IP 判断是否来自 Cloudflare。
- 生成 `cloudflare_guard.conf`，在站点中统一引入非 Cloudflare 请求的拦截规则。
- 内容没有变化时直接退出，不执行 Nginx 检查或重载。
- Nginx 配置检查失败时恢复原配置；原文件不存在时删除新生成的文件。

## 环境要求

- Bash、curl、awk 以及常见 Unix 工具（如 cmp、mktemp、wc）。
- Nginx 支持 HTTP realip 和 geo 模块。
- 运行用户拥有配置目录写权限，以及执行 Nginx 检查和重载命令的权限。
- 默认重载命令使用 systemd；其他环境请修改命令配置。

## 下载与配置

只需下载脚本，无需安装 Git 或克隆仓库。先创建安装目录：

```bash
sudo mkdir -p /opt/cloudflare-ip-update
```

使用 **curl 或 wget 二选一**下载：

```bash
# curl
sudo curl -fL https://raw.githubusercontent.com/ooking/cloudflare-ip-update/main/cloudflare-ip-update.sh -o /opt/cloudflare-ip-update/cloudflare-ip-update.sh
```

```bash
# wget
sudo wget -O /opt/cloudflare-ip-update/cloudflare-ip-update.sh https://raw.githubusercontent.com/ooking/cloudflare-ip-update/main/cloudflare-ip-update.sh
```

添加执行权限：

```bash
sudo chmod +x /opt/cloudflare-ip-update/cloudflare-ip-update.sh
```

即使用 wget 下载，脚本运行时仍需要 curl。重新下载会覆盖脚本中的自定义配置，更新前请先保留这些设置。

编辑 `/opt/cloudflare-ip-update/cloudflare-ip-update.sh` 顶部配置：

```bash
DIR="/etc/nginx/snippets"
NGINX_TEST_CMD=(nginx -t)
NGINX_RESTART_CMD=(systemctl reload nginx)
```

| 配置 | 作用 |
| --- | --- |
| `DIR` | 三个生成文件的存放目录 |
| `NGINX_TEST_CMD` | 检查 Nginx 配置的命令 |
| `NGINX_RESTART_CMD` | 检查成功后执行的命令，默认平滑重载 |

命令使用 Bash 数组，命令及每个参数分别填写，不要将整条命令写成一个字符串。例如：

```bash
NGINX_TEST_CMD=(/usr/local/nginx/sbin/nginx -t -c /etc/nginx/nginx.conf)
NGINX_RESTART_CMD=(/usr/local/nginx/sbin/nginx -s reload -c /etc/nginx/nginx.conf)
```

如果需要完整重启：

```bash
NGINX_RESTART_CMD=(systemctl restart nginx)
```

这些配置直接在脚本中修改，不是环境变量参数。

## 首次接入 Nginx

### 1. 生成文件

在添加新的 `include` 之前运行脚本，避免引用尚不存在的文件：

```bash
sudo /opt/cloudflare-ip-update/cloudflare-ip-update.sh
```

首次生成也会执行配置的检查和重载命令。默认输出：

```text
/etc/nginx/snippets/cloudflare_realip.conf
/etc/nginx/snippets/cloudflare_allow.conf
/etc/nginx/snippets/cloudflare_guard.conf
/etc/nginx/snippets/cloudflare_custom.conf
```

### 2. 引入配置

将以下内容合并到现有 `nginx.conf` 的 `http` 块中，不要额外创建第二个 `http` 块。站点的 `server` 也可以位于已有的站点配置文件中。

```nginx
http {
    include /etc/nginx/snippets/cloudflare_realip.conf;
    include /etc/nginx/snippets/cloudflare_allow.conf;

    server {
        listen 80;
        server_name example.com;

        include /etc/nginx/snippets/cloudflare_guard.conf;

        # 保留站点原有的 location、root 或 proxy_pass 等配置。
    }
}
```

- 将 `example.com` 替换为你的域名；修改 `DIR` 后同步修改 `include` 路径。
- `cloudflare_allow.conf` 包含 `geo` 指令，只能在 `http` 块引入一次，不能放在 `server` 或 `location` 中。
- 每个需要限制来源的 `server` 都要引入 `cloudflare_guard.conf`（必须放在 `server` 中，不能放在 `http` 中），HTTPS 的 443 `server` 同样需要，保留其证书和业务配置。
- 仅引入 realip 和 allow 文件不会自动拦截请求；只需要获取访客真实 IP 时，可以只引入 `cloudflare_realip.conf`。
- 如只想对特定站点启用 realip，可将 `cloudflare_realip.conf` 的引入放在目标 `server` 中，不要在同一配置层级重复引入。

### 3. 检查并重载

手动修改 Nginx 站点配置后，执行与你的环境对应的检查和重载命令。默认环境示例：

```bash
sudo nginx -t && sudo systemctl reload nginx
```

不能依赖再次运行脚本来应用站点配置修改：如果三个生成文件没有变化且自定义文件已存在，脚本会直接退出。

## 三个文件如何配合

`cloudflare_realip.conf` 信任 Cloudflare 网段发送的 `CF-Connecting-IP`，将 `$remote_addr` 改写为访客真实 IP；`$realip_remote_addr` 保留改写前的连接来源 IP。

`cloudflare_allow.conf` 按以下结构生成，实际运行会写入下载到的全部 IPv4 和 IPv6 网段：

```nginx
geo $realip_remote_addr $is_cloudflare {
    default 0;

    173.245.48.0/20 1;
    2400:cb00::/32 1;
}
```

匹配 Cloudflare 网段时 `$is_cloudflare` 为 `1`，否则为 `0`。这样即使 realip 已将 `$remote_addr` 改写为访客 IP，来源判断仍然使用原始连接 IP。

`cloudflare_guard.conf` 的完整规则如下。每个受保护的 `server` 引入它，即可复用判断逻辑：

```nginx
if ($is_cloudflare = 0) {
    return 403;
}

include "/etc/nginx/snippets/cloudflare_custom.conf";
```

如果已有内联的上述 `if`，先运行新版脚本生成 guard 文件，再用 guard 的 `include` 替换内联规则，最后手动检查并重载 Nginx。

此用法适用于 **Cloudflare 直接连接该 Nginx**。如果中间还有负载均衡或其他代理，需要按实际代理链调整配置。启用来源限制的站点需要通过 Cloudflare 代理访问，直接访问源站会返回 403。

## 从旧版 allow / deny 配置迁移

1. 将 `server` / `location` 中原有的 `cloudflare_allow.conf` 引入移到 `http` 块。
2. 在需要保护的 `server` 中引入 `cloudflare_guard.conf`。
3. 移除旧的 Cloudflare `allow` / `deny all` 规则，避免它们按改写后的访客 IP 继续拦截。
4. 运行更新脚本生成新格式，并完成 Nginx 配置检查和重载。

迁移过程中应先协调好引用位置和生成文件格式，再执行检查和重载；旧格式文件与新格式的引入位置不能混用。

## 自定义规则

脚本会让 guard 引入同一目录下固定名称的 `cloudflare_custom.conf`，默认路径为 `/etc/nginx/snippets/cloudflare_custom.conf`。修改 `DIR` 时，引入路径会同步变化。

- 文件不存在时，脚本创建一个仅含说明注释的文件；文件已存在时，不修改其内容。
- 此文件不参与覆盖或回滚；即使配置检查失败，也会保留自定义内容和首次创建的文件。
- 缺失文件被创建后，会触发本次配置检查和重载，即使另外三个文件没有变化。
- 自定义规则在 Cloudflare 来源检查之后执行，对所有引入 guard 的 `server` 生效。
- 文件按 `server` 上下文编写，不要包裹 `server` 块，也不能放入仅允许在 `http` 中使用的 `geo` / `map` 指令。

例如，禁止一个访客 IP，在 `cloudflare_custom.conf` 中添加：

```nginx
if ($remote_addr = 203.0.113.10) {
    return 403;
}
```

将示例地址替换为要封禁的 IP。这里使用 realip 还原后的 `$remote_addr` 判断访客；`$realip_remote_addr` 是连接源站的 Cloudflare 节点 IP，不适合用于封禁单个访客。

修改自定义文件后，手动检查并重载（自定义安装请使用对应命令）：

```bash
sudo nginx -t && sudo systemctl reload nginx
```

脚本不会检测已有自定义文件的内容变化，不能依赖定时更新自动应用手动修改。请编辑 custom 文件，直接写入 guard 的内容仍会被后续更新覆盖。

## 定时更新

完成首次 Nginx 接入后，使用 root 的 crontab 在服务器时区每天凌晨 04:00 更新。以下示例与上面的安装路径一致：

```bash
sudo crontab -e
```

添加：

```cron
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
0 4 * * * /opt/cloudflare-ip-update/cloudflare-ip-update.sh >> /var/log/cloudflare-ip-update.log 2>&1
```

请按实际安装位置修改路径，确保配置命令在 cron 环境下可用，并避免多个任务同时运行该脚本。

查看已保存的定时任务和运行日志：

```bash
sudo crontab -l
sudo tail -n 50 /var/log/cloudflare-ip-update.log
```

日志文件会在定时任务首次运行时创建。确保服务器的 cron 服务正在运行；任务以 root 身份执行，条目中无需再写 sudo。

## 失败处理与注意事项

- 下载失败、列表为空或行数低于基本校验阈值时，脚本退出，不更新现有配置。
- 生成文件变化时，脚本先临时备份旧文件，再覆盖并执行 Nginx 配置检查。
- 三个文件均参与变化检测、备份和回滚；缺失 guard 文件也会触发更新。
- 检查失败会恢复旧文件；原先不存在的文件会被删除，并以非零状态退出。
- 重载或重启命令失败会退出，但当前实现不会自动恢复已写入的配置；修复问题后需手动执行检查和重载。
- 备份仅用于本次执行，脚本退出时清理，不是长期备份。
- 生成文件会被覆盖，自定义站点规则应写在 Nginx 主配置或站点配置中。

## 参考

- [Cloudflare IPv4 网段](https://www.cloudflare.com/ips-v4/)
- [Cloudflare IPv6 网段](https://www.cloudflare.com/ips-v6/)
- [Nginx realip 模块](https://nginx.org/en/docs/http/ngx_http_realip_module.html)
- [Nginx geo 模块](https://nginx.org/en/docs/http/ngx_http_geo_module.html)
