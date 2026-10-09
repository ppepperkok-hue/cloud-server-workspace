# napcat-drop-alert：NapCat QQ 掉线告警（监控）

> 关闭 `state/KNOWN-ISSUES.md` #20 里记的那条"**监控缺口**"：服务器此前**零监控**，QQ 号掉线后没有任何人知道，只能靠用户自己发现"发消息没人回"。

- **名称**：NapCat QQ 登录态监控与掉线告警
- **适用环境**：test（bt-he1k）
- **风险级别**：低（只读探测 + 一条 QQ 消息；不重启任何容器、不改 NapCat / AstrBot 配置、不开放任何新端口）
- **前置条件**：root 权限；`napcat1` / `napcat2` 容器的 WebUI 分别发布在 `127.0.0.1:6099` / `6100`；`curl`、`python3`、`flock`（系统自带）
- **最近更新**：2026-09-29

## 1. 它解决什么

`<QQ_ACCOUNT_B>`（napcat2）会被**腾讯服务端踢下线**（`KickedOffLine`，详见 KNOWN-ISSUES #20）。此时：

- 该号的收发消息与「换班提醒」推送**静默失效**；
- **快速登录救不回来**（登录态作废），只能人工重新扫码；
- 在本次改造之前，**没有任何告警**，用户只能靠"没人回我"察觉到故障。

本监控补上这条：**掉线即主动通知**，并且**用稳定的账号去报告不稳定的账号**。

## 2. 设计（为什么这么做）

| 环节 | 选型 | 理由 |
| --- | --- | --- |
| **检测** | napcat2 **自己的 WebUI 状态接口** `POST /api/QQLogin/CheckLoginStatus` | 该 HTTP 服务在 QQ 未登录时**仍然应答**，所以它报的是**登录态**而不是"进程还活着"。比 grep `docker logs` 可靠：日志会轮转、是散文、且分不清"正在重连"与"被踢下线" |
| **发送** | napcat1（从不掉）WebUI 的 **Debug API**（OneBot action 透传） | **不改配置、不重启容器、不开放新端口**——只用了一个本来就在跑的 HTTP 服务 |
| **去重** | 同一故障 30 分钟内只报一次（`SILENCE_MINUTES`） | 该故障每 2 分钟复现一次，逐条告警会变成轰炸 |
| **防抖** | 连续 2 次探测失败才告警（`CONFIRM_FAILURES`） | 避免把一次瞬时抖动当成掉线 |
| **恢复** | 恢复后**再报一次** | 否则用户不知道可以继续用了 |
| **失败不静默** | 告警发不出去时**不记为已告警**（下次重试）+ 日志 ERROR + 退出码 3 | 两个号同时掉时，至少留下可发现的痕迹 |
| **心跳** | `HEARTBEAT_HOUR`（**默认关闭**） | `docs/operations/05-monitoring.md` §5 要求"监控本身也要被监控"：每天一条"我还活着"即死信开关 |

**判定"在线"的条件**：`isLogin=true` 且 `coreReady=true` 且 `loginPhase=ready`。三者任一不满足即视为掉线，并记录具体是哪一项不满足。

**告警内容**包含：哪个号、首次发现时间、现象（`loginPhase` 等原始判据）、**影响面与不受影响的清单**、**该做什么**（先确认手机上没登着这个号 → 用 WebUI 扫码 → 不要反复重启）。

## 3. 安装

```bash
# 1) 上传（本地工作区执行；脚本含中文，必须用 scp 而不是经文本管道传输）
scp scripts/healthcheck/check-napcat-login.sh   root@<TEST_HOST_IP>:/tmp/check-napcat-login.sh
scp scripts/healthcheck/install-napcat-alert.sh root@<TEST_HOST_IP>:/tmp/install-napcat-alert.sh

# 2) ADMIN_QQ 不进仓库：单独放文件、权限 600
ssh root@<TEST_HOST_IP> 'cat > /etc/napcat-alert.env <<EOF
ADMIN_QQ=<ADMIN_QQ>
SILENCE_MINUTES=30
CONFIRM_FAILURES=2
WEBUI_HELP=http://127.0.0.1:6100/webui/
HEARTBEAT_HOUR=
EOF
chmod 600 /etc/napcat-alert.env'

# 3) 安装（幂等）
ssh root@<TEST_HOST_IP> 'bash /tmp/install-napcat-alert.sh /tmp/check-napcat-login.sh'
```

安装产物（`install-napcat-alert.sh` 会先备份，并打印回滚命令）：

| 路径 | 作用 | 权限 |
| --- | --- | --- |
| `/usr/local/bin/check-napcat-login.sh` | 监控本体 | 755 |
| `/etc/napcat-alert.env` | 配置（**含 ADMIN_QQ**） | **600** |
| `/var/lib/napcat-alert/state.json` | 状态与凭据缓存（含 WebUI 会话凭据） | 600（目录 700） |
| `/var/log/napcat-alert.log` | 运行日志 | 640 |
| `/etc/cron.d/napcat-alert` | 每 5 分钟执行一次 | 644 |
| `/var/lock/napcat-alert.lock` | 防止重叠运行；单次运行上限 `NAPCAT_ALERT_RUN_TIMEOUT`（默认 **180 s**） | 600 |

## 4. 日常操作

```bash
/usr/local/bin/check-napcat-login.sh --status      # 看当前状态（不发消息）
/usr/local/bin/check-napcat-login.sh --reset       # 忘记状态（不发消息）
/usr/local/bin/check-napcat-login.sh --dry-run     # 只打印将要发送的内容
/usr/local/bin/check-napcat-login.sh --simulate up|down|unreachable   # 注入假探测结果（演练用）
tail -f /var/log/napcat-alert.log                  # 观察
```

**演练（不真掉线也能验证告警链路）**：

```bash
CONFIRM_FAILURES=1 /usr/local/bin/check-napcat-login.sh --simulate down   # 应真的收到一条告警
/usr/local/bin/check-napcat-login.sh --simulate down                      # 第二次：应被静默窗口拦住
/usr/local/bin/check-napcat-login.sh --simulate up                        # 应收到"已恢复"
/usr/local/bin/check-napcat-login.sh --reset
```

> 命令行显式导出的变量**优先于** `/etc/napcat-alert.env`（否则演练改不动参数）。

## 5. 排障

| 现象 | 先看什么 |
| --- | --- |
| 收不到告警 | `tail /var/log/napcat-alert.log`；若出现 `TARGET IS DOWN AND THE ALERT COULD NOT BE DELIVERED`，说明**发送方 napcat1 也不可用**，需先恢复 napcat1 |
| 日志里 `sender login failed` | napcat1 的 WebUI（`127.0.0.1:6099`）不通，或 `webui.json` 里的 token 变了 |
| 一直报掉线但用户说能用 | `curl` 看 `POST /api/QQLogin/CheckLoginStatus` 的原始返回；可能判定条件与 NapCat 版本行为对不上（见限制） |
| cron 没跑 | `systemctl status crond`；`/etc/cron.d/napcat-alert` 是否被改名（**带点的文件名会被 cron 忽略**） |
| **日志一行都不长、`state.json` 的 mtime 也不动** | **先怀疑锁被占住**（2026-09-29 → 10-09 就是这样瞎了 10 天）：`flock -n /var/lock/napcat-alert.lock true && echo FREE \|\| echo HELD`。若 HELD，用 `ps -eo pid,lstart,etime,stat,cmd \| grep napcat-alert` 找出那个活的调用（历史上是一个卡住的 `--simulate`，攥了 10 天 4 小时），`kill` 掉即恢复；脚本现已有 180 s 自带超时，正常不会再发生 |

**手动跑一次看结果**：`/usr/local/bin/check-napcat-login.sh; echo $?`（0 正常；3 = 掉线且告警没发出去）。

## 6. 已知限制与残余风险（如实记录）

1. **发送通道是 NapCat WebUI 的 Debug API，属内部接口**（`/api/Debug/create` + `/api/Debug/call`）。它能用、且经实测验证，但**不是 NapCat 的公开稳定契约**；**NapCat 升级后若改了它，告警会静默失效**。缓解：告警失败会打 ERROR 并退出码 3；如需更强保证，把心跳（`HEARTBEAT_HOUR`）打开——心跳不来即说明监控本身坏了。
2. **WebUI 登录方式**是 `POST /api/auth/login` + `sha256(token + ".napcat")`，同样属内部实现。凭据缓存在状态文件里、失效时自动重登，以避开 `loginRate` 限制。
3. **依赖 napcat1 作为通道**：两个号同时掉时告警发不出去（此时只留日志与退出码 3）。这是"用稳定信道报告不稳定信道"的固有边界。
4. **只监控登录态，不监控消息能否真正送达**：登录正常但消息被限流/吞掉的情况检测不到。
5. **心跳默认关闭**：不打开的话，"监控静默坏掉"依然只能靠人翻日志发现。

## 7. 回滚

```bash
rm -f /usr/local/bin/check-napcat-login.sh /etc/cron.d/napcat-alert
rm -rf /var/lib/napcat-alert
# 需要时恢复旧版本（安装脚本会打印备份目录）：
cp -a /root/backups/napcat-alert-<时间戳>/<文件> <原路径>
```

回滚后系统回到"零监控"状态，**不影响 napcat / AstrBot 的任何功能**（监控只读取状态并发送消息）。
