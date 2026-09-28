# connect-bt-he1k：连接测试服务器 bt-he1k

- **名称**：通过 SSH 密钥连接测试服务器 bt-he1k（<TEST_HOST_IP>）
- **适用环境**：test
- **风险级别**：低（本 runbook 只建立连接与只读检查；在该机上做写操作另走变更流程）
- **前置条件**：
  - 本工作区 `secrets/ssh/lighthouse-he1k.pem` 存在（不入库，仅本地）
  - 腾讯云轻量控制台已把密钥对 `<TEST_USER>` 绑定到实例 `<INSTANCE_ID>`，并**重启过实例**（只绑定不重启不生效）
  - 本机可出网访问 `<TEST_HOST_IP>:22`
- **最近更新**：2026-09-28

## 步骤

1. 直接连（Linux / macOS / Windows 通用）：

   ```bash
   ssh -i secrets/ssh/lighthouse-he1k.pem \
       -o IdentitiesOnly=yes \
       -o StrictHostKeyChecking=accept-new \
       -o UserKnownHostsFile=./tmp/known_hosts \
       root@<TEST_HOST_IP>
   ```

   - `IdentitiesOnly=yes` **必须加**：否则 ssh 会先试 ssh-agent 或其他身份，可能耗尽 `MaxAuthTries`(6) 而误报 `Permission denied`。
   - 用户固定 `root`。镜像里的 `lighthouse` 用户也带 `/bin/bash`，但没有绑定这把密钥，连不上。

2. Windows 上跑单条远程命令（工作区封装脚本，自动处理密钥与 known_hosts）：

   ```powershell
   .\scripts\utils\ssh-bt-he1k.ps1 -Command 'uptime; hostname'
   ```

   若被执行策略拦下，或需要新开进程执行：

   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\utils\ssh-bt-he1k.ps1 -Command 'uptime; hostname'
   ```

   > 本机只有 Windows PowerShell 5.1（`powershell.exe`），**没有装 `pwsh`**，别用 `pwsh -File`。
   > `-Command` 里**不要写内嵌双引号**（如 `echo "hi"`）：PowerShell 5.1 向子进程重新拼命令行时不转义内嵌引号，参数会被拆散并报 `A positional parameter cannot be found that accepts argument '...'`。需要引号就把命令写进脚本文件走 `-ScriptPath`。

3. 跑整段脚本（脚本自动 gzip+base64 后作为**单个 argv** 送到远端 `base64 -d | gunzip | bash -s`）：

   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\utils\ssh-bt-he1k.ps1 -ScriptPath .\scripts\healthcheck\server-inventory.sh
   ```

   > 别把脚本 base64 后直接塞进命令行（`echo <b64> | base64 -d | bash -s`）：实测 argv 超过约 8000 字符会被 `ssh.exe` 静默截断，远端只打印 base64、**退出码却是 0**。也别走 stdin 管道（PowerShell 会把 LF 改成 CRLF，bash 收到 `\r` 报错、退出码 127）。结论与权衡见 [`../decisions/ADR-0001-windows-ssh-argv-limit.md`](../decisions/ADR-0001-windows-ssh-argv-limit.md)。

## 验证

```bash
whoami                                   # 预期：root
hostname                                 # 预期：<TEST_HOST_HOSTNAME>
ssh-keygen -lf /root/.ssh/authorized_keys
# 预期：2048 SHA256:<SSH_KEY_FINGERPRINT> skey-j0y7l8y9 (RSA)
sshd -T | grep -E '^(passwordauthentication|permitrootlogin|port)'
# 预期：passwordauthentication no / permitrootlogin yes / port 22
```

判定标准：ssh 退出码 0，输出无 `Permission denied`；上面第 3 条的指纹必须与本地 `ssh-keygen -lf secrets/ssh/lighthouse-he1k.pem` 的输出**完全一致**。

面板（HTTPS）验证——**必须带浏览器 UA**，否则宝塔会回 404 误导你：

```bash
curl -sk -A 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) Chrome/131.0.0.0' \
     -o /dev/null -w '%{http_code}\n' https://<TEST_HOST_IP>:8888/<PANEL_ENTRY>
# 预期：200
# 无 -A 时得到 404 —— 那是反扫描拦截，不是故障；非白名单来源得到 403
```

判定标准：带 UA 得 `200`；`403` 说明出口 IP 不在面板白名单里；带 UA 仍是 `404` 且正文不是登录页，才算真故障。详见 [`../decisions/ADR-0002-bt-panel-ua-gate.md`](../decisions/ADR-0002-bt-panel-ua-gate.md)。

## 回滚

- 本 runbook 只建立连接并做只读检查，不修改主机，无需回滚。
- 若误在主机上产生副作用，按 `docs/operations/02-safety.md` 止损，并在 `state/CHANGELOG.md` 记录。

## 注意事项

- 私钥只放 `secrets/`；`secrets/*`、`*.pem` 均已在 `.gitignore` 中。**绝不要**把它写进文档、日志或提交。
- 主机 `PasswordAuthentication no`：没有这把密钥就进不去；控制台只剩「重置密码」或「换绑密钥」两条后路。
- 绑定/更换密钥后**必须重启实例**才生效。2026-09-28 首次连接失败正是这个原因（绑定后未重启，`authorized_keys` 尚未下发）。
- 面板入口是 `http://<TEST_HOST_IP>:8888/<PANEL_ENTRY>`（安全入口 `/<PANEL_ENTRY>`）；直接访问 `:8888/` 会返回 404，这不是故障。
- 连上后如需写操作（装环境、改配置、重启服务），先在 `state/TASKS.md` 认领，并按 `docs/operations/02-safety.md` 的变更控制流程执行。
