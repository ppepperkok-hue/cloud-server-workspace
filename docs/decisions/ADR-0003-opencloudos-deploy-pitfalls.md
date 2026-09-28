# ADR-0003：往 OpenCloudOS 上部署时踩到的五个坑

- **状态**：已接受
- **日期**：2026-09-28
- **决策者**：agent

## 背景

在 bt-he1k（腾讯云轻量 / OpenCloudOS 9.6 / 香港）上装 Docker 并迁移一个 Windows 上跑着的应用（AstrBot 4.28.1）时，连续踩到四个只看现象完全猜不到原因的坑。逐个记下来，避免下次重走。

## 坑与结论

### 1. OpenCloudOS 的 `docker-ce` 与 `moby` 互斥

`dnf install docker-ce docker-compose` 必然失败：

```
package docker-compose requires docker, but none of the providers can be installed
  - docker-ce conflicts with docker provided by moby-29.x
```

AppStream 里的 `moby` 提供 `docker`，EPOL 的 `docker-ce` 与它互斥，而 `docker-compose` 又依赖 `docker` —— 三方死锁，`--allowerasing` 也解不开。

**结论：OpenCloudOS 9 上装 `moby + docker-compose`（发行版自带），不要碰 `docker-ce`。**

### 2. `daemon.json` 里写 `log-driver` 会让 dockerd 起不来

装好 moby 后 `systemctl start docker` 直接失败，dockerd 真正的报错是：

```
unable to configure the Docker daemon with file /etc/docker/daemon.json:
the following directives are specified both as a flag and in the configuration file:
log-driver: (from flag: journald, from file: json-file)
```

OpenCloudOS 的 `docker.service` 已经带了 `--log-driver=journald`，`daemon.json` 再写一次就是冲突而非覆盖。

**结论：`/etc/docker/daemon.json` 只放 `registry-mirrors`；日志走 journald，别再写 `log-driver` / `log-opts`。**

### 3. Windows → Linux 迁移，配置里带着「本机才有」的东西

迁移过来的 `cmd_config.json` 里带着 `"http_proxy": "socks5://127.0.0.1:PORT"`（本机的 Clash）。容器里没有这个代理，于是**所有插件依赖安装、所有外呼请求全部失败**，报错长得像网络问题：

```
NewConnectionError("SOCKSHTTPSConnection(host='mirrors.aliyun.com', port=443):
Failed to establish a new connection: [Errno 111] Connection refused")
```

同批还有一个：Windows 写出的 JSON 带 **UTF-8 BOM**，严格解析器直接 `Unexpected UTF-8 BOM`。

**结论：跨平台迁移后，第一件事是审一遍配置里的「本机路径 / 本机代理 / 本机端口」，并批量去掉 UTF-8 BOM。** 本次 39 个文件有 BOM。

### 4. `mv A B` 在 B 已存在时会嵌套

解包脚本里写了 `mv $SCRATCH/data /opt/astrbot/data`，而 `/opt/astrbot/data` 早已 `mkdir` 出来了 —— `mv` 把源目录**塞进**目标里，变成 `/opt/astrbot/data/data`。应用照常起来，只是数据目录是空的，于是**静默地跑成全新安装**（随机初始密码、零插件），日志毫无异常。

**结论：脚本里往「可能已存在」的目录放东西，一律用 `cp -a src/* dst/`，并在启动前做存在性断言（本次加了 `cmd_config.json` 必须存在）。**

### 5. YAML 缩进深一层 = 配置静默失效

给 SillyTavern 的白名单加条目时，用正则插了一行 `    - 172.16.0.0/12`（4 空格），而原有条目是 2 空格。YAML 解析**没有报错**——那行被当成上一条的子列表元素，白名单里实际没有这个网段，于是整个站点对代理过来的请求一路 403。排查了三轮才看出是缩进。

**结论：用代码改 YAML 时，先取出同级条目的真实缩进再复用，改完把原始文本（带可见缩进）打出来核对，别只看「值对不对」。** 同理适用于任何「解析器容忍、语义已变」的结构化配置。

## 后果

- 上述四条已固化进 [`install-docker.sh`](../../scripts/deploy/install-docker.sh)、[`deploy-astrbot.sh`](../../scripts/deploy/deploy-astrbot.sh) 与 [`migrate-astrbot.md`](../runbooks/migrate-astrbot.md)，不靠人记。
- 同类「静默成功」的失败（坑 4）比报错的失败危险得多：以后凡是「应用起来了但状态不对」，先怀疑数据目录是不是空的/嵌了一层。
- 迁移类操作统一加一步「迁移后审配置」：路径、代理、端口、时区、BOM。
