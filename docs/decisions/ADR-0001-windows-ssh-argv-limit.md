# ADR-0001：Windows 侧向远端投递脚本的方式（gzip+base64 走 argv）

- **状态**：已接受
- **日期**：2026-09-28
- **决策者**：agent

## 背景

在 Windows 上把工作区脚本送进远端 `bash -s` 执行，遇到两个实测坑（客户端：Windows PowerShell 5.1.26100 + OpenSSH for Windows `ssh.exe` / OpenSSH_10.2p1；服务端：OpenCloudOS 9.6 / bash）：

1. **纯 base64 当参数**：`server-inventory.sh` 源文件 6993 字节 → base64 9188 字符。实测 argv 长度超过约 8000 字符后，`ssh.exe` 会静默丢弃尾部，远端只收到 `echo <半截 base64>`，于是**把 base64 原样打印出来**，脚本根本没跑，且退出码仍为 0（假绿灯）。
   - 阈值实测：`n=1000/3000/5000/7000/8000` 全部正常；`n=9000/10000` 管道段丢失。
2. **走 ssh stdin**（`$text | ssh host 'bash -s'`）：PowerShell 5.1 把 LF 改写成 CRLF，远端 bash 看到多余 `\r`（`bash: line 2: $'\r': command not found`）。脚本虽勉强跑完，但退出码变成 **127**，并混入噪声报错——同样是「看起来成功、实际状态错」。

## 决策

工作区脚本统一用 **gzip + base64 作为单个 argv 参数**投递：

```
echo <base64(gzip(script))> | base64 -d | gunzip | bash -s
```

封装在 [`scripts/utils/ssh-bt-he1k.ps1`](../../scripts/utils/ssh-bt-he1k.ps1)，并在 payload 超过 7000 字符时**直接抛错中止**，不允许静默降级。

## 备选方案与权衡

| 方案 | 优点 | 缺点 | 结论 |
| --- | --- | --- | --- |
| 纯 base64 argv | 实现最简，无额外依赖 | 9 KB 级脚本直接超限，且**静默失败、退出码 0** | ❌ |
| ssh stdin 管道 | 不受 argv 长度限制 | PowerShell 改写换行 → CRLF 污染 + 退出码 127 | ❌ |
| **gzip + base64 argv（选定）** | 体积降到约 1/2.7（本脚本 9188 → 3368 字符），字节精确，无换行污染 | 依赖远端 `gunzip`；脚本过大仍需换方案 | ✅ |
| scp 上传后再执行 | 无长度限制，任意大小 | 需往远端写文件，破坏只读性质，还要清理 | 备用 ✅ |

## 后果

- 单个脚本 gzip+base64 后必须 < 7000 字符（约对应 12–15 KB 源文件）。超了就拆分脚本，或改用 scp 上传 + 清理。
- 远端需要 `base64`（coreutils）与 `gunzip`（gzip 包）；主流发行版默认自带，bt-he1k 上为 `/usr/bin/gunzip`，已验证。
- 脚本正文保持**纯 ASCII**（`scripts/healthcheck/server-inventory.sh` 已据此清理 `—` 等字符）。
- 封装脚本最后必须**把远端退出码原样带出**（`exit $LASTEXITCODE`），避免上表第 1 条的假绿灯重演。
- 在 macOS / Linux 客户端上可直接 `ssh host 'bash -s' < script.sh`，不受本 ADR 约束；本 ADR 只约束 Windows 侧的封装脚本。
