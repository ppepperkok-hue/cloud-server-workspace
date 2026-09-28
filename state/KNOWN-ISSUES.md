# 已知问题（KNOWN-ISSUES）

> 记录影响环境运行的已知问题、缓解措施、修复进度。**解决后标注日期，不删除**（保留历史，供复盘）。

## 未解决（open）

| # | 问题 | 影响 | 缓解措施 | 发现时间 | 负责人 |
| --- | --- | --- | --- | --- | --- |
| 1 | bt-he1k 宝塔面板 `8888/tcp` 直接暴露公网，未设 IP 白名单、未启用面板 SSL，管理员用户名为默认 `admin` | 面板入口路径 + 密码即全部防线，存在被扫描、爆破的风险 | 二选一或叠加：① 腾讯云控制台安全组把 8888 限源 IP 放行；② 宝塔「面板设置 → IP 白名单」+ 开启面板 SSL + 改安全入口。**待用户批准后执行** | 2026-09-28 12:57 | agent |
| 2 | bt-he1k `ipmi.service` 启动失败（IPMI Driver） | 无功能影响（KVM 虚机无 IPMI 硬件），但 `systemctl --failed` 常驻报错、干扰巡检 | 可 `systemctl disable --now ipmi.service` 消除噪音；属破坏性较小的变更，**需用户批准** | 2026-09-28 12:57 | agent |
| 3 | bt-he1k 有 137 个待更新软件包（`dnf check-update`），`updateinfo` 未列出安全公告条目 | 存在未修补漏洞的可能；更新需重启部分服务 | 择期在变更窗口执行 `dnf update`；执行前先做快照/备份，见 `docs/operations/02-safety.md` | 2026-09-28 12:57 | agent |
| 4 | bt-he1k 主机侧防火墙仍全部关闭（firewalld / ufw / fail2ban 均未启用），iptables 默认策略 ACCEPT | 主机侧无二次防线，仅依赖腾讯云控制台安全组 + 云镜黑名单链 | 当前**接受**：对外仅 22/80/8888，8888 已加 IP 白名单，888 被安全组拦截。如需纵深防御再启用 fail2ban（护 SSH）或 firewalld，**需用户批准** | 2026-09-28 12:57 | agent |
| 6 | bt-he1k 面板使用**自签证书**（`CN=bt-he1k`，自签 SHA-256），浏览器访问会提示「不安全」 | 只提供传输加密、防嗅探，不能防中间人，浏览器告警会降低使用意愿 | 有域名后换成 Let's Encrypt 或自有证书（面板「面板设置 → 面板 SSL」可直接上传，也可用 [`scripts/maintenance/harden-bt-panel.sh`](../../scripts/maintenance/harden-bt-panel.sh) 指定证书）；无域名期间保持自签并在客户端手动信任 | 2026-09-28 13:21 | agent |
| 7 | bt-he1k nginx 在 `888/tcp` 监听（宝塔默认 phpMyAdmin 占位口，本机返回 404） | 若将来云安全组放行 888 且装上 phpMyAdmin，会形成新的公网暴露面 | 现状：控制台未放行、外网实测不可达。装 phpMyAdmin 前先加 IP 白名单 / SSL，或把该 `listen` 改为仅内网 | 2026-09-28 13:21 | agent |
| 8 | bt-he1k AstrBot WebUI 目前只有 **HTTP**（`http://<TEST_HOST_IP>/`），登录凭据在链路上是明文 | 已有 IP 白名单兜底，泄露面小，但仍不适合长期使用 | 需要时：腾讯云控制台放行 443 → nginx 加 `listen 443 ssl` + 证书（自签或域名证书）；AstrBot 侧已设 `trust_proxy_headers=true`，无需再改 | 2026-09-28 13:46 | agent |
| 12 | bt-he1k NapCat 容器的 WebUI（6099/6100）只绑 `127.0.0.1` | 手机/其它设备访问不了；扫码或改配置目前只能在能 SSH 的机器上做 | 已提供 SSH 隧道（`scripts/utils/napcat-webui-tunnel.ps1`，同时转发 6099/6100/**8000**）。要手机直连就必须在腾讯云控制台放行端口，**且不能改用域名走 80 端口**（未备案域名会被网络层拦，见 ADR-0004） | 2026-09-28 13:56 | agent |
| 13 | bt-he1k SillyTavern 只绑 `127.0.0.1:8000`，且 `basicAuthMode` 仍为 `false` | 只能经 SSH 隧道访问；一旦有人在控制台放行 8000 就会裸奔（SillyTavern 官方明确反对） | 现由隧道保护。若要公网可访问：**先开 `basicAuthMode`**（配置里已有账号密码），再放行端口 | 2026-09-28 14:36 | agent |
| 9 | bt-he1k AstrBot 的 **QQ 侧（NapCat）尚未迁移**，AstrBot 的 aiocqhttp `6199` 目前无人连接 | 机器人核心已就位，但**收不到也发不出 QQ 消息**，等于半成品 | 需要本人在场：部署 NapCat（Docker）并**重新扫码登录**两个 QQ 号；注意换 IP 登录可能触发 QQ 风控 | 2026-09-28 13:46 | agent |
| 10 | 本机 AstrBot 原实例**仍在运行**，与服务器端构成双实例 | 两端共用同一 QQ 账号/配置会产生重复回复与状态分裂（当前因 QQ 未接入，暂无冲突） | 决定迁移完成后停掉本机实例；在此之前不要同时接同一个 QQ 适配器 | 2026-09-28 13:46 | agent |
| 11 | AstrBot 容器以 **root** 运行（官方镜像未指定 user），数据目录 root 所有 | 容器内进程逃逸时权限偏高；单体部署影响有限 | 可接受；如需收紧可改 compose 的 `user:` 并同步 chown 数据目录，需先在测试环境验证 AstrBot 兼容性 | 2026-09-28 13:46 | agent |

## 已解决（resolved）

| # | 问题 | 解决方式 | 解决时间 | 关联 CHANGELOG |
| --- | --- | --- | --- | --- |
| 1 | 面板 8888 裸暴露公网、无 SSL、无 IP 白名单 | 启用面板 HTTPS（自签 SHA-256）+ IP 白名单 `<OPERATOR_IP>`；双向验证：本机出口 IP 得 200，白名单设为 `8.8.8.8` 时得 403。执行 `scripts/maintenance/harden-bt-panel.sh` | 2026-09-28 13:05 | [2026-09-28 13:05] |
| 2 | `ipmi.service` 启动失败常驻告警 | `systemctl disable --now ipmi.service` + `systemctl reset-failed ipmi.service`，`systemctl --failed` 归零 | 2026-09-28 13:13 | [2026-09-28 13:13] |
| 3 | 137 个待更新软件包 | `dnf -y upgrade`（事务 ID **39**，138 个包；回滚 `dnf history undo 39`），升级后 0 待更新并重启进入新内核 `6.6.119-52.9.oc9` | 2026-09-28 13:20 | [2026-09-28 13:08] |
| 5 | 预置账号 `lighthouse` 保留 `/bin/bash` | 复核后判定**风险低**（`PasswordAuthentication no` 且该账号未绑定任何公钥，实际无法登录），决定**保持现状**，避免加锁影响腾讯云工具链 | 2026-09-28 13:21 | — |
| 9 | AstrBot 的 QQ 侧（NapCat）未迁移，机器人收不到消息 | 在服务器加两个 NapCat 容器（一号一容器，`MODE=astrbot` 自动反向连 `ws://astrbot:6199/ws`），用户扫码登录两个 QQ 号；AstrBot 日志出现 2 次 `aiocqhttp(OneBot v11) 适配器已连接。`、无断开，并观测到真实消息事件流入 | 2026-09-28 13:56 | [2026-09-28 13:56] |
| 10 | 本机与服务器双实例并存 | 本机 AstrBot（pid 26584/25604/25828）与两个 NapCat 进程已全部停止，6185/6199/6099 不再监听，服务器为唯一实例 | 2026-09-28 13:56 | [2026-09-28 13:56] |

---

## 维护方式

1. 发现问题 → 加「未解决」表，写清影响与缓解。
2. 缓解措施落地 → 更新「缓解措施」列。
3. 彻底解决 → 移到「已解决」，写解决方式与时间，关联 CHANGELOG 记录。
4. 有历史价值的事故 → 同步写 `docs/postmortems/`。
