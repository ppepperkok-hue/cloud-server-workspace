# ADR-0005：用 loopback HTTP agent（ops-agent）取代「一次性 SSH」做日常运维通道

- **状态**：已接受
- **日期**：2026-10-09
- **决策者**：agent（用户要求「ssh 太慢了，看能不能在服务器上装个 agent」）

## 背景

在这台机器上做日常运维，一直是「每条命令起一次 `ssh.exe`」：

```powershell
.\scripts\utils\ssh-bt-he1k.ps1 -Command 'uptime'
```

实测单次成本（Windows PowerShell 5.1，本机 → 香港）：

| 路径 | 往返耗时 | 说明 |
| --- | --- | --- |
| `ssh-bt-he1k.ps1 -Command`（一次性 SSH） | **1719 ms** | 外层 powershell 启动 + ssh.exe 握手 + 认证 |
| `rsh.ps1`（agent，但要再起一层 powershell） | 1709 ms | 只省掉握手，被进程启动吃掉 |
| **直接对 agent 发 HTTP（同一 shell 内）** | **124 ms**（首次 378 ms） | 省掉两次进程启动与整段 SSH 握手 |

也就是说**瓶颈不是网络，是「每次调用都要新起进程 + 重新握手 + 重新认证」**。另外一次性 SSH 还有三个一直在咬人的硬限制：

1. **argv ~8 KB 上限**：超过就静默丢尾部（见 [ADR-0001](ADR-0001-windows-ssh-argv-limit.md)）。
2. **引号地狱**：`-Command` 里带 `"` 会被 PowerShell 5.1 拆参数；`{{.Names}}`、`for ...; do ...; done` 之类经常报 `unexpected end of file`，只能改成先落地脚本。
3. **拿不到后台任务**：一条命令最多扛到工具超时；下载 26 分钟的 cloudflared 只能干等或另想办法。

顺手验证了一条看起来最省事的路：**SSH 连接复用（ControlMaster）在本机不可用**。Windows OpenSSH 接受这些参数，但实际连接时报：

```
mux_client_request_session: read from master failed: Connection reset by peer
Failed to connect to new control master
```

## 决策

在服务器上装一个**只监听 127.0.0.1 的小型 HTTP 执行服务 `ops-agent`**（`/opt/ops-agent/ops-agent.py`，纯标准库，systemd 常驻），本机通过**已有的 SSH 隧道**（`napcat-webui-tunnel.ps1` 增加转发 `7777`）访问它。

- 服务器侧：`scripts/deploy/install-ops-agent.sh`
- 本机侧：`scripts/utils/agent.ps1`（可点源，主用）/ `scripts/utils/rsh.ps1`（命令行包装）
- 运行手册：[`docs/runbooks/ops-agent.md`](../runbooks/ops-agent.md)

命令以 **JSON** 传输，因此引号、管道、重定向、`{{...}}` 全部无须转义；输出带 exit code、stdout/stderr 分离、耗时；另有后台任务（`/spawn` + `/job`）与文件上传下载（`/put`、`/get`），不再需要 scp。

## 安全模型（关键）

| 措施 | 说明 |
| --- | --- |
| 只绑 `127.0.0.1:7777` | 公网**没有任何新监听**；`ss -lntp` 可验证 |
| `Authorization: Bearer <token>` | token 存 `/etc/ops-agent/token`（0600 root），比较用 `hmac.compare_digest`（常数时间）；本机副本在 gitignore 的 `secrets/ops-agent-token.txt` |
| 入口仍需 SSH 私钥 | 唯一通路是 SSH 隧道，所以**能碰到 agent 的人本来就能 SSH 上来**；agent 没有扩大攻击面 |
| 全量审计 | 每条请求落一行 JSON 到 `/var/log/ops-agent/commands.log`（含命令、exit、耗时，超 8 MiB 轮转） |
| 输出上限 | 每路流最多保留尾部 1 MiB，防止 `yes` 之类把内存打满 |

**必须明确的残余风险**：agent 以 **root** 运行并执行任意 shell，所以 **token 等价于 root 密码**。它不对外监听这一点是主要防线；不要把 token 提交进仓库（已在 `secrets/`，且 `redact-workspace.py` 会兜底）。

## 备选方案与权衡

| 方案 | 优点 | 缺点 | 结论 |
| --- | --- | --- | --- |
| 继续一次性 SSH（现状） | 无新组件、无新密钥 | 每次 ~1.7 s；argv/引号/超时三重限制 | ❌ 用户明确嫌慢 |
| SSH 连接复用 ControlMaster | 零新组件 | **Windows OpenSSH 实测不可用**（见上） | ❌ 实测否掉 |
| 常驻交互式 ssh 会话（喂 stdin） | 复用连接 | PowerShell 管道会改行尾、读取输出要自己解析提示符，脆弱 | ❌ |
| 把执行接口挂到公网端口（带 token） | 手机也能用 | 无谓地把 root 执行面暴露到互联网 | ❌ 明确不做 |
| 走 Cloudflare Tunnel 调 agent | 不用 SSH | 实测绕美国，1.2 s 起步（见 KNOWN-ISSUES #16），比 SSH 还慢 | ❌ |
| **loopback agent + 既有 SSH 隧道** | 124 ms；无新暴露；解决引号/超时/传文件 | 多一个自研常驻进程与一份 token | ✅ 采用 |

## 后果

- 日常命令、长任务、传文件一律走 `agent.ps1`；`ssh-bt-he1k.ps1` 保留用于**引导**（agent 未装/隧道未起）和隧道断开时的兜底。
- 隧道脚本现在转发 `6099 / 6100 / 8000 / 6185 / 7777`；**隧道一断，agent 也一起不可达**（设计如此）。
- 服务器上多了一个 systemd 单元 `ops-agent.service`（enabled，`Restart=always`），升级 agent 只需重跑 `install-ops-agent.sh`。
- `ssh-bt-he1k.ps1` 同时被改进：超过 7000 个 base64 字符的脚本不再报错，改为**走 stdin**（`tr -d '\r\n' | base64 -d | gunzip | bash -s`），大脚本也能一条命令发过去。
