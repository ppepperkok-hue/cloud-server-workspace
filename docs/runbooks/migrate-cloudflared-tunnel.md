# migrate-cloudflared-tunnel：把本机的 Cloudflare Tunnel 迁到服务器

- **名称**：把 Windows 上的 `cloudflared` 具名隧道迁到 bt-he1k，改由服务器承载业务域名
- **适用环境**：test（2026-09-28 已在 bt-he1k 执行完成）
- **风险级别**：中 —— 域名切错会让线上站点 502；隧道凭据是机密
- **前置条件**：Cloudflare 账号里有**源证书** `cert.pem`（`cloudflared tunnel login` 产生，只在本机）；域名已在 Cloudflare 托管
- **最近更新**：2026-09-28
- **脚本**：[`install-cloudflared.sh`](../../scripts/deploy/install-cloudflared.sh) · [`setup-cloudflared-tunnel.sh`](../../scripts/deploy/setup-cloudflared-tunnel.sh)

## 迁移前的样子

本机一个具名隧道（`<TUNNEL_NAME_CRC>`）扛了 6 个主机名，全部指向 `127.0.0.1:<本机端口>`：

| 主机名 | 本机端口 | 实际后端 |
| --- | --- | --- |
| `<PUBLIC_DOMAIN>`（apex） | 8000 | SillyTavern |
| `st.<PUBLIC_DOMAIN>` | 8000 | SillyTavern |
| `astr.<PUBLIC_DOMAIN>` | 6185 | AstrBot |
| `napcat1.<PUBLIC_DOMAIN>` | 6099 | NapCat 一号 |
| `napcat2.<PUBLIC_DOMAIN>` | 6100 | NapCat 二号 |
| `crc.<PUBLIC_DOMAIN>` | 3789 | Codex Remote Contact（**只在 Windows 上跑**） |

前五个的后端早已迁到服务器，本机端口只是 SSH 隧道在转发；真正只属于 Windows 的只有 `crc`。

## 步骤

1. 服务器装二进制（不用配仓库）：
   ```bash
   bash scripts/deploy/install-cloudflared.sh
   ```
   > GitHub Release 直连很慢（38 MB 实测约 26 分钟），脚本失败时会自动退到 `m.daocloud.io` 的 GitHub 镜像前缀。

2. 在**有 `cert.pem` 的机器**上建服务器专用隧道：
   ```powershell
   cloudflared tunnel create bt-he1k-server
   ```
   把新生成的 `<新隧道ID>.json`（仅此一个文件，**不要**把 `cert.pem` 传上去）放到服务器 `/etc/cloudflared/`。

3. 服务器侧写配置 + 装服务（主机名与端口**作为参数传入**，脚本本身不含任何真实域名）：
   ```bash
   bash scripts/deploy/setup-cloudflared-tunnel.sh /root/cf-tunnel.json <新隧道ID> \
       astr.<PUBLIC_DOMAIN>=6185 napcat1.<PUBLIC_DOMAIN>=6099 napcat2.<PUBLIC_DOMAIN>=6100 \
       st.<PUBLIC_DOMAIN>=8000 <PUBLIC_DOMAIN>=8000
   ```

4. 把 DNS 指向新隧道（**这一步必须用 `cloudflared` ≥ 2026.9**）：
   ```bash
   cloudflared tunnel route dns --overwrite-dns bt-he1k-server <主机名>
   ```
   > **踩坑**：本机装的 2026.7.3 上 `--overwrite-dns` **不覆盖**，只打印 `already configured to route to your tunnel tunnelID=<旧ID>` 就退出，退出码还是 0。换 2026.9.3（服务器上那份）执行才真的改掉。判断是否生效：**再跑一遍**，看它报的 `tunnelID` 是新是旧。

5. 验证「确实由服务器承载」的**决定性做法**：把 Windows 侧的 `cloudflared` 整个停掉，再访问 6 个域名。
   - 前五个仍 200 → 已经在服务器上 ✓
   - `crc` 变 502 → 确实还依赖 Windows ✓

6. 收尾：把 Windows 的 `config.yml` 裁成只剩 `crc` 一条（备份为 `config.yml.pre-migration-backup`）并重启本机 cloudflared；服务器上删掉临时拷过去的 `cert.pem`（跑隧道用不到它）。

## 验证

```bash
systemctl is-active cloudflared && systemctl is-enabled cloudflared
journalctl -u cloudflared -n 30 --no-pager -o cat | grep -ai 'registered tunnel connection'
curl -sk -o /dev/null -w '%{http_code}\n' https://astr.<PUBLIC_DOMAIN>/
```
服务端侧每个 origin 都能先单独探一遍（脚本最后会自动做）：
`astr → 200`、`napcat1/2 → 301`（`/webui` 的目录跳转，正常）、`st / apex → 200`。

## 回滚

```bash
systemctl disable --now cloudflared && rm -rf /etc/cloudflared
```
DNS 改回旧隧道（在 Windows 上跑）：`cloudflared tunnel route dns --overwrite-dns <旧隧道> <主机名>`；
Windows 的 `config.yml` 用 `config.yml.pre-migration-backup` 覆盖回来并重启本机 cloudflared。
最坏情况：旧隧道一直在 Windows 上跑着，DNS 指回去即刻恢复。

## 注意事项

- **隧道 ID 与凭据等同密码**：`<隧道ID>.json` 只放服务器 `/etc/cloudflared/`（600）和本地 `secrets/`，绝不入库。
- 服务器侧 `dnsResolve`/QUIC 可能被部分拦截，cloudflared 会自动降级到 HTTP2（日志里有 `Environment ready with degraded transport`），功能不受影响。
- 域名的**认证**不在这条隧道上：Cloudflare Tunnel 只是把流量送进来。`<PUBLIC_DOMAIN>` 与 `st.*` 指向的 SillyTavern **自身没开认证**，见 [`state/KNOWN-ISSUES.md`](../../state/KNOWN-ISSUES.md) #14。
- 新增业务域名时：先在服务器 `config.yml` 的 `ingress` 里加 `hostname/service`，再 `route dns`，最后才对外公布。
