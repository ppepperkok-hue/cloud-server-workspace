# 任务看板（TASKS）

> 协作核心：**认领前先改状态**，避免两个 agent 撞车。owner 用 agent 名字或 id。
> 状态流转：`待办` → `进行中` → `已完成`；受阻标 `阻塞` 并写原因。

## 进行中（in progress）

| # | 任务 | 环境 | owner | 开始时间 | 备注 |
| --- | --- | --- | --- | --- | --- |
| （暂无） | | | | | |

## 待办（todo）

| # | 任务 | 环境 | 优先级 | 备注 |
| --- | --- | --- | --- | --- |
| 3 | bt-he1k：按需安装 Web 环境剩余组件（MySQL / PHP / Redis） | test | 中 | nginx 1.30.2 已于 2026-09-28 装好；数据库与运行时栈待用户确认要跑什么站点再动 |
| 4 | bt-he1k：有域名后把面板自签证书换成受信证书 | test | 低 | 见 `state/KNOWN-ISSUES.md` #6；面板 SSL 已开，仅证书不受浏览器信任 |
| 5 | bt-he1k：如需纵深防御，再启用 fail2ban / firewalld | test | 低 | 见 `state/KNOWN-ISSUES.md` #4；当前依赖腾讯云控制台安全组 + 面板 IP 白名单 |
| 7 | bt-he1k：给 AstrBot WebUI 加 HTTPS | test | 中 | 见 `state/KNOWN-ISSUES.md` #8；需先在腾讯云控制台放行 443 |
| 9 | bt-he1k：让手机/其它设备也能进 NapCat WebUI | test | 低 | 见 `state/KNOWN-ISSUES.md` #12；需在腾讯云控制台放行 6099/6100；**不要**改用域名走 80（未备案被拦，ADR-0004）。能 SSH 的机器已经能用隧道了 |

## 阻塞（blocked）

| # | 任务 | 阻塞原因 | owner | 备注 |
| --- | --- | --- | --- | --- |
| （暂无） | | | | |

## 已完成（done，近期）

| # | 任务 | 环境 | 完成时间 | 结果 |
| --- | --- | --- | --- | --- |
| 1 | 接入测试服务器 bt-he1k（<TEST_HOST_IP>）并验证 SSH 连通性 | test | 2026-09-28 12:53:12 | 成功：root 公钥登录可用；密钥归档 secrets/ssh/lighthouse-he1k.pem；主机与宝塔面板信息已录入 inventory |
| 2 | bt-he1k 整体情况盘点（主机/安全/服务/面板）并更新工作区 | test | 2026-09-28 12:57:20 | 成功：指纹比对一致，SSH 确认正常；详情入 inventory 三表 + KNOWN-ISSUES；产出盘点脚本与连接 runbook |
| 3 | bt-he1k 面板加固：启用 HTTPS + IP 白名单 | test | 2026-09-28 13:05:45 | 成功：双向验证（本机 200 / 伪白名单 403 / 明文口关闭）；产出 `scripts/maintenance/harden-bt-panel.sh` 与 ADR-0002 |
| 4 | bt-he1k 关闭 `ipmi.service` 失败告警 | test | 2026-09-28 13:08:40 | 成功：`systemctl --failed` 由 1 归零 |
| 5 | bt-he1k 系统包全量升级（138 包） | test | 2026-09-28 13:11:00 | 成功：dnf 事务 39，待更新归零，新增内核 `6.6.119-52.9.oc9` |
| 6 | bt-he1k 安装 nginx 1.30.2 | test | 2026-09-28 13:19:23 | 成功：`nginx -t` 通过，监听 80/888，开机自启 |
| 7 | bt-he1k 冷启动端到端验证（两次重启） | test | 2026-09-28 13:21:00 | 成功：SSH / 面板 / nginx 全部复位，加固与升级在重启后依然生效 |
| 8 | bt-he1k 安装 Docker（moby 29.7.0 + docker-compose） | test | 2026-09-28 13:31:00 | 成功：开机自启，hello-world 拉取运行通过；产出 `scripts/deploy/install-docker.sh` 与 ADR-0003 |
| 9 | 打包并上传 AstrBot 数据（不停机，SQLite 一致快照） | test | 2026-09-28 13:37:00 | 成功：6,674 文件 / 581 MB → 412 MB tarball，两端 sha256 一致；产出 `scripts/deploy/package-astrbot-data.py` |
| 10 | 部署 AstrBot 4.28.1 到容器并修正迁移配置 | test | 2026-09-28 13:41:30 | 成功：36 插件全加载、0 失败，17 提供商与面板账号 `<TEST_USER>` 保留；产出 `deploy-astrbot.sh`、`astrbot-fix-config.sh`、`migrate-astrbot.md` |
| 11 | AstrBot WebUI 接入 nginx 反代 + IP 白名单并冷启动验证 | test | 2026-09-28 13:46:00 | 成功：公网 200（`AstrBot Dashboard`）、`/api/stat` 401、非白名单 403；重启后全部自动恢复；产出 `setup-astrbot-nginx.sh` |
| 12 | 迁移 QQ 适配器：两个 NapCat 容器 + 双号扫码登录 | test | 2026-09-28 13:56:00 | 成功：<QQ_ACCOUNT_A>（<BOT_NICK_A>）、<QQ_ACCOUNT_B>（<BOT_NICK_B>）均接入，AstrBot 记录 2 次「适配器已连接」、无断开，已见真实消息流入；产出 `deploy-napcat.sh` |
| 13 | 停掉本机 AstrBot + NapCat，结束双实例 | local | 2026-09-28 13:52:00 | 成功：本机 3 个 AstrBot 进程与 2 组 NapCat/QQ 进程全部停止，6185/6199/6099 不再监听 |
| 14 | 打通 AstrBot / NapCat 两个 WebUI 的访问 | test | 2026-09-28 14:00:00 | 成功：AstrBot 走 nginx + IP 白名单（`:80`）；NapCat 两个 WebUI 走 SSH 隧道（本机 6099 / 6100，均 200）。域名方案被腾讯云未备案拦截否掉，落 ADR-0004 |
| 15 | 把本机 SillyTavern 1.18.0 迁到服务器 | test | 2026-09-28 14:36:00 | 成功：容器 `healthy`，6 角色卡 / 5 聊天记录 / 2 扩展搬全，`http://127.0.0.1:8000/` 200；隧道已扩到 8000；两个静默坑写入 ADR-0003 与 runbook |
| 16 | 工作区上线前脱敏并推送到公开仓库 | n/a | 2026-09-28 14:55:00 | 成功：107 处真值替换为占位符，`redact-workspace.py --check` 归零；产出脱敏脚本 + 公开仓库提交规范；已提交并推送 |
| 17 | 把本机 Cloudflare Tunnel 迁到服务器 | test | 2026-09-28 15:37:00 | 成功：5 个业务域名改由服务器上的 `bt-he1k-server` 隧道承载（停掉 Windows 侧仍全通即为判据），`crc` 保留在 Windows 侧；产出两个脚本 + runbook；踩到 `--overwrite-dns` 在旧版静默失效 |

---

## 认领/更新方式

1. 认领：把任务从「待办」移到「进行中」，填 owner 和开始时间。
2. 完成：移到「已完成」，填完成时间和结果，并去 `CHANGELOG.md` 追加操作记录。
3. 受阻：移到「阻塞」，写清原因，找用户或协作方解决。
