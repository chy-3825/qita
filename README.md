# Clash Verge Linux Guard

这是 Clash Verge Rev 的 Linux 生命周期守卫，不是 Clash、Mihomo 或 Clash Verge Rev 的分叉源码。它解决 GNOME 系统代理、Mihomo systemd 服务、多个 UI 实例和 `clash://` 协议入口之间的所有权与退出清理问题。

## 功能

- 启动 UI 前启动 `clash-verge-service.service`。
- 使用 PID 与进程启动时间租约识别多个受保护 UI，避免 PID 复用误判。
- 最后一个 UI 正常退出后关闭 GNOME 系统代理并停止 Mihomo 服务。
- 首次启动前清除上次会话可能残留的系统代理。
- Clash Verge 覆盖 deep-link desktop handler 后自动恢复受保护入口。
- 转发 `HUP`、`INT`、`TERM` 给子进程，避免 UI 成为孤儿进程。
- systemd 只对异常失败重启，用户主动停止不会被拉起。

## 要求

- Linux、Bash、systemd；系统代理清理针对 GNOME `gsettings`。
- Clash Verge Rev 默认位于 `/usr/bin/clash-verge`。
- Mihomo 服务名默认为 `clash-verge-service.service`。
- 用户必须具备无交互启动/停止该服务的最小 sudo 权限。

## 安装

先审阅脚本，再执行：

```bash
./tests/run.sh
./install.sh
```

安装不会退出正在运行的 Clash，也不会导入或读取订阅。完成后从桌面入口或 `clash://` 链接启动即可。可用环境变量覆盖二进制、服务、运行目录和测试命令，详见 `bin/clash-verge-guarded`。

## 安全边界

仓库不包含 Clash 配置、订阅 URL、节点、token、日志或数据库。守卫默认只管理自己启动并持有租约的 UI；不过最后一个受保护 UI 退出时会明确关闭 GNOME 系统代理并停止 Mihomo 服务，这是本项目的核心策略。

工作状态见 [工作清单](工作清单.md)，验收步骤见 [验收清单](验收清单.md)。

## 许可证

守卫代码使用 MIT License。Clash Verge Rev、Mihomo 及其依赖仍适用各自许可证。

