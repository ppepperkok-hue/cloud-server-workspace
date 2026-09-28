# 服务器清单

> 唯一事实来源。新增/变更服务器必须更新本表，并在 CHANGELOG 记录。

| 主机名 | 内网 IP | 公网 IP | 环境 | 角色 | 操作系统 | 登录方式引用 | 备注 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| bt-he1k | <TEST_HOST_PRIVATE_IP> | <TEST_HOST_IP> | test | 宝塔面板测试机 | OpenCloudOS 9.6 (kernel 6.6.119-52.9.oc9.x86_64) | secrets/ssh/lighthouse-he1k.pem | 腾讯云轻量应用服务器（香港）；实例 ID `<INSTANCE_ID>`；4C/4G/40G；主机名 `<TEST_HOST_HOSTNAME>`；时区 Asia/Shanghai；SELinux 已关闭；2026-09-28 已完成加固与升级 |

<!--
登录方式引用 = 指向 secrets/ 下对应文件或外部密钥库名称，绝不写明文密码/私钥。
-->

## 主机详情

### bt-he1k — 腾讯云轻量应用服务器（香港）

> 采集时间 2026-09-28 12:57 CST，方式：SSH 密钥登录后只读盘点；2026-09-28 13:21 完成加固/升级后复核。原始输出保存在 `logs/inventory-<TEST_HOST_IP>.txt`、`logs/inventory-followup.txt`、`logs/inventory-verify.txt`（`logs/` 不入库）。

| 类别 | 项 | 值 |
| --- | --- | --- |
| 身份 | 云厂商 / 地域 | 腾讯云轻量应用服务器 / 香港 |
| 身份 | 实例 ID | `<INSTANCE_ID>` |
| 身份 | 控制台名称 | 宝塔Linux面板-He1k |
| 身份 | 主机名 | `<TEST_HOST_HOSTNAME>`（镜像初始 `<IMAGE_DEFAULT_HOSTNAME>`，已改名） |
| 身份 | 虚拟化 | KVM 全虚拟化 |
| 网络 | 内网 IP / 掩码 / 网关 | `<TEST_HOST_PRIVATE_IP>/22` / `10.1.0.1`（eth0，DHCP） |
| 网络 | 公网 IP | `<TEST_HOST_IP>` |
| 网络 | DNS | `183.60.83.19`、`183.60.82.98`（腾讯内网 DNS） |
| 硬件 | CPU | Intel Xeon Platinum 8255C @ 2.50GHz，4 vCPU（1 socket × 4 core × 1 thread） |
| 硬件 | 内存 / Swap | 3655 MiB / 1024 MiB（`/www/swap`，宝塔创建，当前未使用） |
| 硬件 | 系统盘 | `/dev/vda1`，xfs，40 GiB，已用约 17 GiB（43%），inode 占用 1% |
| 系统 | 发行版 | OpenCloudOS 9.6（x86_64） |
| 系统 | 内核 | `6.6.119-52.9.oc9.x86_64`（2026-09-28 升级后运行；另保留 49.22、49.23 两个可回退内核） |
| 系统 | 包管理 | dnf，约 1038 个包，**0 个待更新**（2026-09-28 执行 `dnf -y upgrade`，事务 ID 39，共 138 个包） |
| 系统 | 时区 / 时间同步 | `Asia/Shanghai` / chronyd，`NTPSynchronized=yes` |
| 系统 | 最近启动 | 2026-09-28 13:20:57（升级内核后冷启动并验证通过，boot_id `0a809380-3b83-4f2e-b99b-35e8bc75aaba`） |
| 系统 | 运行时 | Python 3.11.6（系统）、Python 3.7.16（宝塔 pyenv）、Git 2.43.7、Docker 29.7.0（`moby`）；无 Go；SELinux 关闭 |
| 安全 | SELinux | Disabled（内核参数 `selinux=0`） |
| 安全 | 主机防火墙 | firewalld / ufw / fail2ban **均未启用**；iptables 默认 ACCEPT，另有腾讯云镜自建链 `YJ-FIREWALL-INPUT`；实际边界由腾讯云控制台安全组承担 |
| 安全 | 对外端口 | `22/tcp`（SSH，仅公钥）、`80/tcp`（nginx）、`8888/tcp`（宝塔面板 **HTTPS**，已设 IP 白名单）；`888/tcp`（nginx 内 phpMyAdmin 占位）主机上监听但控制台安全组未放行，外网实测不可达 |
| 安全 | 已收紧 | 2026-09-28：面板启用 HTTPS（自签 SHA-256，`CN=bt-he1k`，有效期至 2036-09-25）+ IP 白名单 `<OPERATOR_IP>`；白名单外访问实测返回 403 |

**应用栈状态**：宝塔面板 11.8.0（腾讯云专享版）已安装、`enabled` 开机自启；**nginx 1.30.2 已于 2026-09-28 用宝塔官方脚本编译安装并随开机自启**（`/www/server/nginx`，监听 `80` 与 `888`，`nginx -t` 通过）；**Docker 同日安装**（发行版 `moby 29.7.0` + `docker-compose 5.4.0`，`enabled` 开机自启）；**AstrBot 4.28.1 已从本机迁入容器**（`/opt/astrbot`，镜像 `soulter/astrbot:v4.28.1`，36 个插件全部加载、0 失败，17 个模型提供商与面板账号 `<TEST_USER>` 原样保留，WebUI 经 nginx `:80` 反代 + IP 白名单对外）；**两个 QQ 号也已完成扫码登录**：`napcat1` = <QQ_ACCOUNT_A>（<BOT_NICK_A>）、`napcat2` = <QQ_ACCOUNT_B>（<BOT_NICK_B>），二者均以 `MODE=astrbot` 反向连上 `ws://astrbot:6199/ws`，AstrBot 日志确认 `aiocqhttp(OneBot v11) 适配器已连接。` 出现 2 次、无断开；**SillyTavern 1.18.0 同日迁入容器**（`/opt/sillytavern`，6 张角色卡、5 组聊天记录、2 个第三方扩展，容器 `healthy`，仅绑 `127.0.0.1:8000`，经 SSH 隧道访问）。三条迁移手册见 [`../runbooks/`](../runbooks/migrate-astrbot.md)。MySQL / PHP / Redis 仍**未安装**（待用户确定站点栈）。`/www/wwwroot/` 下只有空的 `default` 目录，尚无站点、证书或面板计划任务。

**系统账号**：`root`（仅密钥 `<TEST_USER>` 可登录）、`lighthouse`（uid 1001，`/bin/bash`，腾讯镜像预置，当前无密码登录途径）、`www`（uid 1000，宝塔 Web 用户，`/sbin/nologin`）。

**腾讯云内置组件**（`/usr/local/qcloud/`，184 MB）：YunJing（云镜/主机安全，每 30 分钟巡检）、tat_agent（自动化助手）、stargate（每 1 分钟保活）、monitor、lighthouse（监控）。均在运行中。

**磁盘占用**：根分区 40 GB 已用约 17 GB（43%）。其中 `/www` 约 3.6 GB（`/www/server/panel` 1.1 GB、`/www/server/nginx` 约 1.4 GB），`/opt/astrbot` 约 0.7 GB（数据）+ 容器层，`/opt/sillytavern` 约 0.2 GB + 容器层，`/var/lib/docker` 约 5 GB（含 AstrBot 2.8 GB、NapCat 2.1 GB、SillyTavern 0.8 GB 的镜像层），`/usr/local/qcloud` 184 MB。内存 3654 MB，四个容器常驻约 1.9 GB。

## 变更与回滚记录（bt-he1k）

2026-09-28 这一轮的加固/升级，逐条回滚方式如下（备份统一在 `/root/backups/bt-panel-harden-LAST/` 指向的目录）：

| 时间 | 变更 | 回滚方式 |
| --- | --- | --- |
| 2026-09-28 13:05 | 面板启用 HTTPS（自签 SHA-256）+ IP 白名单 `<OPERATOR_IP>` | 解包备份覆盖回去：`tar xzf …/panel-data.tgz -C /www/server/panel && tar xzf …/panel-ssl.tgz -C /www/server/panel && /etc/init.d/bt restart`（即恢复「无 SSL、无白名单」）。只想放开白名单可单跑 `bt 13` |
| 2026-09-28 13:08 | 系统包全量升级（138 包，dnf 事务 **39**），新增内核 6.6.119-52.9 | `dnf history undo 39` 然后重启，即回到 49.23 内核与旧包 |
| 2026-09-28 13:13 | 关闭 `ipmi.service`（KVM 无 IPMI 硬件，启动必失败）并清除 failed 状态 | `systemctl enable --now ipmi.service`（会重新出现失败告警，属预期） |
| 2026-09-28 13:19 | 编译安装 nginx 1.30.2（宝塔官方 `nginx.sh install 1.30`） | `/etc/init.d/nginx stop && chkconfig nginx off`；彻底移除再删 `/www/server/nginx`、`/etc/init.d/nginx` |
| 2026-09-28 13:31 | 安装 Docker（`moby` + `docker-compose`，EPOL 的 `docker-ce` 与它互斥，见 ADR-0003） | `systemctl disable --now docker && dnf remove -y moby docker-compose docker-buildx docker-compose-switch containerd`；镜像数据留在 `/var/lib/docker` |
| 2026-09-28 13:45 | 把本机 AstrBot 4.28.1 迁入容器（数据 `/opt/astrbot/data`，36 插件），并经 nginx `:80` 反代 + IP 白名单对外 | `cd /opt/astrbot && docker compose down`；彻底回退删 `/opt/astrbot` 与 `/www/server/panel/vhost/nginx/astrbot.conf`。**本机原实例全程未动**，可随时切回 |
| 2026-09-28 13:53 | 加两个 NapCat 容器（一号一容器）并完成扫码登录，两个 QQ 号接入 AstrBot | `docker compose rm -sf napcat1 napcat2`（配置与 QQ 数据保留在 `napcat1/` `napcat2/`，需重新扫码才能再登录）；同时本机 AstrBot + NapCat 进程已停（如需回退，重新启动本机那套即可） |
| 2026-09-28 14:36 | 把本机 SillyTavern 1.18.0 迁入容器（`/opt/sillytavern`，角色卡/聊天/扩展全搬），仅绑 `127.0.0.1:8000` | `cd /opt/sillytavern && docker compose down`；`config`/`data`/`extensions` 的上一版保留为 `*.pre-<时间戳>`，`config.yaml.pre-migration` 为原样配置；彻底回退删 `/opt/sillytavern`。**本机原实例未改动** |
