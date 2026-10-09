# 服务清单

> 唯一事实来源。新增/变更服务必须更新本表，并在 CHANGELOG 记录。

| 服务名 | 部署位置（主机） | 端口 | 协议 | 依赖 | 负责人 | 版本 | 备注 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| sshd | bt-he1k | 22 | SSH | 无 | agent | OpenSSH 9.3p2-16.oc9 | 仅公钥登录（用户 root）；`PasswordAuthentication no`；密钥对 <TEST_USER> |
| bt-panel | bt-he1k | 8888 | HTTPS | 无 | agent | 11.8.0（腾讯云专享版） | 访问地址 `https://<TEST_HOST_IP>:8888/<PANEL_ENTRY>`；安全入口 `/<PANEL_ENTRY>`；已启用面板 SSL（自签）+ IP 白名单 `<OPERATOR_IP>`；**必须带浏览器 UA，否则返回 404**（见 ADR-0002）；Bt-Task 常驻 |
| nginx | bt-he1k | 443 | HTTPS | 无 | agent | 1.30.2 | **HTTPS 入口 = 酒馆反代**（vhost `sillytavern-ssl.conf`，`listen 443 ssl`）。证书是**自签**（SAN = `IP:<TEST_HOST_IP>` + `DNS:st.<PUBLIC_DOMAIN>`，10 年，`/www/server/panel/vhost/cert/sillytavern/`）——浏览器会提示不受信任，原因见 ADR-0004：域名 SNI 在 443 会被 RST，公共 CA 又不给裸 IP 签证书 |
| nginx | bt-he1k | 80 | HTTP | 无 | agent | 1.30.2（宝塔编译安装） | **只做 301 跳转到 443**（vhost `sillytavern.conf`，`listen 80 default_server`，`return 301 https://$host$request_uri;`，2026-10-09 19:12 由「直接反代酒馆」改成这样）——这样手机上只记一个地址，且不再有明文流量。**`default_server` 必须显式写**：否则 `phpfpm_status.conf` 因文件名排序先加载而抢走默认站点 |
| nginx | bt-he1k | 888 | HTTP | 无 | agent | 1.30.2 | 宝塔默认 phpMyAdmin 占位口（`nginx.conf` 内 `listen 888`），本机返回 404；控制台安全组未放行，外网不可达 |
| postfix | bt-he1k | 25（仅 127.0.0.1） | SMTP | 无 | agent | OpenCloudOS 自带 | 面板/系统邮件本地投递，未对外暴露 |
| chronyd | bt-he1k | 323/udp（仅 127.0.0.1） | NTP | 无 | agent | 系统自带 | 时间同步，`NTPSynchronized=yes` |
| docker | bt-he1k | — | — | containerd | agent | moby 29.7.0（发行版自带） | 容器运行时，`enabled` 开机自启；`/etc/docker/daemon.json` 只配 `registry-mirrors`（不要写 `log-driver`，见 ADR-0003） |
| astrbot | bt-he1k | 6185（**docker-proxy 发布到全接口**） | **HTTPS** | docker | agent | 4.28.1（`soulter/astrbot:v4.28.1`） | 聊天机器人核心与 WebUI；数据 `/opt/astrbot/data`；**面板自己终结 TLS**（`dashboard.ssl.enable=true`，用酒馆那张自签证书，以 `/www/server/panel/vhost/cert/sillytavern:/AstrBot/certs:ro` 挂进容器），因此明文 `http://…:6185/` 已不再监听（实测 000）；对外 `https://<TEST_HOST_IP>:6185/`（自签警告）与 `https://astr.<PUBLIC_DOMAIN>/`（cloudflared 回源 `https://127.0.0.1:6185` + `noTLSVerify`）；`trust_proxy_headers` 已改 `false`（此前面板前无代理却信任 XFF，可伪造头绕过登录限流）；`restart: unless-stopped`。**改 bind-mount 配置后只能用 `docker restart astrbot`，不要 `docker compose up -d`**（见 KNOWN-ISSUES #23） |
| astrbot-aiocqhttp | bt-he1k | 6199 + 6200（仅 127.0.0.1） | WebSocket | docker | agent | 4.28.1 | OneBot v11 反向 WS 入口，**两个平台实例**：`default`:6199 ← napcat1、`napcat2`:6200 ← napcat2（2026-09-29 拆分）。**每个 QQ 号必须独立实例**——共用一个实例时 umo 形如 `default:FriendMessage:<对方QQ>`，不含「哪个机器人收的」这一维度，两个人格与记忆会串在一起（`unique_session=true` 也挡不住，它只隔离群/私聊） |
| sillytavern | bt-he1k | 8000（仅 127.0.0.1） | HTTP | docker | agent | 1.18.0（`ghcr.io/sillytavern/sillytavern`） | 酒馆；数据 `/opt/sillytavern/{config,data,extensions}`；`whitelistMode=true` 且白名单含 `172.16.0.0/12`（否则代理过来的请求全 403）；**经 SSH 隧道访问** `http://127.0.0.1:8000/` |
| napcat ×2 | bt-he1k | 6099 / 6100（仅 127.0.0.1） | HTTP | docker | agent | NapCat 4.18.28（`mlikiowa/napcat-docker:latest`） | QQ 协议端，一号一容器：`napcat1` = QQ <QQ_ACCOUNT_A>（<BOT_NICK_A>）、`napcat2` = QQ <QQ_ACCOUNT_B>（<BOT_NICK_B>）；`MODE=astrbot` 自动反向连（napcat1 → `ws://astrbot:6199/ws`；napcat2 → `ws://astrbot:6200/ws`，**2026-09-29 由 6199 改**以隔离两个号的会话）；WebUI 只绑本机，外网经 Cloudflare Tunnel（见下一行）或 SSH 隧道（`scripts/utils/napcat-webui-tunnel.ps1`，理由见 ADR-0004） |
| cloudflared | bt-he1k | 无监听（纯出站 7844/443） | Cloudflare Tunnel | systemd | agent | 2026.9.3（`/usr/local/bin/cloudflared`） | 具名隧道 `bt-he1k-server`（ID 见 `secrets/cloudflared/`）；ingress 把 `astr.<PUBLIC_DOMAIN>`→`https://127.0.0.1:6185`（配 `originRequest.noTLSVerify: true`，因为面板是自签）、`napcat1/2.<PUBLIC_DOMAIN>`→6099/6100、`st.<PUBLIC_DOMAIN>` 与 apex→8000 送到本机回环口。QUIC 部分被拦已自动降级 HTTP2。**`crc.<PUBLIC_DOMAIN>` 不在本隧道**（那是 Windows 侧 app）。**注意**：四个连接实测全落在洛杉矶（`lax01/05/07/10`），日常访问比直连慢两个数量级，见 KNOWN-ISSUES #16 |
| ops-agent | bt-he1k | 7777（仅 127.0.0.1） | HTTP（JSON） | systemd | agent | 1.0.0（`/opt/ops-agent/ops-agent.py`，纯标准库） | **日常运维通道**：取代「一条命令起一次 `ssh.exe`」（实测 1719 ms → 124 ms）。Bearer token 在 `/etc/ops-agent/token`（本机副本 `secrets/ops-agent-token.txt`）；每请求记 `/var/log/ops-agent/commands.log`。**以 root 运行，token 等价 root 密码**；只绑 loopback，唯一入口是 SSH 隧道。见 ADR-0005 与 `docs/runbooks/ops-agent.md` |

<!--
端口冲突、服务依赖在这里一眼看全；新增端口必须查这里避免撞端口。
-->

## 网络监听端口（bt-he1k，2026-10-09 19:25 复核）

对外可达（全部绑 `0.0.0.0`，实际能不能连上还取决于腾讯云安全组）：`22/tcp`（sshd）、`80/tcp`（nginx `sillytavern.conf` `default_server`，**301 → `https://$host/`**）、`443/tcp`（nginx `sillytavern-ssl.conf`，→ `127.0.0.1:8000` 酒馆，自签证书 SAN = IP + `st.<PUBLIC_DOMAIN>`，**basicAuth 一层**；无凭据 401）、`6185/tcp`（**docker-proxy 把 AstrBot 面板发布到全接口**，但面板自己终结 TLS：`https://<TEST_HOST_IP>:6185/` 实测 200、明文 `http://` 已不监听，故这一格是「有加密的裸端口」）、`888/tcp`（nginx 的 phpMyAdmin 占位口，本机 404）、`8888/tcp`（BT-Panel）。

仅限本机：`127.0.0.1:8000`（酒馆应用本身）、`127.0.0.1:6099` + `6100`（两个 NapCat WebUI）、`127.0.0.1:6199` + `6200` + `6201`（aiocqhttp 反向 WS）、`127.0.0.1:7777`（ops-agent）、`127.0.0.1:25`（postfix）、`127.0.0.1:323` + `[::1]:323`（chronyd）、`127.0.0.1:38787`（containerd）；另有若干 UDP 是 cloudflared 的 QUIC 出站。

要从本机访问只绑 loopback 的那几个口，用 `scripts/utils/napcat-webui-tunnel.ps1`（同时转发 6099 / 6100 / 8000 / 6185 / 7777）。日常运维命令直接点源 `scripts/utils/agent.ps1` 走 7777，不要再逐条起 ssh（ADR-0005）。

> 变更史：2026-09-28 时 `80` 指向 AstrBot、`6185` 只绑 loopback；后因「手机要直连且未备案域名被网络层拦」把 `80`/`443` 让给酒馆（见 ADR-0004），AstrBot 面板改走 `6185`（该改动由其它会话做出，本轮仅复核记录）。2026-10-09 19:12 又把 AstrBot 面板推到自签 TLS 之后（面板自己终结，`6185` 的明文口关闭）并让 `80` 改成 `301 → 443`；同日 19:17 装 `ops-agent`（`127.0.0.1:7777`）。

## 系统服务（bt-he1k）

**运行中**：`sshd` `bt.service` `nginx` `docker` `containerd` `cloudflared` `ops-agent` `crond` `chronyd` `postfix` `rsyslog` `NetworkManager` `acpid` `atd` `rngd` `mcelog` `dbus-broker` `systemd-*` `site_total.service`（宝塔站点监控，常驻）`tat_agent.service`（腾讯云自动化助手）`getty@tty1` `serial-getty@ttyS0`

**开机自启（关键项）**：`sshd` `bt`（sysv 脚本 `/etc/rc.d/init.d/bt`）`nginx`（sysv 脚本，chkconfig 2/3/4/5:on）`docker` `containerd` `cloudflared`（本工作区自建 unit）`ops-agent`（本工作区自建 unit，2026-10-09）`crond` `chronyd` `postfix` `rsyslog` `NetworkManager` `cloud-init*` `kdump` `smartd` `sysstat` `multipathd` `lvm2-monitor` `tat_agent`

**启动失败**：无。原先的 `ipmi.service`（IPMI Driver，KVM 虚机无硬件、必然失败）已于 2026-09-28 `disable --now` 并 `reset-failed`，`systemctl --failed` 已归零。

**未安装 / 无对应服务**：MySQL/MariaDB、PHP-FPM、Redis。（nginx 于 2026-09-28 安装；Docker 于同日安装）

## 计划任务（bt-he1k）

| 位置 | 内容 | 用途 |
| --- | --- | --- |
| `/etc/cron.d/sgagenttask` | 每 1 分钟 `flock /tmp/stargate.lock` 拉起 `stargate/admin/start.sh` | 腾讯云 stargate 保活 |
| `/etc/cron.d/yunjing` | 每 30 分钟 + `@reboot` 执行 `YunJing/YDCrontab.sh` | 腾讯云镜主机安全巡检 |
| `/etc/cron.d/0hourly` | 每小时 `run-parts /etc/cron.hourly` | 系统默认 |
| `root` crontab | 每 5 分钟拉起 stargate | 腾讯云 stargate |
| `/etc/cron.d/napcat-alert` | **每 5 分钟**（2026-10-09 由 `*/1` 放宽；原先每分钟 2 行日志 ≈ 2900 行/天，`/var/log/cron` 里 29666 行全是它）执行 `/usr/local/bin/check-napcat-login.sh` | NapCat 掉线告警。**注意该脚本自身已静默失效，见 KNOWN-ISSUES #22** |
| `/www/server/cron/` | 空 | 宝塔面板计划任务（当前 0 条） |
