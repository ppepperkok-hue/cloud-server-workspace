# 架构决策记录（ADR）

本目录记录「为什么这么做」——技术选型、取舍、踩坑结论。任何影响后续工作的决策，必须落成一条 ADR，不在聊天或代码注释里悄悄决定。

## 规范

- 文件名：`ADR-{NNNN}-{slug}.md`，如 `ADR-0001-use-ansible-for-cm.md`。
- 编号递增，不可复用。
- 模板见 [`ADR-0000-template.md`](ADR-0000-template.md)。
- 决策被推翻时：**新建**一条 ADR 引用旧 ADR 并说明推翻原因，不修改历史。

## 索引

| 编号 | 标题 | 状态 | 日期 |
| --- | --- | --- | --- |
| [ADR-0001](ADR-0001-windows-ssh-argv-limit.md) | Windows 侧向远端投递脚本的方式（gzip+base64 走 argv） | 已接受 | 2026-09-28 |
| [ADR-0002](ADR-0002-bt-panel-ua-gate.md) | 探测宝塔面板必须带浏览器 User-Agent | 已接受 | 2026-09-28 |
| [ADR-0003](ADR-0003-opencloudos-deploy-pitfalls.md) | 往 OpenCloudOS 上部署时踩到的六个坑（moby 互斥 / daemon.json log-driver / BOM 与本地代理 / mv 嵌套 / YAML 缩进静默失效 / CLI 静默不生效） | 已接受 | 2026-09-28 |
| [ADR-0004](ADR-0004-tencent-domain-block.md) | 这台腾讯云机器不能用「域名」访问 80 / 443 端口（80 未备案被 webblock，443 域名 SNI 直接 RST） | 已接受 | 2026-09-28 |

## 何时需要写 ADR

- 引入新工具/技术栈（如选 Ansible 还是 Terraform）。
- 改变架构或目录约定。
- 踩坑后总结出「以后都这么做」的结论。
- 两个方案取舍，会影响后续 agent 的判断。
