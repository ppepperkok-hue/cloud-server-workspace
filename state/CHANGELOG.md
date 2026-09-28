# 操作日志（CHANGELOG）

> 追加式：新记录加到**顶部**或**底部**（本工作区约定：加到**底部**，按时间升序）。历史记录只读不改。
> 格式：`[时间] [执行者] [环境] 动作 — 结果 — 回滚方式`

---

## 记录

[2026-09-28 12:02:03] [agent] [n/a] 初始化工作区：建立目录规范、操作指南与多 agent 协作标准，创建公开 GitHub 仓库 cloud-server-workspace 并推送 main — 结果：成功，44 个文件，仓库 PUBLIC，密钥扫描无泄漏 — 回滚：无需回滚（新仓库，可整体删除）

[2026-09-28 12:44:46] [user] [test] 腾讯云轻量控制台创建 SSH 密钥对 <TEST_USER> 并绑定至实例 <INSTANCE_ID>（<TEST_HOST_IP>）— 结果：成功，绑定后实例重启，root 公钥登录生效 — 回滚：控制台「SSH 密钥」解绑该密钥

[2026-09-28 12:53:12] [agent] [test] 接入测试服务器 bt-he1k 并完成信息盘点：SSH 密钥登录验证（root）、主机与宝塔面板信息采集、私钥归档 — 结果：成功，root 公钥登录可用；OpenCloudOS 9.6 / 4C4G / 40G / 内网 <TEST_HOST_PRIVATE_IP>；宝塔面板 11.8.0（腾讯云专享版）运行于 8888，安全入口 /<PANEL_ENTRY>；已写入 docs/inventory/{servers,services,credentials}.md — 回滚：新增记录，无需回滚；如需撤销仅删除 secrets/ssh/lighthouse-he1k.pem 并回退 inventory 三表

[2026-09-28 12:57:20] [agent] [test] bt-he1k 全量只读盘点：采集主机/硬件/网络/安全基线/监听端口/系统服务/计划任务/宝塔面板/腾讯云组件，并做 SSH 密钥指纹双向比对、宝塔面板凭据归档 — 结果：成功；SSH 正常（主机 `/root/.ssh/authorized_keys` 指纹 `SHA256:<SSH_KEY_FINGERPRINT>` 与本地私钥完全一致），仅公钥可登录；OpenCloudOS 9.6 / 4vCPU / 3655MiB / 40GiB(用 15%)；宝塔 11.8.0 运行中但 Web 环境（nginx/MySQL/PHP/Redis）未安装、无站点；137 个待更新包；面板 8888 无 IP 白名单、未开 SSL。产物：`logs/inventory-<TEST_HOST_IP>.txt`、`logs/inventory-followup.txt`（不入库），结论写入 `docs/inventory/{servers,services,credentials}.md`、`state/KNOWN-ISSUES.md`，新增脚本 `scripts/healthcheck/server-inventory.sh`，新增 runbook `docs/runbooks/connect-bt-he1k.md` — 回滚：全线只读，主机零变更；工作区侧回退对应文档与脚本的提交即可

[2026-09-28 13:02:12] [agent] [n/a] 修正 Windows 侧 SSH 脚本投递方式并补齐盘点脚本：实测 `ssh.exe` 在 argv 超过约 8000 字符时**静默截断**（远端只回显 base64、退出码却为 0），改用 stdin 则被 PowerShell 5.1 改写成 CRLF（bash 报 `$'\r': command not found`、退出码 127）— 结果：改为 **gzip+base64 单个参数**投递（9188 → 3368 字符）+ 7000 字符上限硬校验，封装于 `scripts/utils/ssh-bt-he1k.ps1`；`scripts/healthcheck/server-inventory.sh` 清理非 ASCII 字符并补齐 WEB_STACK / 磁盘占用 / journal 分区；端到端验证 `EXIT=0`、333 行、22 个分区齐全；结论落 `docs/decisions/ADR-0001-windows-ssh-argv-limit.md` — 回滚：删除该封装脚本与 ADR-0001，即回到直连 ssh 手工执行脚本

[2026-09-28 13:05:45] [agent] [test] bt-he1k 面板加固：备份面板 `data`/`ssl` 到 `/root/backups/bt-panel-harden-20260928-130545`，启用面板 HTTPS（自签 SHA-256，`CN=bt-he1k`，有效期至 2036-09-25），设置 IP 白名单 `<OPERATOR_IP>` — 结果：成功；**双向验证通过**（本机出口 IP 得 200，白名单改成 `8.8.8.8` 时得 403，明文 HTTP 口已关闭）；过程中确认宝塔对无浏览器 UA 的请求一律回 404（反扫描），排查结论落 ADR-0002 与 `scripts/maintenance/harden-bt-panel.sh` — 回滚：`tar xzf /root/backups/bt-panel-harden-LAST/panel-data.tgz -C /www/server/panel && /etc/init.d/bt restart`；只放开白名单可单跑 `bt 13`

[2026-09-28 13:08:40] [agent] [test] bt-he1k 关闭 `ipmi.service` 并 `systemctl reset-failed ipmi.service` — 结果：成功，`systemctl --failed` 由 1 归零；KVM 虚机无 IPMI 硬件，该服务本就必然失败 — 回滚：`systemctl enable --now ipmi.service`

[2026-09-28 13:11:00] [agent] [test] bt-he1k 系统包全量升级：`dnf -y upgrade`（以 systemd-run 脱离 SSH 会话执行，日志 `/root/dnf-upgrade-20260928-130835.log`）— 结果：成功，138 个包，dnf 事务 ID **39**，待更新归零；新增内核 `6.6.119-52.9.oc9`、glibc `2.38-49.oc9.2`、openssh `9.3p2-16.oc9`；需重启生效 — 回滚：`dnf history undo 39` 后重启

[2026-09-28 13:19:23] [agent] [test] bt-he1k 安装 nginx：`bash /www/server/nginx.sh install 1.30`（systemd-run 脱离会话，日志 `/root/nginx-install-20260928-131457.log`）— 结果：成功，nginx 1.30.2 编译安装到 `/www/server/nginx`，`nginx -t` 通过，监听 `80` 与 `888`，chkconfig 2/3/4/5:on 开机自启；`/www/wwwroot` 仍无站点 — 回滚：`/etc/init.d/nginx stop && chkconfig nginx off`；彻底移除再删 `/www/server/nginx` 与 `/etc/init.d/nginx`

[2026-09-28 13:21:00] [agent] [test] bt-he1k 冷启动端到端验证：重启两次（13:13:06 激活新内核、13:20:57 验证最终配置），并跑 `scripts/healthcheck/server-inventory.sh` 与面板/nginx/SSH 全面复核 — 结果：**全部通过**；新内核 `6.6.119-52.9.oc9` 运行中、0 待更新、0 failed units；`sshd`(22) / `nginx`(80,888) / `BT-Panel`(8888) 均 active 且 enabled；面板 HTTPS 带浏览器 UA 返回 200 且标题正确、白名单生效，无 UA 返回 404（预期）；nginx 本机与公网 HTTP 均 200；SSH 公钥指纹与本地私钥一致 — 回滚：无需回滚（只读验证）

[2026-09-28 13:31:00] [agent] [test] bt-he1k 安装 Docker：`dnf install -y moby docker-compose`（EPOL 的 `docker-ce` 与 AppStream 的 `moby` 提供同一个 `docker` 而互斥，三方死锁，见 ADR-0003），写 `/etc/docker/daemon.json` 只配 registry 镜像（`docker.m.daocloud.io` / `m.daocloud.io`，因该机直连 Docker Hub 超时）— 结果：成功，`moby 29.7.0` + `docker-compose 5.4.0`，`enabled` 开机自启，hello-world 拉取与运行通过。过程中踩到「daemon.json 写 `log-driver` 会与 unit 的 `--log-driver=journald` 冲突导致 dockerd 启动失败」，已写入 ADR-0003 — 回滚：`systemctl disable --now docker && dnf remove -y moby docker-compose`

[2026-09-28 13:37:00] [agent] [test] 迁移本机 AstrBot 数据到 bt-he1k：用 `scripts/deploy/package-astrbot-data.py` 做**不停机**打包（SQLite 在线备份给 16 个 .db 做一致快照），排除 `backups/`(1.76 GB)、`temp/`、`*.bak`、`logs/`、`site-packages/`，得 6,674 文件 / 581 MB → tar.gz 412 MB；`scp` 上传 — 结果：成功，两端 sha256 完全一致（`3f55b46e…7d877`）— 回滚：删除 `/root/astrbot-data.tar.gz`，本机原实例未动

[2026-09-28 13:41:30] [agent] [test] 部署 AstrBot 到容器并修正迁移配置：解包到 `/opt/astrbot/data`、写 `docker-compose.yml`、起容器（端口只绑 `127.0.0.1`）— 结果：成功但**先踩两个坑**——① 首次 `mv` 把数据放成了 `data/data`，AstrBot 静默跑成全新安装（随机初始密码）；② 迁移来的 `cmd_config.json` 带着本机 `http_proxy: socks5://127.0.0.1:PORT` 且 39 个 JSON 带 UTF-8 BOM，导致所有插件依赖安装全失败。改用 `deploy-astrbot.sh`（拷内容 + 存在性断言）+ `astrbot-fix-config.sh`（去 BOM + 清代理）后：36 个插件全部加载、0 失败，17 个提供商与面板账号 `<TEST_USER>` 原样保留。两条坑写入 ADR-0003 — 回滚：`cd /opt/astrbot && docker compose down`；删 `/opt/astrbot`

[2026-09-28 13:46:00] [agent] [test] AstrBot WebUI 对外方式定为「nginx 反代 + IP 白名单」并做冷启动验证：写 `/www/server/panel/vhost/nginx/astrbot.conf`（`allow <OPERATOR_IP>; deny all;`，WebSocket 透传），设 `dashboard.trust_proxy_headers=true`，随后重启整机 — 结果：**全部通过**；公网 `http://<TEST_HOST_IP>/` 返回 200 且标题为 `AstrBot Dashboard`，`/api/stat` 返回 401（需登录），非白名单来源 403，68–72 个插件相关日志 0 失败；重启后 docker/nginx/bt/AstrBot 全部自动恢复，0 failed units；面板 HTTPS 仍为 200 — 回滚：`rm /www/server/panel/vhost/nginx/astrbot.conf && /www/server/nginx/sbin/nginx -s reload`（备份在 `/root/backups/nginx-*`）

[2026-09-28 13:56:00] [agent] [local+test] 停掉本机实例并把 QQ 侧迁到服务器：① 本机 AstrBot（pid 26584/25604/25828）与两个 NapCat 进程全部停止，6185/6199/6099 不再监听；② 服务器加两个 NapCat 容器（`mlikiowa/napcat-docker:latest`，`MODE=astrbot`、固定 MAC、镜像走 DaoCloud），用户扫码登录两个 QQ 号 — 结果：**成功**；`napcat1` = QQ <QQ_ACCOUNT_A>（<BOT_NICK_A>）、`napcat2` = QQ <QQ_ACCOUNT_B>（<BOT_NICK_B>），二者自动反向连上 `ws://astrbot:6199/ws`，AstrBot 日志出现 2 次 `aiocqhttp(OneBot v11) 适配器已连接。`、无断开，且已观测到真实群聊/临时消息事件流入；三个容器 restarts=0，WebUI 与宝塔面板对外仍 200 — 回滚：`cd /opt/astrbot && docker compose rm -sf napcat1 napcat2`；要恢复本机那套就直接重新启动本机进程。产物：`scripts/deploy/deploy-napcat.sh`

[2026-09-28 14:00:00] [agent] [test] 打通两个 WebUI 的访问：① AstrBot 沿用 `http://<TEST_HOST_IP>/`（nginx + IP 白名单，无需改动）；② NapCat WebUI 尝试用 `nip.io` 域名在 80 端口按 `server_name` 拆分——服务器本地按 Host 头验证通过（200 / `NapCat WebUI`），但**外网被腾讯云网络层拦截**（`Location: https://dnspod.qcloud.com/static/webblock.html?d=...`，403），原因是 80 端口未备案域名拦截；遂删除该死 vhost，改为 **SSH 端口转发**：6099/6100 映射到本机，实测两个 WebUI 均 200 且静态资源可取 — 结果：成功；结论落 ADR-0004，新增 `scripts/utils/napcat-webui-tunnel.ps1` — 回滚：关闭隧道进程即可，服务器侧无任何变更残留

[2026-09-28 14:36:00] [agent] [test] 把本机 SillyTavern 1.18.0（`E:\jiuguan\SillyTavern`）迁到 bt-he1k：本机打包「用户数据」（`config.yaml` + `data/default-user` 329 文件 + `cookie-secret.txt` + 两个第三方扩展 JS-Slash-Runner / ST-Prompt-Template），排除应用本体/node_modules/_webpack/_cache；68.5 MB tarball 上传（sha256 一致）；镜像 `m.daocloud.io/ghcr.io/sillytavern/sillytavern:1.18.0`（ghcr 直连 35 分钟未完成，换 DaoCloud 前缀后秒级完成，层按 digest 复用）— 结果：**成功**，容器 `running/healthy`，`http://127.0.0.1:8000/` 返回 200 且标题 `SillyTavern`，6 张角色卡、5 组聊天记录、设置 `username=<ST_USERNAME>` 均已搬全，两个扩展 manifest 均 200。过程中踩两个静默坑（白名单缩进深一层导致全站 403；扩展目录多一层导致扩展全不加载），已写入 ADR-0003 与 `migrate-sillytavern.md`。访问方式：SSH 隧道（`napcat-webui-tunnel.ps1` 现在同时转发 6099/6100/**8000**）— 回滚：`cd /opt/sillytavern && docker compose down`；删 `/opt/sillytavern`，本机原实例未改动

[2026-09-28 14:50:00] [agent] [n/a] 上线前脱敏：新增提交前置机制 —— 真值集中存放于已 gitignore 的 `secrets/redaction-map.json`，由 `scripts/utils/redact-workspace.py` 负责替换与自检；把 17 个文件里的真值共 **107 处**替换为占位符（公网/内网/运维出口 IP、实例 ID、主机名、密钥对名与 SSH 指纹、宝塔面板安全入口、两个 QQ 号与机器人昵称、SillyTavern 用户名、NapCat WebUI 令牌、本机代理端口）；`napcat-webui-tunnel.ps1` 改为从 `secrets/napcat-webui-tokens.json` 读取令牌；`docs/inventory/README.md` 与根 `README.md` 增加公开仓库脱敏说明与占位符对照表 — 结果：成功；`--check` 复跑为 0，全库扫描已登记字面量 0 残留（仅 `logs/` 命中，而该目录已 gitignore，不入库）— 回滚：真值全在 `secrets/redaction-map.json`，可反向替换

[2026-09-28 14:55:00] [agent] [n/a] 把本轮运维成果提交并推送到公开仓库（origin，见 `git remote -v`）（4 条 ADR、4 份 runbook、13 个脚本、inventory/state 更新）— 结果：推送成功；推送前完成脱敏自检，仓库内不含密钥、令牌、真实 IP 与个人信息 — 回滚：`git revert <sha>` 后重新推送

[2026-09-28 15:00:00] [agent] [test] bt-he1k 例行状态巡检（只读）：新增 `scripts/healthcheck/status.sh`（主机/资源/服务/容器/监听/四套应用/安全基线/补丁 一次看全）— 结果：**整体健康**；0 failed units，四个容器 restarts=0、无 OOM，AstrBot 36 插件 0 失败且 2 个适配器在线，NapCat 双号在连，SillyTavern `healthy`，0 待更新包且无需重启。同时发现三件事：① **`<PUBLIC_DOMAIN>` 经本机 cloudflared + 本会话 SSH 隧道公网直通服务器上的 SillyTavern，且未开认证**（详见 KNOWN-ISSUES #14）；② `/root` 里还留着两个迁移用的 tarball 共 480 MB；③ `/var/log/secure` 里 30 条失败登录其实是本会话早期的用户名试探，另有 3 个境外 IP 扫描（0 成功，全部成功登录均来自运维出口 IP）— 回滚：纯只读巡检，无系统变更

<!-- 新记录追加在此行之上 -->

---

<!--
记录示例：
[2026-02-01 10:00:00] [agent-a] [prod] 重启 nginx 更新证书 — 结果：成功，验证 https 返回 200 — 回滚：旧证书已备份于 secrets/nginx-old.pem
-->
