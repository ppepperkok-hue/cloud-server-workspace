# ADR-0006：脚本里的证书 SAN 复验要按 OpenSSL 版本走两条路径

- **状态**：已接受
- **日期**：2026-10-21
- **决策者**：agent

## 背景

`scripts/maintenance/harden-bt-panel.sh` 要把运行时传入的面板地址写进自签证书的 `subjectAltName`，并在安装前确认证书真的带上了这个地址——这是防止占位符 `<TEST_HOST_IP>` 原样进证书的最后一道闸。

最早的实现用 `openssl x509 -noout -checkip/-checkhost` 来复验。问题在于：**这两个选项是 OpenSSL 3.4 才有的**（3.5.0 才正式引入 `X509_check_ip` / `X509_check_host` 的命令行入口），而目标机 bt-he1k 是 OpenCloudOS 9.6，OpenSSL 大概率是 3.0.x。在 3.0 上这两条命令**根本不存在**，脚本会永远走不到「匹配成功」那一支，表现为「证书明明是对的，脚本却拒绝安装」。这是 ADR-0003 坑 6「静默不生效」的同一类：不是报错，而是行为与预期相反。

目标机上没有 `openssl x509 -checkip` 这个事实，本机（OpenSSL 3.5.5）测不出来——本机太新了。所以必须**在目标机上先探测能力，再选路径**，而不是猜。

## 决策

脚本启动时探测本机 OpenSSL 能力，之后按能力选复验路径，**两条路径都由 OpenSSL 自己做地址归一化**：

| 能力 | 探测方式 | 复验命令 |
| --- | --- | --- |
| OpenSSL ≥ 3.4 | `openssl x509 -help` 含 `-checkip` / `-checkhost` | `openssl x509 -noout -checkip/-checkhost <host>` |
| 更早的 3.x | `openssl verify -help` 含 `-verify_ip` / `-verify_hostname` | `openssl verify -partial_chain -no-CApath -CAfile <cert> -verify_ip/-verify_hostname <host> <cert>` |

探测帮助文本必须读 **stderr**（`openssl x509 -help` 的选项列表不走 stdout）。

**不能自己比较 SAN 文本**：SAN 里的 IPv6 会被 OpenSSL 归一化成 `2001:DB8:0:0:0:0:0:10`，手写字符串比较会误判；更危险的是前缀陷阱——`203.0.113.10` 是 `203.0.113.100` 的前缀，纯文本包含判断会放行一台不该放行的主机。

**还要区分「不匹配」与「工具坏了」**：`-checkip` 在不匹配和证书读不出来时**都返回 1**，只看退出码会把工具故障说成「证书缺 SAN」。所以按输出消息判定（`does NOT match` / `mismatch` 才是真不匹配），并把第三种状态单列为「本机无法复验」——此时**拒绝安装**并明确报错，绝不因为「复验工具坏了」就放行一张没验证过的证书。

## 备选方案与权衡

| 方案 | 优点 | 缺点 | 结论 |
| --- | --- | --- | --- |
| 只用 `x509 -checkip` | 写法最简单 | OpenSSL < 3.4 上永远失败，脚本在目标机不可用 | ❌ |
| 目标机升级 OpenSSL | 一劳永逸 | 动系统核心库，影响面远超一个维护脚本；且不解决别的旧版 OpenSSL 环境 | ❌ |
| 自己比较 SAN 文本 | 不依赖 OpenSSL 版本 | IPv6 归一化会误判；前缀陷阱会放行错误主机 | ❌ |
| **探测能力 + 两条路径 + 消息级判定** | 跨版本可用；判定交给 OpenSSL；工具故障不冒充不匹配 | 多约 30 行；两条路径都要测 | ✅ 采用 |

## 后果

- `harden-bt-panel.sh` 在 OpenSSL 3.0.x（目标机）与 ≥ 3.4（本机）上都能正确复验 SAN。
- 「无法复验」被当成独立失败原因报出，脚本在该情况下**不安装证书**，原证书与 SSL 状态保持不变。
- 本机测试必须**分别覆盖两条路径**：现代路径用真 OpenSSL，fallback 路径靠改写副本里的能力探测来强制走通，否则 fallback 分支等于没测过。
- 教训落在 ADR-0003 坑 6 旁边：**新写的脚本不能默认目标机的工具链和本机一样**。凡是用到「较新才有的 CLI 选项」的地方，都要探测 + 降级。
