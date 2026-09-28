# 服务清单

> 唯一事实来源。新增/变更服务必须更新本表，并在 CHANGELOG 记录。

| 服务名 | 部署位置（主机） | 端口 | 协议 | 依赖 | 负责人 | 版本 | 备注 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| sshd | bt-he1k | 22 | SSH | 无 | agent | OpenSSH 9.3p2-16.oc9 | 仅公钥登录（用户 root）；`PasswordAuthentication no`；密钥对 <TEST_USER> |
| bt-panel | bt-he1k | 8888 | HTTPS | 无 | agent | 11.8.0（腾讯云专享版） | 访问地址 `https://<TEST_HOST_IP>:8888/<PANEL_ENTRY>`；安全入口 `/<PANEL_ENTRY>`；已启用面板 SSL（自签）+ IP 白名单 `<OPERATOR_IP>`；**必须带浏览器 UA，否则返回 404**（见 ADR-0002）；Bt-Task 常驻 |
| nginx | bt-he1k | 80 | HTTP | 无 | agent | 1.30.2（宝塔编译安装） | 站点入口 + **AstrBot WebUI 反向代理**（vhost `astrbot.conf`，仅放行白名单来源，其余 403）；`nginx -t` 通过、开机自启 |
| nginx | bt-he1k | 888 | HTTP | 无 | agent | 1.30.2 | 宝塔默认 phpMyAdmin 占位口（`nginx.conf` 内 `listen 888`），本机返回 404；控制台安全组未放行，外网不可达 |
| postfix | bt-he1k | 25（仅 127.0.0.1） | SMTP | 无 | agent | OpenCloudOS 自带 | 面板/系统邮件本地投递，未对外暴露 |
| chronyd | bt-he1k | 323/udp（仅 127.0.0.1） | NTP | 无 | agent | 系统自带 | 时间同步，`NTPSynchronized=yes` |
| docker | bt-he1k | — | — | containerd | agent | moby 29.7.0（发行版自带） | 容器运行时，`enabled` 开机自启；`/etc/docker/daemon.json` 只配 `registry-mirrors`（不要写 `log-driver`，见 ADR-0003） |
| astrbot | bt-he1k | 6185（仅 127.0.0.1） | HTTP | docker | agent | 4.28.1（`soulter/astrbot:v4.28.1`） | 聊天机器人核心与 WebUI；数据 `/opt/astrbot/data`；经 nginx `:80` 反代 + IP 白名单对外；`restart: unless-stopped` |
| astrbot-aiocqhttp | bt-he1k | 6199（仅 127.0.0.1） | WebSocket | docker | agent | 4.28.1 | OneBot v11 反向 WS 入口；2026-09-28 已有 2 个连接（两个 QQ 号） |
| sillytavern | bt-he1k | 8000（仅 127.0.0.1） | HTTP | docker | agent | 1.18.0（`ghcr.io/sillytavern/sillytavern`） | 酒馆；数据 `/opt/sillytavern/{config,data,extensions}`；`whitelistMode=true` 且白名单含 `172.16.0.0/12`（否则代理过来的请求全 403）；**经 SSH 隧道访问** `http://127.0.0.1:8000/` |
| napcat ×2 | bt-he1k | 6099 / 6100（仅 127.0.0.1） | HTTP | docker | agent | NapCat 4.18.28（`mlikiowa/napcat-docker:latest`） | QQ 协议端，一号一容器：`napcat1` = QQ <QQ_ACCOUNT_A>（<BOT_NICK_A>）、`napcat2` = QQ <QQ_ACCOUNT_B>（<BOT_NICK_B>）；`MODE=astrbot` 自动反向连 `ws://astrbot:6199/ws`；WebUI 只绑本机，**经 SSH 隧道访问**（`scripts/utils/napcat-webui-tunnel.ps1`，理由见 ADR-0004） |

<!--
端口冲突、服务依赖在这里一眼看全；新增端口必须查这里避免撞端口。
-->

## 网络监听端口（bt-he1k，2026-09-28 13:48 复核）

对外可达：`22/tcp`（sshd，0.0.0.0 + ::）、`80/tcp`（nginx → AstrBot WebUI，仅放行白名单来源，其余 403）、`8888/tcp`（BT-Panel，全部接口，已加 IP 白名单）。`888/tcp`（nginx 的 phpMyAdmin 占位口）主机上在听，但腾讯云控制台安全组未放行，客户端实测不可达。仅限本机：`127.0.0.1:6185`（AstrBot WebUI，只经 nginx 反代）、`127.0.0.1:6199`（aiocqhttp 反向 WS）、`127.0.0.1:25`（postfix）、`127.0.0.1:323` + `[::1]:323`（chronyd）、`127.0.0.1:38787`（containerd）。

## 系统服务（bt-he1k）

**运行中**：`sshd` `bt.service` `nginx` `docker` `containerd` `crond` `chronyd` `postfix` `rsyslog` `NetworkManager` `acpid` `atd` `rngd` `mcelog` `dbus-broker` `systemd-*` `site_total.service`（宝塔站点监控，常驻）`tat_agent.service`（腾讯云自动化助手）`getty@tty1` `serial-getty@ttyS0`

**开机自启（关键项）**：`sshd` `bt`（sysv 脚本 `/etc/rc.d/init.d/bt`）`nginx`（sysv 脚本，chkconfig 2/3/4/5:on）`docker` `containerd` `crond` `chronyd` `postfix` `rsyslog` `NetworkManager` `cloud-init*` `kdump` `smartd` `sysstat` `multipathd` `lvm2-monitor` `tat_agent`

**启动失败**：无。原先的 `ipmi.service`（IPMI Driver，KVM 虚机无硬件、必然失败）已于 2026-09-28 `disable --now` 并 `reset-failed`，`systemctl --failed` 已归零。

**未安装 / 无对应服务**：MySQL/MariaDB、PHP-FPM、Redis。（nginx 于 2026-09-28 安装；Docker 于同日安装）

## 计划任务（bt-he1k）

| 位置 | 内容 | 用途 |
| --- | --- | --- |
| `/etc/cron.d/sgagenttask` | 每 1 分钟 `flock /tmp/stargate.lock` 拉起 `stargate/admin/start.sh` | 腾讯云 stargate 保活 |
| `/etc/cron.d/yunjing` | 每 30 分钟 + `@reboot` 执行 `YunJing/YDCrontab.sh` | 腾讯云镜主机安全巡检 |
| `/etc/cron.d/0hourly` | 每小时 `run-parts /etc/cron.hourly` | 系统默认 |
| `root` crontab | 每 5 分钟拉起 stargate | 腾讯云 stargate |
| `/www/server/cron/` | 空 | 宝塔面板计划任务（当前 0 条） |
