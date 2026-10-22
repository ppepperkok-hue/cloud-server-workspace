# harden-bt-panel：加固宝塔面板（HTTPS + IP 白名单）

- **名称**：给宝塔面板开启 HTTPS 并设置访问 IP 白名单
- **适用环境**：test（bt-he1k 已于 2026-09-28 执行）
- **风险级别**：中 —— 白名单写错会把自己挡在面板外（SSH 不受影响，用 `bt 13` 即可复位）
- **前置条件**：能 SSH 登录该主机；已确认**自己出口的公网 IP**（白名单）与**面板对外地址**（证书 SAN）；根分区可写
- **最近更新**：2026-10-21
- **脚本**：[`scripts/maintenance/harden-bt-panel.sh`](../../scripts/maintenance/harden-bt-panel.sh)（幂等，可重复执行）

## 步骤

1. 先取出口 IP，不要凭猜：

   ```bash
   ssh -i secrets/ssh/lighthouse-he1k.pem root@<TEST_HOST_IP> 'echo $SSH_CLIENT'
   # 输出形如 "<OPERATOR_IP> 54798 22"，第一段就是面板白名单要填的 IP
   ```

2. 跑脚本（会先把面板 `data`/`ssl` 备份到 `/root/backups/bt-panel-harden-<时间戳>/`，并写 `ROLLBACK.txt`）：

   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\utils\ssh-bt-he1k.ps1 `
       -ScriptPath .\scripts\maintenance\harden-bt-panel.sh -ScriptArgs "<OPERATOR_IP> <TEST_HOST_IP>"
   ```

   两个参数依次是「白名单 IP」和「面板对外地址」，**中间用一个空格分开**。第二个参数会写进自签证书的 `subjectAltName`，可以是 IPv4 / IPv6 / DNS 名；仓库是公开的，脚本里不存默认值，所以每次都必须给。缺参、占位符（`<...>`）、带协议或端口的 URL、非法地址都会在**备份目录创建之前**退出，不会生成证书、不会重启面板。

   参数请用空格分隔，**不要用逗号**：`powershell -File` 下 PowerShell 5.1 会把整个 `-ScriptArgs` 值绑成**一个**字符串，逗号不会拆分它（`-ScriptArgs "<OPERATOR_IP>,<TEST_HOST_IP>"` 会把整串当成白名单，第二个参数为空，脚本以 "no host address given" 退出）。包装脚本按空白拆分并逐个单引号传给远端 bash，所以白名单里若本身含逗号，应作为单个参数整体传入。

   也可以只传白名单、把地址放进环境变量：`BT_PANEL_HOST=<TEST_HOST_IP>`。

3. 临时放开白名单（面板对所有来源开放）：把参数换成 `none`，第二个参数照旧要给。

## 验证

```bash
curl -sk -A 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) Chrome/131.0.0.0' \
     -o /dev/null -w '%{http_code}\n' https://<TEST_HOST_IP>:8888/<PANEL_ENTRY>
```

- `200` —— 面板可用，且本机在白名单内；
- `403` —— 本机不在白名单（白名单确实生效，先确认这是你要的结果）；
- `404` —— 十有八九是**没带浏览器 UA**（见 [`../decisions/ADR-0002-bt-panel-ua-gate.md`](../decisions/ADR-0002-bt-panel-ua-gate.md)），不是故障。

再确认明文端口已关：

```bash
curl -s -o /dev/null -w '%{http_code}\n' http://<TEST_HOST_IP>:8888/<PANEL_ENTRY>
# 预期：000（连接失败，说明只剩 HTTPS）
```

## 回滚

```bash
# 恢复加固前的面板配置（含 ssl/ 与 data/），回到「无 SSL、无白名单」
tar xzf /root/backups/bt-panel-harden-LAST/panel-data.tgz -C /www/server/panel
tar xzf /root/backups/bt-panel-harden-LAST/panel-ssl.tgz  -C /www/server/panel
/etc/init.d/bt restart

# 只想放开 IP 白名单而不动证书：
bt 13
```

## 注意事项

- 白名单**只支持单个 IP 或 `a.b.c.d-a.b.c.e` 区间，不支持 CIDR**——面板里填 `/` 会被拒。
- 自签证书的 SAN 只写第二个参数给的地址（`IP:` 或 `DNS:`）。旧脚本里的公网 IP、内网 IP、主机名三个值都是占位符，现不再自动附加；证书是自签的，浏览器本来也不会默认信任。
- 证书已存在时脚本保持原样（幂等）；只有缺失或 `FORCE_SSL=1` 才重签。生成后会用 OpenSSL 复验 SAN：OpenSSL ≥ 3.4 用 `x509 -checkip` / `-checkhost`，更早的 3.x（目标机 OpenCloudOS 9.6 属于此类）自动改用 `openssl verify -verify_ip` / `-verify_hostname`。两条路径都由 OpenSSL 自己做地址归一化，`2001:db8::10` 这类写法不会被误判；对不上就拒绝安装、保留旧证书。若连复验都做不了（工具本身报错），脚本会明确报「无法在本机复验」并且**不安装**证书。旧证书 SAN 里若还带着 `<...>` 占位符，脚本只打 `WARNING`，重签请直接执行脚本并加 `FORCE_SSL=1`。
- 白名单文件是 `/www/server/panel/data/limitip.conf`，逗号分隔；**改完必须重启面板**，因为进程内有 1 小时缓存。
- 本机出口 IP 若是动态的，IP 一变面板就打不开。此时用 SSH 进去跑 `bt 13` 复位即可，SSH 永远不受面板白名单影响。
- **不要用宝塔自带的「开启面板 SSL」**：它的 `CreateSSL()` 用 md5 给自签证书签名，现代浏览器与 OpenSSL 3 都会拒绝；脚本改用 SHA-256 自签。
- 执行完按 `AGENTS.md` 三件套：验证 → 追加 `state/CHANGELOG.md` → 更新 `state/TASKS.md`。
