#Requires -Version 5.1
<#
.SYNOPSIS
    强制卸载旧版（稳定版）Microsoft Edge，并自动完成全部善后处理。

.DESCRIPTION
    一条命令完成下面全部动作（不需要重启电脑）：
      1. 自动探测稳定版 Edge（Program Files / Program Files (x86) / 当前用户目录）
      2. 备份相关注册表到日志目录，便于回滚
      3. 关闭 msedge 进程 -> 调用官方卸载 -> 强制清除残留文件
      4. 清理注册表：EdgeUpdate 客户端、卸载项、StartMenuInternet、RegisteredApplications、App Paths
      5. 清理失效快捷方式（开始菜单 / 桌面 / 任务栏固定项）
      6. 把仍指向已删路径的 http/https/microsoft-edge:/网页/PDF 关联重定向到可用的预览版浏览器
      7. 删除稳定版的 EdgeUpdate 客户端登记，阻止 Edge 自动重装（更新器仍可服务其他通道）
      8. 自检并输出结果；全程不重启、不动 WebView2 运行时、不删个人浏览器数据

.PARAMETER TargetBrowser
    关联重定向的目标浏览器 exe 路径。留空时自动探测 Canary / Beta / Dev / Chrome。

.PARAMETER DryRun
    只演练：显示将要执行的动作，不修改任何内容（无需管理员权限）。

.PARAMETER PurgeUserData
    额外删除 %LOCALAPPDATA%\Microsoft\Edge\User Data（书签/密码/历史）。默认保留。

.PARAMETER LogDirectory
    备份与日志目录。默认 C:\ProgramData\EdgeStableRemoval（非管理员时为 %LOCALAPPDATA%\EdgeStableRemoval）。

.PARAMETER LogFile
    内部参数：日志文件完整路径。

.PARAMETER SkipElevate
    内部参数：表示已经在提权进程中运行，避免重复提权。

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\Remove-OldEdge.ps1

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\Remove-OldEdge.ps1 -DryRun

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\Remove-OldEdge.ps1 -TargetBrowser 'C:\Program Files (x86)\Microsoft\Edge SxS\Application\msedge.exe'

.NOTES
    回滚方式：reg import "<备份目录>\*.reg"，然后重新安装 Edge 稳定版安装包。
#>
[CmdletBinding()]
param(
    [string]$TargetBrowser,
    [switch]$DryRun,
    [switch]$PurgeUserData,
    [string]$LogDirectory,
    [string]$LogFile,
    [switch]$SkipElevate
)

$ErrorActionPreference = 'Continue'
$ProgressPreference    = 'SilentlyContinue'

# 任何未被捕获的语句错误都要记入日志并计入失败，避免“静默跳过”
trap {
    $msg = "未捕获错误：[{0}] {1}" -f $_.InvocationInfo.MyCommand, $_.Exception.Message
    Write-Host $msg -ForegroundColor Red
    $script:Issues.Add($msg)
    if ($script:CanWriteLog) { try { Add-Content -LiteralPath $script:LogFile -Value $msg -Encoding UTF8 } catch { } }
    continue
}

$script:StableGuid  = '56EB18F8-B008-4CBD-B6D2-8C97FE7E9062'
$script:EdgeName    = 'Microsoft Edge'
$script:ScriptVersion = '1.0.0'
$script:IsAdmin     = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$script:Issues      = New-Object System.Collections.Generic.List[string]
$script:Results     = New-Object System.Collections.Generic.List[object]
$script:LogFile     = $LogFile
$script:CanWriteLog = $false

# 匹配任何指向稳定版 Edge 可执行文件的路径（含版本号子目录），用于发现失效关联
$script:LegacyEdgePattern = '(?i)[A-Z]:\\[^"\r\n]*?\\Microsoft\\Edge\\Application\\(?:[0-9]+(?:\.[0-9]+)*\\)?msedge\.exe'

$installRoots = @(
    'C:\Program Files (x86)\Microsoft\Edge',
    'C:\Program Files\Microsoft\Edge',
    (Join-Path $env:LOCALAPPDATA 'Microsoft\Edge')
)

# ---------------------------------------------------------------- helpers ----

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('INFO', 'STEP', 'OK', 'WARN', 'ERR')][string]$Level = 'INFO'
    )
    $line  = '[{0}] [{1}] {2}' -f (Get-Date -Format 'HH:mm:ss'), $Level.PadRight(4), $Message
    $color = switch ($Level) {
        'STEP' { 'Cyan' }
        'OK'   { 'Green' }
        'WARN' { 'Yellow' }
        'ERR'  { 'Red' }
        default { 'Gray' }
    }
    Write-Host $line -ForegroundColor $color
    if ($script:CanWriteLog) { try { Add-Content -LiteralPath $script:LogFile -Value $line -Encoding UTF8 } catch { } }
}

function Add-Result {
    param([string]$Item, [bool]$Ok, [string]$Detail = '')
    $script:Results.Add([pscustomobject]@{ Item = $Item; Ok = $Ok; Detail = $Detail })
    if (-not $Ok) { $script:Issues.Add("$Item $Detail".Trim()) }
}

function Resolve-LogPaths {
    if (-not $LogDirectory) {
        $LogDirectory = if ($script:IsAdmin -or -not $DryRun) { Join-Path $env:ProgramData 'EdgeStableRemoval' }
                        else { Join-Path $env:LOCALAPPDATA 'EdgeStableRemoval' }
    }
    if (-not $LogFile) {
        $stamp   = Get-Date -Format 'yyyyMMdd-HHmmss'
        $LogFile = Join-Path $LogDirectory ("removal-{0}.log" -f $stamp)
    }
    $script:LogDirectory = $LogDirectory
    $script:LogFile      = $LogFile

    try {
        New-Item -ItemType Directory -Force -Path $LogDirectory -ErrorAction Stop | Out-Null
        if (-not (Test-Path -LiteralPath $LogFile)) { New-Item -ItemType File -Force -Path $LogFile -ErrorAction Stop | Out-Null }
        $script:CanWriteLog = $true
    } catch {
        $script:CanWriteLog = $false
        Write-Host ("暂时无法写入日志目录 {0}（提权后会自动创建），当前仅输出到控制台。" -f $LogDirectory) -ForegroundColor Yellow
    }
}

function Test-IsElevated {
    return $script:IsAdmin
}

function Invoke-SelfElevate {
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $PSCommandPath))
    if ($PSBoundParameters.ContainsKey('TargetBrowser') -and $TargetBrowser) { $argList += @('-TargetBrowser', ('"{0}"' -f $TargetBrowser)) }
    if ($PurgeUserData) { $argList += '-PurgeUserData' }
    $argList += @('-LogDirectory', ('"{0}"' -f $script:LogDirectory))
    $argList += @('-LogFile', ('"{0}"' -f $script:LogFile))
    $argList += '-SkipElevate'

    Write-Host '正在请求管理员权限，请在 UAC 弹窗中点击“是”…' -ForegroundColor Yellow
    try {
        $p = Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -Verb RunAs -PassThru -Wait
        return $p.ExitCode
    } catch {
        Write-Host "提权失败：$($_.Exception.Message)" -ForegroundColor Red
        return 2
    }
}

# -------------------------------------------------------------- detection ----

function Get-EdgeStableState {
    $state = [pscustomobject]@{
        InstallRoots  = New-Object System.Collections.Generic.List[string]
        Versions      = New-Object System.Collections.Generic.List[object]
        SetupExes     = New-Object System.Collections.Generic.List[object]
        ClientKeys    = New-Object System.Collections.Generic.List[string]
        UninstallKeys = New-Object System.Collections.Generic.List[string]
        GhostKeys     = New-Object System.Collections.Generic.List[string]
        StaleCommands = New-Object System.Collections.Generic.List[object]
    }

    foreach ($root in $installRoots) {
        $app = Join-Path $root 'Application'
        if (Test-Path -LiteralPath $app) {
            $state.InstallRoots.Add($root)
            $dirs = @(Get-ChildItem -LiteralPath $app -Directory -ErrorAction SilentlyContinue |
                    Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'msedge.exe') })
            foreach ($d in $dirs) { $state.Versions.Add($d) }
            # 每个安装根只调用最新版本的 setup.exe，其余版本随目录一起删除
            $newest = $dirs | Sort-Object { try { [version]($_.Name -replace '[^0-9.].*$', '') } catch { [version]'0.0' } } | Select-Object -Last 1
            if ($newest) {
                $setup = Join-Path $newest.FullName 'Installer\setup.exe'
                if (Test-Path -LiteralPath $setup) {
                    $isPerUser = $root -like (Join-Path $env:LOCALAPPDATA '*')
                    $state.SetupExes.Add([pscustomobject]@{ Exe = $setup; Version = $newest.Name; PerUser = $isPerUser; Root = $root })
                }
            }
        }
    }

    $clientRoots = @(
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients',
        'HKLM:\SOFTWARE\Microsoft\EdgeUpdate\Clients',
        'HKCU:\SOFTWARE\Microsoft\EdgeUpdate\Clients'
    )
    foreach ($cr in $clientRoots) {
        Get-ChildItem -LiteralPath $cr -ErrorAction SilentlyContinue | ForEach-Object {
            $props = Get-ItemProperty -LiteralPath $_.PSPath -ErrorAction SilentlyContinue
            if ($props.name -eq $script:EdgeName -or $_.PSChildName -eq "{$($script:StableGuid)}") {
                $state.ClientKeys.Add($_.PSPath)
            }
        }
    }

    $uninstallRoots = @(
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
    )
    foreach ($ur in $uninstallRoots) {
        Get-ChildItem -LiteralPath $ur -ErrorAction SilentlyContinue |
            Where-Object { $_.PSChildName -in @('Microsoft Edge', 'MicrosoftEdge', "{$($script:StableGuid)}") } |
            ForEach-Object { $state.UninstallKeys.Add($_.PSPath) }
    }

    $ghostKeys = @(
        'HKLM:\SOFTWARE\WOW6432Node\Clients\StartMenuInternet\Microsoft Edge',
        'HKLM:\SOFTWARE\Clients\StartMenuInternet\Microsoft Edge',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Edge',
        'HKLM:\SOFTWARE\Microsoft\Edge'
    )
    foreach ($g in $ghostKeys) { if (Test-Path -LiteralPath $g) { $state.GhostKeys.Add($g) } }
    foreach ($ra in @('HKLM:\SOFTWARE\RegisteredApplications', 'HKLM:\SOFTWARE\WOW6432Node\RegisteredApplications')) {
        if (Test-Path -LiteralPath $ra) {
            $props = Get-ItemProperty -LiteralPath $ra -ErrorAction SilentlyContinue
            if ($null -ne $props.'Microsoft Edge') { $state.GhostKeys.Add("$ra|Microsoft Edge") }
        }
    }
    foreach ($ap in @(
            'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\msedge.exe',
            'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\App Paths\msedge.exe')) {
        if (Test-Path -LiteralPath $ap) { $state.GhostKeys.Add($ap) }
    }
    foreach ($cs in @(
            "HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\ClientState\{$($script:StableGuid)}",
            "HKLM:\SOFTWARE\Microsoft\EdgeUpdate\ClientState\{$($script:StableGuid)}",
            "HKCU:\SOFTWARE\Microsoft\EdgeUpdate\ClientState\{$($script:StableGuid)}")) {
        if (Test-Path -LiteralPath $cs) { $state.GhostKeys.Add($cs) }
    }

    return $state
}

function Get-StaleAssociations {
    <# 找出所有仍指向「已不存在」的稳定版 Edge 可执行文件的注册表命令值 #>
    $searchFor  = 'Microsoft\Edge\Application\msedge.exe'
    $hits       = & reg.exe query HKCR /f $searchFor /s /d 2>$null
    $candidates = @()
    foreach ($line in @($hits)) {
        if ($line -match '^HKEY_CLASSES_ROOT\\(.+)$') { $candidates += ($line -replace '^\s+|\s+$', '') }
    }

    $stale = New-Object System.Collections.Generic.List[object]
    foreach ($key in $candidates | Select-Object -Unique) {
        $props = Get-ItemProperty -LiteralPath "Registry::$key" -ErrorAction SilentlyContinue
        if ($null -eq $props) { continue }
        foreach ($p in $props.PSObject.Properties) {
            if ($p.Name -like 'PS*') { continue }
            if ($p.Value -isnot [string]) { continue }
            $m = [regex]::Match($p.Value, $script:LegacyEdgePattern)
            if (-not $m.Success) { continue }
            if (Test-Path -LiteralPath $m.Value) { continue }   # 文件仍在 => 不是失效项
            $stale.Add([pscustomobject]@{ Key = $key; ValueName = $p.Name; Value = $p.Value; OldExe = $m.Value })
        }
    }
    return $stale
}

function Find-TargetBrowser {
    $candidates = @(
        (Join-Path $env:LOCALAPPDATA 'Microsoft\Edge SxS\Application\msedge.exe'),
        'C:\Program Files (x86)\Microsoft\Edge SxS\Application\msedge.exe',
        'C:\Program Files\Microsoft\Edge SxS\Application\msedge.exe',
        (Join-Path $env:LOCALAPPDATA 'Microsoft\Edge Beta\Application\msedge.exe'),
        'C:\Program Files (x86)\Microsoft\Edge Beta\Application\msedge.exe',
        (Join-Path $env:LOCALAPPDATA 'Microsoft\Edge Dev\Application\msedge.exe'),
        'C:\Program Files (x86)\Microsoft\Edge Dev\Application\msedge.exe',
        'C:\Program Files\Google\Chrome\Application\chrome.exe',
        'C:\Program Files (x86)\Google\Chrome\Application\chrome.exe',
        (Join-Path $env:LOCALAPPDATA 'Google\Chrome\Application\chrome.exe')
    )
    foreach ($c in $candidates) { if (Test-Path -LiteralPath $c) { return $c } }
    return $null
}

# ------------------------------------------------------------------ steps ----

function Backup-Registry {
    param([string]$Directory)
    $stamp  = Get-Date -Format 'yyyyMMdd-HHmmss'
    $target = Join-Path $Directory ("backup-{0}" -f $stamp)
    if ($DryRun) {
        Write-Log "[DryRun] 将备份注册表到 $target" 'STEP'
        return $target
    }
    New-Item -ItemType Directory -Force -Path $target | Out-Null

    $keys = @(
        'HKLM\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients',
        'HKLM\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\ClientState',
        'HKLM\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft Edge',
        'HKLM\SOFTWARE\WOW6432Node\Microsoft\Edge',
        'HKLM\SOFTWARE\WOW6432Node\Clients\StartMenuInternet\Microsoft Edge',
        'HKLM\SOFTWARE\Clients\StartMenuInternet\Microsoft Edge',
        'HKLM\SOFTWARE\RegisteredApplications',
        'HKLM\SOFTWARE\WOW6432Node\RegisteredApplications',
        'HKCU\SOFTWARE\Classes\http\shell\open\command',
        'HKCU\SOFTWARE\Classes\https\shell\open\command',
        'HKCU\SOFTWARE\Classes\MSEdgeHTM',
        'HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\msedge.exe'
    )
    $i = 0
    foreach ($k in $keys) {
        $i++
        $file = Join-Path $target ("{0:D2}-{1}.reg" -f $i, ($k -replace '[\\/:*?"<>|]', '_'))
        & reg.exe export $k $file /y 2>$null | Out-Null
        if (-not (Test-Path -LiteralPath $file)) { Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue }
    }
    $count = (Get-ChildItem -LiteralPath $target -Filter *.reg -ErrorAction SilentlyContinue | Measure-Object).Count
    Write-Log ("注册表已备份：{0}（{1} 个文件）" -f $target, $count) 'OK'
    Add-Result '注册表备份' $true $target
    return $target
}

function Stop-EdgeProcesses {
    # 只结束稳定版 Edge 自己的进程，避免误杀 Canary/Beta 等正在使用的浏览器
    $all     = @(Get-Process -Name msedge -ErrorAction SilentlyContinue)
    $targets = @()
    foreach ($p in $all) {
        $exe = $null
        try { $exe = $p.Path } catch { }
        if (-not $exe) { continue }
        foreach ($root in $installRoots) {
            if ($exe.StartsWith((Join-Path $root 'Application'), [System.StringComparison]::OrdinalIgnoreCase)) {
                $targets += $p
                break
            }
        }
    }

    if ($targets.Count -eq 0) {
        Write-Log ("没有属于稳定版 Edge 的进程在运行（当前共有 {0} 个 msedge 进程，属于其他通道，保持不动）" -f $all.Count) 'INFO'
        Add-Result '关闭稳定版 Edge 进程' $true '无需处理'
        return
    }
    if ($DryRun) {
        Write-Log ("[DryRun] 将结束 {0} 个稳定版 Edge 进程：{1}" -f $targets.Count, (($targets.Id) -join ',')) 'STEP'
        Add-Result '关闭稳定版 Edge 进程' $true 'DryRun'
        return
    }
    foreach ($p in $targets) {
        try { Stop-Process -Id $p.Id -Force -ErrorAction Stop } catch { }
    }
    Start-Sleep -Seconds 2
    $left = 0
    foreach ($p in $targets) { if (Get-Process -Id $p.Id -ErrorAction SilentlyContinue) { $left++ } }
    Write-Log ("已结束 {0} 个稳定版 Edge 进程（剩余 {1}）" -f $targets.Count, $left) 'OK'
    Add-Result '关闭稳定版 Edge 进程' ($left -eq 0) ("剩余 $left")
}

function Invoke-OfficialUninstall {
    param($State)
    $done = 0
    foreach ($s in $State.SetupExes) {
        $setupArgs = if ($s.PerUser) {
            @('--uninstall', '--verbose-logging', '--force-uninstall')
        } else {
            @('--uninstall', '--system-level', '--verbose-logging', '--force-uninstall')
        }
        if ($DryRun) {
            Write-Log ("[DryRun] 将执行：`"{0}`" {1}" -f $s.Exe, ($setupArgs -join ' ')) 'STEP'
            continue
        }
        Write-Log ("调用官方卸载：{0}（{1}）" -f $s.Version, $s.Exe) 'STEP'
        try {
            $p = Start-Process -FilePath $s.Exe -ArgumentList $setupArgs -PassThru -Wait -ErrorAction Stop
            Write-Log ("setup.exe 退出码 {0}（Win11 常见为 93=被系统拒绝，随后会强制清理）" -f $p.ExitCode) 'INFO'
            $done++
        } catch {
            Write-Log ("setup.exe 启动失败：{0}" -f $_.Exception.Message) 'WARN'
        }
        Start-Sleep -Seconds 3
    }
    if (-not $DryRun) { Add-Result '官方卸载程序调用' ($done -gt 0 -or $State.SetupExes.Count -eq 0) ("$done 个版本") }
}

function Remove-EdgeFiles {
    param($State)
    foreach ($root in $State.InstallRoots) {
        if (-not (Test-Path -LiteralPath $root)) {
            Write-Log ("目录已不存在：{0}" -f $root) 'INFO'
            continue
        }
        if ($DryRun) {
            Write-Log ("[DryRun] 将取得所有权并删除目录：{0}" -f $root) 'STEP'
            continue
        }
        Write-Log ("清除残留目录：{0}" -f $root) 'STEP'
        & takeown.exe /f $root /r /d Y 2>$null | Out-Null
        & icacls.exe $root /grant '*S-1-5-32-544:(OI)(CI)F' /t /c /q 2>$null | Out-Null
        for ($n = 1; $n -le 6; $n++) {
            Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
            if (-not (Test-Path -LiteralPath $root)) { break }
            Start-Sleep -Seconds 3
        }
        $gone = -not (Test-Path -LiteralPath $root)
        if ($gone) { Write-Log ("已删除 {0}" -f $root) 'OK' } else { Write-Log ("删除失败：{0}" -f $root) 'ERR' }
        Add-Result ("删除目录 {0}" -f $root) $gone
    }
}

function ConvertTo-RegistryPath {
    # PowerShell 的 PSPath 形如 Microsoft.PowerShell.Core\Registry::HKEY_LOCAL_MACHINE\...
    # 注意：不能在方法调用的参数里直接链式 -replace（逗号会被当作参数分隔符）
    param([string]$Path)
    $p = $Path -replace '^Microsoft\.PowerShell\.Core\\Registry::', ''
    $p = $p -replace '^HKEY_LOCAL_MACHINE', 'HKLM:'
    $p = $p -replace '^HKEY_CURRENT_USER', 'HKCU:'
    return $p
}

function Remove-EdgeRegistry {
    param($State)
    $targets = New-Object System.Collections.Generic.List[string]
    foreach ($k in $State.ClientKeys) {
        $targets.Add((ConvertTo-RegistryPath -Path $k))
    }
    foreach ($k in $State.UninstallKeys) {
        $targets.Add((ConvertTo-RegistryPath -Path $k))
    }
    foreach ($k in $State.GhostKeys) {
        if ($k -like '*|Microsoft Edge') {
            $parent = $k.Split('|')[0]
            if ($DryRun) { Write-Log ("[DryRun] 将删除注册表值 {0} -> Microsoft Edge" -f $parent) 'STEP'; continue }
            Remove-ItemProperty -LiteralPath $parent -Name 'Microsoft Edge' -Force -ErrorAction SilentlyContinue
            $still = $null -ne (Get-ItemProperty -LiteralPath $parent -ErrorAction SilentlyContinue).'Microsoft Edge'
            Write-Log ("清理 RegisteredApplications\Microsoft Edge -> 仍存在={0}" -f $still) 'OK'
            Add-Result '清理 RegisteredApplications\Microsoft Edge' (-not $still)
        } else {
            $targets.Add($k)
        }
    }
    # EdgeUpdate ClientState（不删更新器自身，避免影响其它通道的自动更新）
    foreach ($cs in @(
            'HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\ClientState\' + "{$($script:StableGuid)}",
            'HKLM:\SOFTWARE\Microsoft\EdgeUpdate\ClientState\' + "{$($script:StableGuid)}",
            'HKCU:\SOFTWARE\Microsoft\EdgeUpdate\ClientState\' + "{$($script:StableGuid)}",
            'HKCU:\SOFTWARE\Microsoft\EdgeUpdate\Clients\' + "{$($script:StableGuid)}",
            'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\msedge.exe')) {
        $targets.Add($cs)
    }

    foreach ($t in ($targets | Select-Object -Unique)) {
        if (-not (Test-Path -LiteralPath $t)) { continue }
        if ($DryRun) { Write-Log ("[DryRun] 将删除注册表项：{0}" -f $t) 'STEP'; continue }
        Remove-Item -LiteralPath $t -Recurse -Force -ErrorAction SilentlyContinue
        $gone = -not (Test-Path -LiteralPath $t)
        Write-Log ("删除注册表项 {0} -> 成功={1}" -f $t, $gone) $(if ($gone) { 'OK' } else { 'ERR' })
        Add-Result ("删除注册表项 {0}" -f $t) $gone
    }
}

function Remove-DeadShortcuts {
    param([string[]]$OldRoots)

    $dirs = @(
        'C:\ProgramData\Microsoft\Windows\Start Menu\Programs',
        (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'),
        (Join-Path $env:USERPROFILE 'Desktop'),
        'C:\Users\Public\Desktop',
        (Join-Path $env:APPDATA 'Microsoft\Internet Explorer\Quick Launch'),
        (Join-Path $env:APPDATA 'Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar')
    ) | Select-Object -Unique

    $wsh = New-Object -ComObject WScript.Shell
    $removed = 0
    foreach ($d in $dirs) {
        if (-not (Test-Path -LiteralPath $d)) { continue }
        Get-ChildItem -LiteralPath $d -Filter *.lnk -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
            $target = $null
            try { $target = $wsh.CreateShortcut($_.FullName).TargetPath } catch { }
            $isEdge = $false
            foreach ($old in $OldRoots) {
                if ($target -and $target.StartsWith((Join-Path $old 'Application'), [System.StringComparison]::OrdinalIgnoreCase)) { $isEdge = $true }
            }
            if (-not $isEdge -and $_.Name -eq 'Microsoft Edge.lnk' -and ($target -eq '' -or -not (Test-Path -LiteralPath $target))) { $isEdge = $true }
            if ($isEdge) {
                if ($DryRun) { Write-Log ("[DryRun] 将删除快捷方式：{0}" -f $_.FullName) 'STEP' }
                else {
                    Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue
                    if (-not (Test-Path -LiteralPath $_.FullName)) { Write-Log ("已删除快捷方式：{0}" -f $_.FullName) 'OK'; $removed++ }
                }
            }
        }
    }
    if ($removed -eq 0 -and -not $DryRun) { Write-Log '没有需要清理的失效快捷方式' 'INFO' }
    if (-not $DryRun) { Add-Result '清理失效快捷方式' $true ("删除 $removed 个") }
}

function Repair-Associations {
    param($State, [string]$Browser)

    if (-not $Browser) {
        Write-Log '未找到可用的替代浏览器，跳过关联修复。可加 -TargetBrowser 指定 exe 后重跑。' 'WARN'
        Add-Result '修复文件/协议关联' $false '未指定替代浏览器'
        return
    }
    Write-Log ("关联重定向目标：{0}" -f $Browser) 'STEP'

    $stale = Get-StaleAssociations
    if (@($stale).Count -eq 0) {
        Write-Log '没有发现指向已删除路径的关联项' 'OK'
        Add-Result '修复文件/协议关联' $true '无需修复'
        return
    }

    $fixed = 0
    foreach ($s in $stale) {
        # 用正则替换，兼容大小写差异和带版本号子目录的旧路径
        $newValue = [regex]::Replace($s.Value, $script:LegacyEdgePattern, { param($m) $Browser })
        $rel = $s.Key -replace '^HKEY_CLASSES_ROOT\\', ''
        $dest = "HKCU:\Software\Classes\$rel"
        if ($DryRun) {
            Write-Log ("[DryRun] {0} :: {1}`n        {2}`n     -> {3}" -f $s.Key, $s.ValueName, $s.Value, $newValue) 'STEP'
            continue
        }
        try {
            New-Item -Path $dest -Force | Out-Null
            Set-ItemProperty -LiteralPath $dest -Name $s.ValueName -Value $newValue -ErrorAction Stop
            $fixed++
            Write-Log ("已重定向 {0} ({1})" -f $rel, $s.ValueName) 'OK'
        } catch {
            Write-Log ("重定向失败 {0}：{1}" -f $rel, $_.Exception.Message) 'ERR'
        }
    }
    if (-not $DryRun) {
        $left = @(Get-StaleAssociations).Count
        $script:StaleAfter = $left
        Add-Result '修复文件/协议关联' ($left -eq 0) ("已修复 $fixed 项，剩余 $left 项")
    }
}

function Remove-EdgeUserData {
    $p = Join-Path $env:LOCALAPPDATA 'Microsoft\Edge\User Data'
    if (-not (Test-Path -LiteralPath $p)) { return }
    if ($DryRun) { Write-Log ("[DryRun] 将删除用户数据：{0}" -f $p) 'STEP'; return }
    Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction SilentlyContinue
    Write-Log ("已删除用户数据：{0}（成功={1}）" -f $p, (-not (Test-Path -LiteralPath $p))) 'OK'
}

function Test-FinalState {
    param($State, [string]$Browser)

    $after = Get-EdgeStableState
    $staleCount = if ($null -ne $script:StaleAfter) { $script:StaleAfter } else { @(Get-StaleAssociations).Count }

    if (-not $DryRun) {
        Add-Result '稳定版 Edge 目录已清除' ($after.InstallRoots.Count -eq 0) (($after.InstallRoots) -join ', ')
        Add-Result 'EdgeUpdate 稳定版客户端已移除' ($after.ClientKeys.Count -eq 0) (($after.ClientKeys) -join ', ')
        Add-Result '卸载项已移除' ($after.UninstallKeys.Count -eq 0) (($after.UninstallKeys) -join ', ')
        Add-Result '指向已删路径的关联项' ($staleCount -eq 0) ("剩余 $staleCount 项")
        $csLeft = @(@(
                "HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\ClientState\{$($script:StableGuid)}",
                "HKLM:\SOFTWARE\Microsoft\EdgeUpdate\ClientState\{$($script:StableGuid)}",
                "HKCU:\SOFTWARE\Microsoft\EdgeUpdate\ClientState\{$($script:StableGuid)}") |
                Where-Object { Test-Path -LiteralPath $_ }).Count
        Add-Result 'EdgeUpdate ClientState 已清除' ($csLeft -eq 0) ("剩余 $csLeft 项")
        $wv = Get-ItemProperty 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}' -ErrorAction SilentlyContinue
        Add-Result 'WebView2 运行时保留' ($null -ne $wv) ([string]$wv.pv)
        if ($Browser) { Add-Result '替代浏览器可用' (Test-Path -LiteralPath $Browser) $Browser }
    }
}

# ------------------------------------------------------------------- main ----

Write-Host ''
Write-Host '================ 移除旧版（稳定版）Microsoft Edge ================' -ForegroundColor Cyan
Write-Log ("Remove-OldEdge v{0}" -f $script:ScriptVersion) 'INFO'
Write-Log ("主机：{0}  Windows {1}" -f $env:COMPUTERNAME, [Environment]::OSVersion.Version) 'INFO'
Write-Log ("管理员：{0}  DryRun：{1}" -f $script:IsAdmin, [bool]$DryRun) 'INFO'

Resolve-LogPaths

$state = Get-EdgeStableState
$workCount = $state.InstallRoots.Count + $state.ClientKeys.Count + $state.UninstallKeys.Count + $state.GhostKeys.Count

Write-Log ("探测结果：安装目录 {0} 个、可执行版本 {1} 个、EdgeUpdate 客户端 {2} 个、卸载项 {3} 个、幽灵登记 {4} 个" -f `
        $state.InstallRoots.Count, $state.Versions.Count, $state.ClientKeys.Count, $state.UninstallKeys.Count, $state.GhostKeys.Count) 'STEP'

if (-not $TargetBrowser) { $TargetBrowser = Find-TargetBrowser }

if ($workCount -eq 0) {
    $staleOnly = @(Get-StaleAssociations)
    if ($staleOnly.Count -eq 0) {
        Write-Log '系统已经是干净状态：未发现稳定版 Edge 的文件、注册表登记或失效关联。' 'OK'
        Write-Host ''
        Write-Host '无需任何操作。' -ForegroundColor Green
        exit 0
    }
    Write-Log ("未发现稳定版 Edge 本体，但有 {0} 处关联仍指向已删除路径，将进行修复。" -f $staleOnly.Count) 'WARN'
}

if (-not $DryRun -and -not $script:IsAdmin -and -not $SkipElevate) {
    Write-Log '需要管理员权限才能删除 Program Files 目录和 HKLM 注册表项，正在提权…' 'WARN'
    $code = Invoke-SelfElevate
    if ($script:LogFile -and (Test-Path -LiteralPath $script:LogFile)) {
        Write-Host ''
        Write-Host '---------------- 提权进程日志 ----------------' -ForegroundColor DarkGray
        Get-Content -LiteralPath $script:LogFile | ForEach-Object { Write-Host $_ -ForegroundColor DarkGray }
    }
    exit $code
}

$backupDir = Backup-Registry -Directory $script:LogDirectory
$null = $backupDir

Stop-EdgeProcesses
Invoke-OfficialUninstall -State $state
Remove-EdgeFiles -State $state

# Edge 更新服务可能在清理后回写客户端登记，这里带重试地清干净
for ($pass = 1; $pass -le 3; $pass++) {
    Remove-EdgeRegistry -State (Get-EdgeStableState)
    if ($DryRun) { break }
    $check = Get-EdgeStableState
    $leftClients = $check.ClientKeys.Count + @($check.GhostKeys | Where-Object { $_ -like '*EdgeUpdate\ClientState*' }).Count
    if ($leftClients -eq 0) { break }
    Write-Log ("第 {0} 轮清理后仍有 {1} 个稳定版 EdgeUpdate 登记，5 秒后重试" -f $pass, $leftClients) 'WARN'
    Start-Sleep -Seconds 5
}

Remove-DeadShortcuts -OldRoots $installRoots
Repair-Associations -State $state -Browser $TargetBrowser
if ($PurgeUserData) { Remove-EdgeUserData }
Test-FinalState -State $state -Browser $TargetBrowser

# --------------------------------------------------------------- summary ----

function Write-SummaryLine {
    param([string]$Text, [string]$Color = 'Gray')
    Write-Host $Text -ForegroundColor $Color
    if ($script:CanWriteLog) { try { Add-Content -LiteralPath $script:LogFile -Value $Text -Encoding UTF8 } catch { } }
}

Write-Host ''
Write-SummaryLine '========================= 结果汇总 =========================' 'Cyan'
foreach ($r in $script:Results) {
    $flag = if ($r.Ok) { '[OK]  ' } else { '[FAIL]' }
    $color = if ($r.Ok) { 'Green' } else { 'Red' }
    Write-SummaryLine ("{0} {1}  {2}" -f $flag, $r.Item, $r.Detail) $color
}
Write-Host ''
if ($script:LogFile) { Write-Host ("日志：{0}" -f $script:LogFile) -ForegroundColor Gray }
if ($backupDir)       { Write-Host ("备份：{0}（reg import 可回滚）" -f $backupDir) -ForegroundColor Gray }
Write-SummaryLine '未重启电脑。' 'Green'
if ($TargetBrowser) {
    Write-Host ("若要把 {0} 设为默认浏览器：打开该浏览器 → 设置 → 默认浏览器 → 设为默认。" -f (Split-Path $TargetBrowser -Leaf)) -ForegroundColor Gray
}
Write-Host '注意：Windows 功能更新（大版本升级）有可能重新安装稳定版 Edge，届时重跑本脚本即可。' -ForegroundColor DarkYellow

if ($script:Issues.Count -gt 0) {
    Write-Host ''
    Write-SummaryLine ("存在 {0} 项未完成的检查，详见上方 [FAIL] 行。" -f $script:Issues.Count) 'Yellow'
    if (-not $DryRun) { Write-Host '可稍等 1 分钟后再次运行本脚本，残留项通常会被清理干净。' -ForegroundColor Gray }
    exit 1
}

Write-Host ''
Write-SummaryLine '全部完成。' 'Green'
exit 0
