# 已知问题（KNOWN-ISSUES）

> 记录影响环境运行的已知问题、缓解措施、修复进度。**解决后标注日期，不删除**（保留历史，供复盘）。

## 未解决（open）

| # | 问题 | 影响 | 缓解措施 | 发现时间 | 负责人 |
| --- | --- | --- | --- | --- | --- |
| 4 | bt-he1k 主机侧防火墙仍全部关闭（firewalld / ufw / fail2ban 均未启用），iptables 默认策略 ACCEPT | 主机侧无二次防线，仅依赖腾讯云控制台安全组 + 云镜黑名单链 | 当前**接受**：对外仅 22/80/8888，8888 已加 IP 白名单，888 被安全组拦截。如需纵深防御再启用 fail2ban（护 SSH）或 firewalld，**需用户批准** | 2026-09-28 12:57 | agent |
| 6 | bt-he1k 面板使用**自签证书**（`CN=bt-he1k`，自签 SHA-256），浏览器访问会提示「不安全」 | 只提供传输加密、防嗅探，不能防中间人，浏览器告警会降低使用意愿 | 有域名后换成 Let's Encrypt 或自有证书（面板「面板设置 → 面板 SSL」可直接上传，也可用 [`scripts/maintenance/harden-bt-panel.sh`](../../scripts/maintenance/harden-bt-panel.sh) 指定证书）；无域名期间保持自签并在客户端手动信任 | 2026-09-28 13:21 | agent |
| 7 | bt-he1k nginx 在 `888/tcp` 监听（宝塔默认 phpMyAdmin 占位口，本机返回 404） | 若将来云安全组放行 888 且装上 phpMyAdmin，会形成新的公网暴露面 | 现状：控制台未放行、外网实测不可达。装 phpMyAdmin 前先加 IP 白名单 / SSL，或把该 `listen` 改为仅内网 | 2026-09-28 13:21 | agent |
| 11 | AstrBot 容器以 **root** 运行（官方镜像未指定 user），数据目录 root 所有 | 容器内进程逃逸时权限偏高；单体部署影响有限 | 可接受；如需收紧可改 compose 的 `user:` 并同步 chown 数据目录，需先在测试环境验证 AstrBot 兼容性 | 2026-09-28 13:46 | agent |
| 12 | bt-he1k NapCat 容器的 WebUI（6099/6100）只绑 `127.0.0.1` | 手机/其它设备访问不了；扫码或改配置目前只能在能 SSH 的机器上做 | 已提供 SSH 隧道（`scripts/utils/napcat-webui-tunnel.ps1`，同时转发 6099/6100/**8000**/**6185**/**7777**）。要手机直连就必须在腾讯云控制台放行端口，**且不能改用域名走 80 端口**（未备案域名会被网络层拦，见 ADR-0004） | 2026-09-28 13:56 | agent |
| 13 | bt-he1k SillyTavern 只绑 `127.0.0.1:8000`，且 `basicAuthMode` 仍为 `false` | 只能经 SSH 隧道访问；一旦有人在控制台放行 8000 就会裸奔（SillyTavern 官方明确反对） | 现由隧道保护。若要公网可访问：**先开 `basicAuthMode`**（配置里已有账号密码），再放行端口 | 2026-09-28 14:36 | agent |
| 14 | SillyTavern 现在走公网了（`http://<TEST_HOST_IP>/`，直连），**认证只靠 basicAuth 一层**；NapCat 两个 WebUI 亦公网可达，只靠 URL 里的 token | 一旦 basicAuth 被爆破或 token 泄露，角色卡、聊天记录、配好的模型 API Key 全部暴露；NapCat 侧还能直接改机器人行为 | 已开 `basicAuthMode=true`（401 验证通过）。加固方向：① 开 443 + 证书（见 #17）；② Cloudflare Zero Trust Access 做统一登录；③ NapCat 建议加一层反代白名单或只走隧道 | 2026-09-28 21:55 | agent |
| 18 | 宝塔自带的 `phpfpm_status.conf` 里 `allow 127.0.0.1; deny all;` **没有生效**：外网带 `Host: 127.0.0.1` 就能拿到 nginx `stub_status`（返回 200），`/phpfpm_*_status` 也可达 | 泄露 nginx 连接统计等内部信息（本机没装 PHP，phpfpm 端点其实 502） | **已缓解**：该 vhost 已改名为 `phpfpm_status.conf.disabled-by-agent`，复测外网 200 → 401。**宝塔面板升级可能把它重建**，届时重跑 [`disable-bt-status-vhost.sh`](../../scripts/maintenance/disable-bt-status-vhost.sh) | 2026-09-28 22:20 | agent |
| 15 | bt-he1k 的 cloudflared 需要**人工维护 DNS**：隧道本身跑得起来，但 `route dns` 要用 Cloudflare **源证书**（`cert.pem`），而它只在本机 | 在服务器上新加域名时，得回 Windows 跑 `cloudflared tunnel route dns`（或再临时拷 `cert.pem` 上去）；本机那份 `cloudflared` 还是 2026.7.3，`--overwrite-dns` 有静默失效的 bug | 现状**接受**：加域名是低频操作。要做的话：升级本机 cloudflared 到 ≥ 2026.9，或申请一个 Cloudflare API Token（`Zone:DNS:Edit`）按需使用，**不建议**把源证书长期放在服务器上 | 2026-09-28 15:37 | agent |
| 16 | **Cloudflare Tunnel 这条路极慢，不建议日常用**：服务器在**香港**，但隧道四个连接全部落在**洛杉矶**（`lax01/05/07/10`），而用户侧命中的边缘是**达拉斯**（响应头 `CF-RAY: …-DFW`） | 实测同一个酒馆首页（brotli 后 84 KB）：SSH 直连 **0.14 s**、Cloudflare **1.42 s**；一个 423 B 的静态资源：直连 **0.036 s**、Cloudflare **5.14 s**。**慢在绕路，不在服务器**（服务器本地响应 4–23 ms） | 日常用直连：SSH 隧道 `http://127.0.0.1:8000/`；要任何设备都能用就在腾讯云控制台放行端口（见下条）。想救 Cloudflare 的话：`--region` 无效（`_ap-v2-origintunneld._tcp.argotunnel.com` 不存在，填了会让服务起不来），只能等 Cloudflare 侧边缘调度改善 | 2026-09-28 15:55 | agent |
| 20 | **napcat2（QQ `<QQ_ACCOUNT_B>`）反复掉线：是腾讯服务端「踢下线」，不是崩溃**（同机同配置的 napcat1/`<QQ_ACCOUNT_A>` 从不掉）。2026-09-29 **10:44:16** 日志出现 `[KickedOffLine] [下线通知] 你的账号当前登录已失效，请重新登录。` | 该号的所有消息收发与「换班提醒」推送**静默失效**，用户只能靠"发消息没回应"察觉；**被踢后缓存的登录态即作废，快速登录也救不回来，只能人工重新扫码** | **详析见下方「#20 详析」**。立刻可做：① `o3HookMode` 1→0（NapCat 官方对"频繁掉线"的建议，本条还没试过）；② ✅ **「零监控」缺口已于 2026-09-29 11:45 关闭**（任务包 O2）——掉线会自动经 napcat1 发 QQ 告警：防抖（连续 2 次坏探测）、同故障 30 分钟去重、恢复后再报、**告警发不出去不静默**（不记为已告警 + 日志 ERROR + 退出码 3）、可选每日心跳。产物见 [`docs/runbooks/napcat-drop-alert.md`](../docs/runbooks/napcat-drop-alert.md)；发送通道用 napcat1 **WebUI 的 Debug API**（内部接口，升级后可能失效 → 故提供心跳作死信开关）；③ 减少无谓重启（每次重启 = 一次新登录尝试）；④ 扫码优先走 WebUI 而非控制台。**用户已确认：该号此前在手机 QQ 上登录着，对照组 `<QQ_ACCOUNT_A>` 只在服务器上登**（互踢假说与官方文档「避免在同一 IP/设备上同时登录 Bot 账号与常用账号」一致）；用户已于 2026-09-29 11:35 前后**在手机退出该号**。**遗留待办（用户 2026-09-29 指示）**：去 [NapCatQQ 仓库](https://github.com/NapNeko/NapCatQQ/issues) 翻 issue，看有没有人报过同样症状（`KickedOffLine`、`ErrType 1 ErrCode 3/10`、**扫码后卡在「二维码已被扫描，等待确认」再报 `ErrCode 10`**）。O1 已引 [#2063](https://github.com/NapNeko/NapCatQQ/issues/2063)、[#1568](https://github.com/NapNeko/NapCatQQ/issues/1568)，**官方无公开错误码映射表**。另一条未解现象：【推测】11:26:59 那条"已被扫描"而用户并未扫码，可能是腾讯侧状态错乱，也可能是该码被其它客户端取用——未定论 | 2026-09-29 11:40 | agent |

| 21 | **两个 QQ 号（`<QQ_ACCOUNT_A>` / `<QQ_ACCOUNT_B>`）当前都处于未登录状态**：2026-10-09 18:56 因内存整理重启 NapCat 后，两容器同时打印 `快速登录错误： 登录态已失效，请重新登录。`，此后每约 2 分钟刷一次二维码（`/app/napcat/cache/qrcode.png`）。AstrBot 侧三个适配器 `aiocqhttp(default)` / `aiocqhttp(napcat2)` / `aiocqhttp(probe)` **只有 probe 连上**，两个真号都没连 | 两台机器人的消息收发与「换班提醒」推送**全部不工作**；用户只能靠"发消息没回应"察觉 | **需要用户人工重新扫码**（推荐经 SSH 隧道用 WebUI：`http://127.0.0.1:6099/webui/?token=…` / `:6100/…`，令牌在 `secrets/napcat-webui-tokens.json`）。**判据**：napcat1 在 09-30 00:58、napcat2 在 09-30 01:06 就已各自出现过同类失败 ⇒ 登录态**此前就已失效**，本次重启只是把它暴露出来，不是重启损坏的。缓解方向见 #20 与 #22 | 2026-10-09 18:56 | agent |
| 22 | **NapCat 掉线告警脚本已静默失效**：`/var/lib/napcat-alert/state.json` 的 mtime 停在 **2026-09-29 15:20**，内容仍是 `{state:"down", failures:"54", first_failure_epoch:"1790663221", alerted:"1", last_reason:"isLogin…"}`，此后近 3 天**再未写入过** | 「零监控」缺口重新打开：掉线后无人被告知，而用户以为自己有告警；这与 #21 叠加 = **静默失效 × 静默失效** | 待排查：脚本 `check-napcat-login.sh` 是否在 `alerted=1` 后走进了永不重置的分支，或依赖的发送通道本身已断（该脚本**用 napcat1 的 WebUI Debug API 发消息，napcat1 一断它自己也哑** ⇒ 自噬设计缺陷）。cron 已由 `*/1` 放宽为 `*/5`（见 [2026-10-09 18:54] CHANGELOG），**频率不是失效原因** | 2026-10-09 18:54 | agent |
| 23 | **AstrBot 的插件依赖装在容器可写层，`docker compose up -d` 一重建就全丢**：2026-10-09 为了给面板加证书挂载而重建容器，之后 AstrBot 从零重装 `transformers` / `modelscope` / `huggingface-hub` 等（日志 `Collecting …` 连续滚了十几分钟，实测下载 **~211 kB/s**），期间**面板 6185、两个 OneBot 适配器 6199/6200 全部不监听** | 每次「改 compose」的代价都可能是**几十分钟的机器人离线**；期间面板 502、两个 QQ 收不到消息，而容器状态看起来是 `Up`（正常），容易被误判成崩溃 | **改 `cmd_config.json` 这类 bind-mount 里的配置时用 `docker restart astrbot`**（不重建容器、依赖不丢），只在真的动 compose 时才 `up -d`；动 compose 前先预期一次长重装。长期方案（未做）：把 site-packages 或 venv 放命名卷。**现成缓解（已测速，未实施）**：本机 `http://mirrors.tencentyun.com/pypi/simple/` 与 `https://mirrors.cloud.tencent.com/pypi/simple/` 都返回 200 且 `connect=0.002 s`（腾讯内网），而 `https://pypi.org/simple/` 的 connect 是 0.24 s ⇒ 给容器配内网 pip 源可把「几十分钟的重装」压到分钟级。判据：容器内 `6185` 是否 OPEN（`docker exec astrbot python3 -c "import socket;s=socket.socket();print(s.connect_ex(('127.0.0.1',6185)))"`），注意镜像里**没有 `ss`/`netstat`/`ps`** | 2026-10-09 19:20 | agent |

## 已解决（resolved）

| # | 问题 | 解决方式 | 解决时间 | 关联 CHANGELOG |
| --- | --- | --- | --- | --- |
| 1 | 面板 8888 裸暴露公网、无 SSL、无 IP 白名单 | 启用面板 HTTPS（自签 SHA-256）+ IP 白名单 `<OPERATOR_IP>`；双向验证：本机出口 IP 得 200，白名单设为 `8.8.8.8` 时得 403。执行 `scripts/maintenance/harden-bt-panel.sh` | 2026-09-28 13:05 | [2026-09-28 13:05] |
| 2 | `ipmi.service` 启动失败常驻告警 | `systemctl disable --now ipmi.service` + `systemctl reset-failed ipmi.service`，`systemctl --failed` 归零 | 2026-09-28 13:13 | [2026-09-28 13:13] |
| 3 | 137 个待更新软件包 | `dnf -y upgrade`（事务 ID **39**，138 个包；回滚 `dnf history undo 39`），升级后 0 待更新并重启进入新内核 `6.6.119-52.9.oc9` | 2026-09-28 13:20 | [2026-09-28 13:08] |
| 5 | 预置账号 `lighthouse` 保留 `/bin/bash` | 复核后判定**风险低**（`PasswordAuthentication no` 且该账号未绑定任何公钥，实际无法登录），决定**保持现状**，避免加锁影响腾讯云工具链 | 2026-09-28 13:21 | — |
| 9 | AstrBot 的 QQ 侧（NapCat）未迁移，机器人收不到消息 | 在服务器加两个 NapCat 容器（一号一容器，`MODE=astrbot` 自动反向连 `ws://astrbot:6199/ws`），用户扫码登录两个 QQ 号；AstrBot 日志出现 2 次 `aiocqhttp(OneBot v11) 适配器已连接。`、无断开，并观测到真实消息事件流入 | 2026-09-28 13:56 | [2026-09-28 13:56] |
| 10 | 本机与服务器双实例并存 | 本机 AstrBot（pid 26584/25604/25828）与两个 NapCat 进程已全部停止，6185/6199/6099 不再监听，服务器为唯一实例 | 2026-09-28 13:56 | [2026-09-28 13:56] |
| 13 | bt-he1k SillyTavern 只绑 `127.0.0.1:8000`，且 `basicAuthMode` 为 `false` | 已按本条预案执行：**先开 `basicAuthMode`**（凭据沿用 config.yaml 里的，脚本不回显密码，验证 401 → 带凭据 200），再由 nginx 在 `80`（`default_server`）与 `443 ssl` 上对外反代 ⇒ 公网无凭据得 401、带凭据 200 | 2026-09-28 21:55 | [2026-09-28 21:55] |
| 8 | AstrBot WebUI 只有 HTTP，登录凭据在链路上明文 | 面板改由**自己终结 TLS**：`dashboard.ssl.enable=true` + 把酒馆那张自签证书只读挂进容器（`/AstrBot/certs`），并把 compose 里那个 `6185:6185` 的明文发布改成只认 TLS。验证：`https 127.0.0.1:6185` → 200、`http` → 000（明文口已不监听）、`/api/stat` 仍 401；顺带把此前无代理却为 `true` 的 `trust_proxy_headers` 改成 `false`（否则可伪造 `X-Forwarded-For` 绕过登录限流）。执行 `scripts/deploy/put-astrbot-panel-behind-tls.sh` | 2026-10-09 19:12 | [2026-10-09 19:12:00] |
| 17 | 公网入口 HTTPS-by-IP 用自签证书会告警，且纯 HTTP 那条上密码是明文 | 用户拍板**采用自签**（不建私有 CA 装手机信任库）：`80` 改为 `return 301 https://$host$request_uri;`，明文那条路消失；443 与面板 6185 共用同一张 10 年自签证书（SAN = `IP:<TEST_HOST_IP>` + `DNS:st.<PUBLIC_DOMAIN>`）⇒ 手机只需点一次「继续」。决策记入 [`docs/decisions/ADR-0004-tencent-domain-block.md`](../docs/decisions/ADR-0004-tencent-domain-block.md) 的「决策（2026-10-09，用户拍板）」 | 2026-10-09 19:12 | [2026-10-09 19:12:00] |

---

## #20 详析：napcat2 反复「被踢下线」

> 排查时间 2026-09-29 11:30–11:40，**全程只读**（未改配置、未重启任何容器）。证据均为服务器实测。

**结论（一句话）**：`<QQ_ACCOUNT_B>` 的掉线是**腾讯服务端主动踢下线**（`KickedOffLine`）——**不是**容器崩溃、**不是**内存不足、**不是**配置差异、**也不是**本机重启引起的。

### 已确认的事实（每条附证据）

1. **掉线时刻 = 2026-09-29 10:44:16**（本地时间）。原文：`<BOT_NICK_B> | [KickedOffLine] [下线通知] 你的账号当前登录已失效，请重新登录。`，紧接 `账号状态变更为离线`，随后 NapCat 自己记 `账号被踢下线，正在重启 Worker 以重新创建 QQ 登录服务`。
2. **不是进程崩溃**：两容器 `OOMKilled=false`、`ExitCode=0`；`crash_files/` 与 `Crashpad/` 里**没有任何 dump**（只有 09-28 的 `client_id`）；容器内 `qq` 进程全程存活。
   - ⚠️ 方法论修正：**`RestartCount` 不能用来判断"从没重启过"**——`docker restart`（手工）不增加该计数。要看 `State.StartedAt`。此前据此推断"运行中掉线"结论侥幸正确，但依据不牢。
3. **不是资源问题**：`docker stats` 显示 napcat2 **169 MiB** / napcat1 **208 MiB**——**稳定的那个反而更吃内存**；宿主机 3.6 GB 总内存、约 1.6 GB 可用、swap 仅 86 MB、load 0.16；`dmesg` 无 OOM / cgroup kill。
4. **不是配置差异**：两服务 compose（除端口 / 固定 MAC / 卷）、`napcat_*.json`、`onebot11_*.json` 逐项对比，**只有两处差异**——反连地址（`6199` vs `6200`）与固定 MAC，其余完全一致。
5. **不是宿主机网络 / 内核**：掉线那一刻（10:44:16）`journalctl` 内**没有任何**网络或内核事件。日志里可见的 10:44:35 是**部署引起的 astrbot 重启**，比掉线**晚 19 秒**，且只影响 OneBot 反向 WS，不影响 QQ 登录态。
6. **WS 断开 ≠ QQ 掉线**（重要区分）：napcat1 也频繁报 `反向WebSocket 连接意外关闭`（08:48 / 09:01 / 10:16 / 10:24 / 10:44 / 10:47…），但它**每次自动重连且 QQ 登录一直有效**——这些断连与 `docker restart astrbot` 高度重合，**是我们自己部署造成的**。真正的故障是 napcat2 的 **QQ 登录态**被踢。

### 为什么上午加的 `ACCOUNT` 没救回来

- `ACCOUNT` 只在**容器启动**时生效：`/app/entrypoint.sh:222-223` 为 `if [ -n "${ACCOUNT}" ]; then gosu napcat /opt/QQ/qq --no-sandbox -q $ACCOUNT`。
- 被踢后走的是 **NapCat 内部重启 Worker**，**不经过 entrypoint**，因此日志出现 `没有 -q 指令指定快速登录，将使用二维码登录方式`——**`-q` 根本没带上**。
- 即使手工 `docker restart`（走 entrypoint、带上 `-q`）**依然失败**：`快速登录错误： 登录态已失效，请重新登录。`
- ⇒ **结论：`ACCOUNT` 覆盖「容器重启 / 机器重载」，覆盖不了「被服务端踢」。** 被踢后只能人工扫码。
- NapCat 另提供 `NAPCAT_QUICK_PASSWORD` / `NAPCAT_QUICK_PASSWORD_MD5` 作为回退（当前**未配置**，日志明确提示了这一点）。

### 最可能的原因（排序 + 依据）

1. **腾讯风控 / 社交风控落在该账号上**（最可能）。依据：NapCat 官方「安全相关」文档把同类现象直接归到风控并给了处置建议；该号是**单号高频活动**（进外部群、收陌生人临时消息），从**非官方客户端 + 数据中心 IP** 登录。
2. **该账号在别处也登着**（手机 / 其它电脑 / 本地 NapCat）→ 客户端互踢。**服务器侧无法证实**，需问用户。时间上不矛盾（08:34 登录、10:44 被踢，存活约 2 小时 10 分）。
3. 其余（崩溃 / 资源 / 配置 / 本机重启）**已被证据排除**。

### NapCat 官方处置建议（权威来源：[安全相关](https://doc.napneko.icu/other/security)）

- 「**频繁掉线问题可通过更换账号或设备来有效改善**」——官方承认这是账号/设备相关问题。
- 「遇到**社交风控**时，解除限制后重新运行即可，此类限制通常不会频繁触发」。
- 「如无法更换账号或设备，可尝试在配置中将 **`o3Hook` 设置为 0** 以关闭包拦截」← **我们当前是 `o3HookMode: 1`，这条还没试过。**
- 「避免在**同一 IP / 设备**上同时登录 Bot 账号与常用账号」。
- 网络环境复杂导致登录困难：换 IP / 重新拨号，或用 `NAPCAT_PROXY_ADDRESS` / `NAPCAT_PROXY_PORT` 配 SOCKS5 代理。

### 错误码语义（**结论：没有权威映射，不猜**）

- `Login Error,ErrType: 1 ErrCode: 3`：被踢**之后**约每 2 分钟一次的**重试循环**（本容器生命周期内累计 **24 次**）。
- `ErrCode: 10`：出现在 `二维码已被扫描，等待确认...` 之后 5 秒（11:26:59 → 11:27:04）。
- NapCat **未公开** ErrCode 映射表；官方仓库同类报错出现过 `ErrCode 5`（[#2063](https://github.com/NapNeko/NapCatQQ/issues/2063)）、`ErrCode 8`（[#1568](https://github.com/NapNeko/NapCatQQ/issues/1568)、[#650](https://github.com/NapNeko/NapCatQQ/issues/650)），属同一外层包装 + 不同内码。**具体含义【未拿到】。**
- 附带发现：issue #2063 记录「**控制台扫码报错、WebUI 扫码正常**」（同版本 4.18.28）——扫码优先用 WebUI 更稳。

### 一处尚未解释的现象（如实记录）

- **11:26:59** 日志出现 `二维码已被扫描，等待确认...`，**而用户明确表示他没有扫码**。可能是腾讯侧状态错乱、该码被其它客户端取用、或此前动作的延迟确认。**【推测，未定论】**。已知后果：该状态**卡死出不来**，只能 `docker restart` 清掉。

### 监控缺口（本次暴露的真正缺陷）

- 服务器上**没有任何针对容器 / 机器人存活的监控或告警**：`crontab` 只有腾讯 stargate 保活，systemd timer 只有系统自带的 sysstat / logrotate 等。
- 因此掉线**只能靠用户发现"发消息没人回"才知道**。**这是本问题中最容易修、收益最直接的一条。**

### 建议方案（按性价比分级）

**① 立刻可做（不需要用户在场）**
1. `o3HookMode` 1→0：先备份 `napcat.json`，改后重启容器，一条命令可回滚。这是 NapCat 官方对"频繁掉线"的明确建议。
2. **加掉线告警**：小脚本检查 napcat 日志 / 登录态，命中 `KickedOffLine` 或"未登录"就**用 napcat1 给用户发一条 QQ 消息**——napcat1 从不掉，是最可靠的告警通道。
3. **减少无谓重启**：合并部署批次；避免短时间内反复 `docker restart napcat2`（每次都是一次新的登录尝试，可能加重风控）。
4. **扫码优先走 WebUI**（6100），而不是控制台二维码。

**② 需要用户配合 / 回答**
- 见下节三个问题。

**③ 结构性**
- 换号 / 换 IP / 配 SOCKS5 代理（NapCat 文档路径）；或接受"掉了就人工扫一次"。

### 需要用户回答的确切问题

1. `<QQ_ACCOUNT_B>` 是否**同时**登录在您的手机 QQ、或任何其它电脑 / 客户端 / 本地 NapCat 上？**今天 10:44 前后您是否在手机上用过这个号的 QQ？**
2. **对照组**：`<QQ_ACCOUNT_A>`（从不掉的那个）是否**只**在 NapCat 上用，手机 / 其它设备都不登？如果两个号的使用方式不同，就能直接定位到原因。
3. 是否愿意配置 `NAPCAT_QUICK_PASSWORD`（把该 QQ 的**密码**存到服务器）换取"掉线后自动重登"？**默认不建议**：被踢会让登录态作废，密码同样可能失败，而把密码放在服务器上是不必要的风险——**我倾向先做"告警"而不是"存密码"**。

---

## 维护方式

1. 发现问题 → 加「未解决」表，写清影响与缓解。
2. 缓解措施落地 → 更新「缓解措施」列。
3. 彻底解决 → 移到「已解决」，写解决方式与时间，关联 CHANGELOG 记录。
4. 有历史价值的事故 → 同步写 `docs/postmortems/`。
