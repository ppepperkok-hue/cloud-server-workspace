# 清单（inventory/）—— 唯一事实来源

本目录记录「东西在哪」的**唯一事实来源**。任何服务器、服务、端口、密钥位置的信息，只在这里维护，禁止在其他文档重复维护（防止信息孤岛）。

## 子文件

| 文件 | 内容 |
| --- | --- |
| `servers.md` | 服务器清单：IP/主机名、角色、环境、系统、登录方式引用 |
| `services.md` | 服务清单：服务名、部署位置、端口、依赖、负责人 |
| `credentials.md` | 密钥位置**引用**（绝不记明文）：密钥名/路径/ARN |

## 维护铁律

1. **唯一来源**：新增/变更服务器或服务，第一时间改这里，别只记在聊天或 CHANGELOG。
2. **不记明文密钥**：credentials.md 只记「去哪取密钥」，不写密钥本身。
3. **变更同步**：改完这里，去 `state/CHANGELOG.md` 追加一条记录。
4. **格式统一**：按各文件内表格格式填写，缺列就补说明。

## 本仓库是公开的 —— 提交前必须脱敏

`cloud-server-workspace` 是 **PUBLIC** 仓库，所以本目录（以及 `state/`、`docs/runbooks/`、`docs/decisions/`、`scripts/`）里**一律不写真值**，只写占位符：

| 占位符 | 含义 |
| --- | --- |
| `<TEST_HOST_IP>` / `<TEST_HOST_PRIVATE_IP>` | 测试机公网 / 内网地址 |
| `<OPERATOR_IP>` | 运维本人出口 IP（面板 / WebUI 白名单里那一个） |
| `<INSTANCE_ID>` / `<TEST_HOST_HOSTNAME>` | 云实例 ID / 主机名 |
| `<PANEL_ENTRY>` | 宝塔面板安全入口路径 |
| `<TEST_USER>` | 密钥对名 / 面板账号 |
| `<SSH_KEY_FINGERPRINT>` | 主机 authorized_keys 指纹 |
| `<QQ_ACCOUNT_A>` / `<QQ_ACCOUNT_B>` / `<ADMIN_QQ>` | 机器人 / 管理员 QQ 号 |
| `<BOT_NICK_A>` / `<BOT_NICK_B>` | 机器人昵称 |
| `<ST_USERNAME>` | SillyTavern 用户名 |
| `<NAPCAT1_WEBUI_TOKEN>` / `<NAPCAT2_WEBUI_TOKEN>` | NapCat WebUI 令牌 |

**真值放在 `secrets/redaction-map.json`（已 gitignore）**，`secrets/inventory-values` 之外的任何人都不该拿到它。提交前跑一次：

```powershell
python scripts\utils\redact-workspace.py --check   # 只看会改什么
python scripts\utils\redact-workspace.py --apply   # 应用并自检残留
```

脚本会自动跳过 `secrets/`、`logs/`、`tmp/`，并在 `--apply` 后校验「已登记的敏感字面量一个都不剩」。**新增服务器时先把真值补进 `redaction-map.json`，再写文档。**
