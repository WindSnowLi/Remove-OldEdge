# Remove-OldEdge

在 Windows 10 / 11 上**强制卸载旧版（稳定版）Microsoft Edge** 的 PowerShell 脚本，一条命令完成卸载与全部善后，**不需要重启电脑**。

> ⚠️ 本脚本会强制删除系统自带的 Edge 稳定版。卸载后会**自动下载并安装最新的 Edge Canary** 作为替代浏览器（可用 `-SkipCanaryInstall` 关闭，此时请确保已有可用的替代浏览器），并阅读文末的[风险与注意事项](#风险与注意事项)。

---

## 特性

- **一键完成**：卸载 + 残留文件 + 注册表 + 快捷方式 + 自动安装 Canary + 失效关联修复 + 自检
- **自动补浏览器**：卸载后从微软官方下载最新 Edge Canary 安装包并静默安装（`/silent /install`），只有通过 Authenticode 签名校验（`Microsoft Corporation`）的安装包才会被执行
- **不需要重启**
- **保留 Edge WebView2 运行时**（大量桌面应用依赖它渲染网页）
- **保留个人浏览数据**（书签 / 密码 / 历史），需要时可加 `-PurgeUserData` 一并删除
- **只关闭稳定版 Edge 的进程**，不影响 Canary / Beta / Dev 正在使用的窗口
- **自动修复失效关联**：`http` / `https` / `microsoft-edge:` / 网页文件 / PDF 会重定向到 Canary 或其它可用的替代浏览器
- **阻止自动重装**：删除稳定版的 EdgeUpdate 客户端登记，同时保留其它通道的自动更新
- **可回滚**：执行前自动备份相关注册表
- **幂等**：重复运行安全；干净状态下直接退出且不会再请求管理员权限（Canary 已安装时也不会重复下载）
- **`-DryRun` 演练**：只打印将要执行的动作，不改动任何内容

## 环境要求

| 项目 | 要求 |
| --- | --- |
| 操作系统 | Windows 10 / Windows 11（已在 Windows 11 Build 26200 上实测） |
| PowerShell | Windows PowerShell 5.1+ 或 PowerShell 7+ |
| 权限 | 管理员（脚本会自动请求 UAC，无需手动右键） |
| 网络 | 需要：从微软官方域名 `c2rsetup.edog.officeapps.live.com` 下载最新 Edge Canary（速度约 150 MB 安装内容）；用 `-SkipCanaryInstall` 关闭时无需网络 |

## 快速开始

```powershell
# 建议先演练，确认将要执行的动作
powershell -NoProfile -ExecutionPolicy Bypass -File .\Remove-OldEdge.ps1 -DryRun

# 正式执行（会请求管理员权限）
powershell -NoProfile -ExecutionPolicy Bypass -File .\Remove-OldEdge.ps1
```

也可以在资源管理器中右键脚本 → **使用 PowerShell 运行**。

典型输出（干净状态复跑，此时 Canary 已装好，不会重复下载）：

```
[INFO] Remove-OldEdge v1.1.0
[INFO] 管理员：True  DryRun：False  自动安装 Canary：True
[STEP] 探测结果：安装目录 0 个、可执行版本 0 个、EdgeUpdate 客户端 0 个、卸载项 0 个、幽灵登记 0 个
[OK  ] 系统已经是干净状态：未发现稳定版 Edge 的文件、注册表登记或失效关联。

无需任何操作。
```

首次在干净系统上运行（需要补装 Canary）时会出现：

```
[STEP] 下载最新 Edge Canary 安装包（第 1/3 次）：https://c2rsetup.edog.officeapps.live.com/c2r/downloadEdge.aspx?...
[OK  ] 下载完成：C:\ProgramData\EdgeStableRemoval\MicrosoftEdgeSetupCanary.exe（1.8 MB）
[OK  ] 安装包签名校验通过：CN=Microsoft Corporation, O=Microsoft Corporation, ...
[STEP] 静默安装 Edge Canary："C:\ProgramData\EdgeStableRemoval\MicrosoftEdgeSetupCanary.exe" /silent /install
[OK  ] Edge Canary 安装完成（158.0.4366.0）：C:\Users\<你>\AppData\Local\Microsoft\Edge SxS\Application\msedge.exe
```

## 参数

| 参数 | 说明 | 默认值 |
| --- | --- | --- |
| `-TargetBrowser <路径>` | 失效关联重定向的目标浏览器 exe | 自动探测 Canary → Beta → Dev → Chrome；都没有时使用本脚本刚安装的 Canary |
| `-SkipCanaryInstall` | 跳过「卸载后自动下载并静默安装最新 Edge Canary」 | 关闭（即默认会安装） |
| `-DryRun` | 只演练，不修改任何内容（无需管理员） | 关闭 |
| `-PurgeUserData` | 额外删除 `%LOCALAPPDATA%\Microsoft\Edge\User Data` | 关闭（保留数据） |
| `-LogDirectory <路径>` | 日志、注册表备份与安装包下载目录 | `C:\ProgramData\EdgeStableRemoval` |

示例：

```powershell
# 指定重定向目标，并清理个人数据
powershell -NoProfile -ExecutionPolicy Bypass -File .\Remove-OldEdge.ps1 `
  -TargetBrowser "C:\Program Files (x86)\Microsoft\Edge SxS\Application\msedge.exe" `
  -PurgeUserData

# 不自动安装 Canary（需自行保证已有可用浏览器）
powershell -NoProfile -ExecutionPolicy Bypass -File .\Remove-OldEdge.ps1 -SkipCanaryInstall
```

## 执行流程

| # | 步骤 | 说明 |
| --- | --- | --- |
| 1 | 探测 | 扫描 `Program Files`、`Program Files (x86)`、`%LOCALAPPDATA%` 三个安装根，以及 EdgeUpdate 客户端、卸载项、幽灵登记、失效关联 |
| 2 | 备份 | 导出相关注册表到 `<LogDirectory>\backup-<时间戳>`，可用 `reg import` 回滚 |
| 3 | 关闭进程 | 仅结束可执行文件位于稳定版目录下的 `msedge.exe` |
| 4 | 官方卸载 | 调用各安装根中**最新版本**的 `Installer\setup.exe --uninstall --system-level --force-uninstall` |
| 5 | 强制清理 | 若目录仍在，`takeown` + `icacls` 取得所有权后递归删除（最多重试 6 次） |
| 6 | 注册表清理 | `EdgeUpdate\Clients`、`EdgeUpdate\ClientState`、`Uninstall\Microsoft Edge`、`Clients\StartMenuInternet\Microsoft Edge`、`RegisteredApplications\Microsoft Edge`、`App Paths\msedge.exe`（HKLM 32/64 位与 HKCU） |
| 7 | 安装 Canary | 未安装 Canary 时，从微软官方下载最新引导安装包，`Get-AuthenticodeSignature` 校验通过后以 `/silent /install` 静默安装；已安装则跳过 |
| 8 | 快捷方式 | 按 `.lnk` 实际目标判断，清理开始菜单、公共桌面、当前用户桌面、任务栏固定项中的失效项 |
| 9 | 关联修复 | 用 `reg query HKCR /s /d` 找出仍指向已删路径的命令值，在 `HKCU\Software\Classes` 中覆盖为 Canary（或 `-TargetBrowser` 指定的浏览器），不篡改 UserChoice 哈希，兼容大小写与带版本号路径 |
| 10 | 自检 | 重新探测并逐项核对，任何一项未通过则以退出码 `1` 结束并提示重跑 |

### 自检项

稳定版目录已清除、EdgeUpdate 稳定版客户端已移除、卸载项已移除、`ClientState` 已清除、失效关联剩余 0 项、WebView2 运行时仍在、Edge Canary 已安装且可执行文件存在、替代浏览器可执行文件存在、注册表备份已生成、进程与快捷方式处理结果。

## 工作原理要点

- **Windows 11 会拒绝卸载系统 Edge**：`setup.exe` 通常返回退出码 `93`，所以脚本在调用官方卸载后必然会再做一次强制文件清理。这是预期行为，不是错误。
- **阻止自动重装**：EdgeUpdate 只给自己"认识"的产品做更新/修复，删掉稳定版对应的客户端登记（GUID `56EB18F8-B008-4CBD-B6D2-8C97FE7E9062`）后就不会被自动装回来；更新器本体与其它通道的登记保持不动。
- **关联重定向不碰 UserChoice**：Windows 对 `UserChoice` 有哈希校验，脚本改为在 `HKCU\Software\Classes` 覆盖 `http`、`https`、`microsoft-edge`、`MSEdgeHTM`、`MSEdgeMHT`、`MSEdgePDF` 等 ProgId 的 open/runas 命令，效果等同且完全可逆。
- **WebView2 是独立产品**：位于 `C:\Program Files (x86)\Microsoft\EdgeWebView`，脚本不会触碰。
- **Canary 安装包来源与校验**：只从微软官方地址 `c2rsetup.edog.officeapps.live.com` 下载引导安装包（`MicrosoftEdgeSetupCanary.exe`，始终拉取最新 Canary），并用 `Get-AuthenticodeSignature` 确认签名状态为 `Valid` 且签发者包含 `O=Microsoft Corporation` 后才以 `/silent /install` 执行；下载结束后会删除安装包。安装成功后 EdgeUpdate 会自动维持 Canary 通道更新。

## 回滚

```powershell
# 1) 导入备份（内容为被删除前的注册表状态）
reg import "C:\ProgramData\EdgeStableRemoval\backup-<时间戳>\01-....reg"
# 2) 重新安装 Edge 稳定版安装包即可恢复
```

个人浏览数据默认保留在 `%LOCALAPPDATA%\Microsoft\Edge\User Data`，可在替代浏览器的"导入浏览器数据"中导入书签等。如不再需要自动安装的 Canary，可用其自带安装包执行 `--uninstall --system-level --force-uninstall`，或从"设置 → 应用"中卸载。

## 已验证

在 Windows 11（Build 26200）上，以 Edge 稳定版 `156.0.4314.42` 为对象做了真实回归：

- 卸载后目录、`EdgeUpdate` 客户端、卸载项、`ClientState`、幽灵登记、失效关联全部为空，脚本退出码 `0`
- 干净状态下复跑：输出"系统已经是干净状态"，退出码 `0`，且不再请求 UAC（幂等）
- 无浏览器运行时双击 `.html`，实际启动的是 `%LOCALAPPDATA%\Microsoft\Edge SxS\Application\msedge.exe`（关联修复生效）
- v1.1.0 起，干净状态下运行会从微软官方下载最新 Edge Canary 并静默安装，随后关联修复直接指向新装的 Canary；已安装时不会重复下载

## 风险与注意事项

1. **这是对系统组件的强制修改**。部分依赖 Edge 稳定版的系统功能（如小组件、任务栏搜索的网页结果、部分内置帮助链接）可能受到影响；PDF/网页文件关联会指向替代浏览器。
2. **会额外安装一个浏览器**：默认会自动安装最新的 Edge Canary（约 150 MB+ 下载量，占用额外磁盘空间）。不需要时用 `-SkipCanaryInstall` 关闭。
3. **Windows 功能更新（大版本升级）可能把稳定版 Edge 装回来**，届时重新运行本脚本即可。
4. **默认浏览器仍需要手动设置**：打开替代浏览器 → 设置 → 默认浏览器 → 设为默认。
5. 企业环境中如存在组策略（`HKLM\SOFTWARE\Policies\Microsoft\Edge`）或强制安装策略，脚本可能无法彻底移除，请先与 IT 管理员确认。
6. 建议先在测试机或虚拟机中验证；如需关闭自动安装，请确保至少有另一个可用浏览器。

## 目录结构

```
Remove-OldEdge/
├── Remove-OldEdge.ps1   # 主脚本
├── README.md            # 本文档
├── CHANGELOG.md         # 变更记录
├── LICENSE              # MIT 许可证
├── .gitattributes       # 换行符规范
└── .gitignore
```

## 许可

本项目基于 [MIT License](LICENSE) 发布，Copyright (c) 2026 WindSnowLi。

使用本脚本即表示你已理解：脚本会对系统自带的 Edge 稳定版做强制修改，风险由使用者自行承担。
