# service-restart：重启单个服务（示例 Runbook）

> 这是「填好的示范」，展示 runbook 模板的实际填法。正式条目照此标准写。

- **名称**：重启 nginx（以 nginx 为例，其他单服务可套用）
- **适用环境**：prod / staging / dev
- **风险级别**：中
- **前置条件**：有该主机的 operator 权限；已确认无正在进行的部署；重启窗口已确认
- **最近更新**：2026-02-01

## 步骤

1. 先看当前状态与配置语法（dry-run 性质）：
   ```bash
   systemctl status nginx
   nginx -t          # 校验配置，失败则停止，不要继续
   ```
2. 记录重启前状态（写 CHANGELOG 用）：
   ```bash
   systemctl is-active nginx
   ```
3. 执行重启：
   ```bash
   sudo systemctl restart nginx
   ```

## 验证

```bash
systemctl is-active nginx        # 预期：active
curl -sI https://TARGET_HOST -o /dev/null -w '%{http_code}\n'   # 预期：200
```
- 日志无新增 error：`journalctl -u nginx -n 20 --no-pager`

## 回滚

- 若重启后异常：回退到上一个配置并再次重启：
  ```bash
  sudo cp /etc/nginx/nginx.conf.prev /etc/nginx/nginx.conf
  sudo systemctl restart nginx
  ```
- 若仍异常，查看 `docs/inventory/services.md` 找负责人，按 `docs/operations/02-safety.md` 触发止损/复盘。

## 注意事项

- 重启前务必 `nginx -t` 校验，避免配置错误导致服务起不来。
- 生产环境选低峰窗口；重启后立即验证，别只看到进程在就收工。
- 完成后按 `AGENTS.md` 三件套：验证 → 追加 `state/CHANGELOG.md` → 更新 `state/TASKS.md`。
