# ADR-0004：这台腾讯云机器不能用「域名」访问 80 端口

- **状态**：已接受
- **日期**：2026-09-28
- **决策者**：agent

## 背景

需要把两个 NapCat 的 WebUI 开放给用户。NapCat 的 WebUI 写死挂在 `/webui/`、`/api/`、`/auth/` 这几个**根路径**上，没有可配置的 base path，因此两个实例**不可能共用一个 origin**（路径必然冲突）。

于是我在 80 端口上用 `server_name` 拆了两个主机名，靠 `nip.io`（会解析回内嵌 IP 的公共通配 DNS）省掉改云安全组的步骤：

- `napcat1.<TEST_HOST_IP>.nip.io`
- `napcat2.<TEST_HOST_IP>.nip.io`

**服务器本地按 Host 头验证完全正常**：`/webui/` 返回 200，标题 `NapCat WebUI`。但从外网访问时：

```
HTTP/1.1 302（后为 403）
Location: https://dnspod.qcloud.com/static/webblock.html?d=napcat1.<TEST_HOST_IP>.nip.io
```

腾讯云在网络层对 **80 端口的 HTTP 请求按 Host 头做「未备案域名」拦截**，返回 webblock / AccessDeny 页；**按 IP 访问完全不受影响**（`http://<TEST_HOST_IP>/` 始终 200）。也就是说请求根本没到这台机器。

## 决策

bt-he1k 的对外 Web 入口**只用「IP + 端口」**（或 443 + 已备案域名），**不要依赖任何域名形式的 Host 走 80 端口**。需要在一台机器上拆多个服务时，用**不同端口**而不是**不同域名**。

## 备选方案与权衡

| 方案 | 优点 | 缺点 | 结论 |
| --- | --- | --- | --- |
| 80 端口按域名拆 vhost（nip.io / sslip.io） | 不占新端口，不用改云安全组 | 被腾讯云未备案拦截，外网直接 403 | ❌ 实测否掉 |
| 不同端口 + IP 访问 | 不被拦截，配置最直白 | 需要用户在控制台放行端口 | ✅ 需要对外时用 |
| 单端口按路径拆 + `sub_filter` 改写 | 不用放行端口 | NapCat WebUI 的 `/webui`、`/api` 写死，改写脆弱易碎 | ❌ |
| SSH 端口转发（隧道） | 不额外暴露任何端口，流量加密 | 只能从能 SSH 的机器访问 | ✅ 管理界面的默认做法 |

## 后果

- 管理类界面（NapCat WebUI）默认走 **SSH 隧道**：见 [`scripts/utils/napcat-webui-tunnel.ps1`](../../scripts/utils/napcat-webui-tunnel.ps1)，本地映射到 `127.0.0.1:6099` / `127.0.0.1:6100`。
- 要对外提供服务，必须在腾讯云控制台放行端口；而且**将来若要用域名走 80/443，该域名需要先完成 ICP 备案**，否则同样被拦。
- 这条也解释了为什么不能像在普通 VPS 上那样随手用 `nip.io` 当临时域名——本机保留的 `napcat.conf` 已按此结论删除。
