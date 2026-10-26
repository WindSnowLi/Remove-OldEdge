# 变更记录

本项目的所有重要变更都会记录在此文件中。

## [1.0.0] - 2026-10-26

### 新增

- 首次发布：一键强制卸载旧版（稳定版）Microsoft Edge 并完成全部善后
- 自动探测 `Program Files`、`Program Files (x86)`、`%LOCALAPPDATA%` 三个安装根
- 注册表自动备份（`reg import` 可回滚）
- 官方 `setup.exe --uninstall --force-uninstall` 失败后自动 `takeown` + `icacls` 强制清理
- 清理 `EdgeUpdate\Clients`、`EdgeUpdate\ClientState`、卸载项、`Clients\StartMenuInternet\Microsoft Edge`、`RegisteredApplications\Microsoft Edge`、`App Paths`
- 失效快捷方式清理（按 `.lnk` 实际目标判断）
- `http` / `https` / `microsoft-edge:` / 网页 / PDF 关联重定向到替代浏览器（`HKCU\Software\Classes` 覆盖，不篡改 UserChoice）
- 逐项自检，未通过时退出码为 `1`
- 支持 `-DryRun`、`-TargetBrowser`、`-PurgeUserData`、`-LogDirectory`
- 幂等：干净状态下直接退出且不请求提权

### 修复（开发期发现）

- `List.Add(... -replace ... -replace ...)` 中的逗号被当作参数分隔符，导致注册表登记被静默跳过（改为分步赋值，并新增 `trap` 把未捕获错误计入失败）
- `EdgeUpdate\ClientState` 残留未纳入探测与自检
- `Clients\StartMenuInternet\Microsoft Edge`、`RegisteredApplications\Microsoft Edge` 幽灵登记未被清理
- 结束进程时原逻辑会误杀其它 Edge 通道（Canary/Beta/Dev）的进程，改为只结束稳定版路径下的进程
