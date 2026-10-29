<#
  NetKeeper 安装器
  - 找到（或新建）PPPoE 宽带连接
  - 账号密码加密保存，密钥只给 SYSTEM / Administrators
  - 整套运行文件装到 C:\ProgramData\NetKeeper（普通用户不可写，避免提权）
  - 注册开机任务：SYSTEM 身份、开机 10 秒后启动、无需登录桌面
  - 立即启动并显示日志
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$Script:Root = $PSScriptRoot
if (-not $Script:Root) { $Script:Root = Split-Path -Parent $MyInvocation.MyCommand.Definition }
$Script:InstallDir = Join-Path $env:ProgramData 'NetKeeper'

function Say($msg, $color = 'Gray') { Write-Host $msg -ForegroundColor $color }
function Fail($msg) { Write-Host "`n[失败] $msg" -ForegroundColor Red; Read-Host '按回车关闭' | Out-Null; exit 1 }

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

Say '' ; Say '==============================================' Cyan
Say '  NetKeeper — 宽带自动拨号（开机即拨）' Cyan
Say '==============================================' Cyan

if (-not (Test-Admin)) {
    Say '  需要管理员权限，正在请求提权…' Yellow
    try {
        Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-NoExit', '-File', ('"{0}"' -f $PSCommandPath))
    } catch {
        Say '  提权被取消或失败。请右键「安装.bat」→ 以管理员身份运行。' Red
        Read-Host '按回车关闭' | Out-Null
    }
    exit
}

# ---------- 0. 运行环境要求 ----------
$scriptSrc = Join-Path $Script:Root 'NetKeeper.ps1'
if (-not (Test-Path $scriptSrc)) { Fail "找不到 NetKeeper.ps1，请把整个文件夹一起复制过来。" }
$rasService = Get-Service -Name 'RasMan' -ErrorAction SilentlyContinue
if (-not $rasService) { Fail '本机没有「远程访问连接管理器」(RasMan) 服务，无法 PPPoE 拨号。' }
if ($rasService.StartType -eq 'Disabled') {
    Say '  「远程访问连接管理器」被禁用了，正在改为自动启动…' Yellow
    Set-Service -Name 'RasMan' -StartupType Automatic
    Start-Service -Name 'RasMan'
}
if ($rasService.Status -ne 'Running') {
    Say '  正在启动「远程访问连接管理器」…' Yellow
    try { Start-Service -Name 'RasMan' } catch { Fail "无法启动 RasMan：$($_.Exception.Message)" }
}

# ---------- 电话簿读写 ----------
$UserPbk = Join-Path $env:APPDATA 'Microsoft\Network\Connections\Pbk\rasphone.pbk'
$AllPbk  = Join-Path $env:ProgramData 'Microsoft\Network\Connections\Pbk\rasphone.pbk'

# 电话簿读写交给共用模块（安装/卸载共用，避免两处解析逻辑跑偏）
. (Join-Path $Script:Root 'Pbk.ps1')

# ---------- 权限：目录/文件只给 SYSTEM + Administrators ----------
$sidSystem = New-Object Security.Principal.SecurityIdentifier('S-1-5-18')
$sidAdmins = New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544')
function Protect-Path([string]$path, [bool]$isDir) {
    try {
        if ($isDir) { $acl = New-Object Security.AccessControl.DirectorySecurity }
        else { $acl = New-Object Security.AccessControl.FileSecurity }
        $acl.SetAccessRuleProtection($true, $false)
        try { $acl.SetOwner($sidSystem) } catch { }
        if ($isDir) {
            # 目录必须带继承标记（ContainerInherit,ObjectInherit），否则这个 ACE 只管目录本身：
            # 之后在它下面新建的 logs\ 子目录会得到「空 DACL」——连 SYSTEM 和管理员都进不去
            # （实测：安装末尾读日志报 Test-Path 拒绝访问，就是这个原因）。
            $inherit = [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
            $prop = [Security.AccessControl.PropagationFlags]::None
            $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule(
                $sidSystem, 'FullControl', $inherit, $prop, 'Allow')))
            $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule(
                $sidAdmins, 'FullControl', $inherit, $prop, 'Allow')))
        } else {
            $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($sidSystem, 'FullControl', 'Allow')))
            $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($sidAdmins, 'FullControl', 'Allow')))
        }
        Set-Acl -Path $path -AclObject $acl
    } catch {
        Say ("  警告：无法收紧「{0}」的权限：{1}" -f $path, $_.Exception.Message) Yellow
    }
}


# ---------- 1. 找宽带连接 ----------
Say "`n[1/5] 查找已有的宽带连接…"
$userEntries = Get-PbkEntries $UserPbk
$allEntries  = Get-PbkEntries $AllPbk
Say ("  当前用户：{0}" -f $(if ($userEntries.Count) { $userEntries -join '、' } else { '（无）' }))
Say ("  所有用户：{0}" -f $(if ($allEntries.Count) { $allEntries -join '、' } else { '（无）' }))

$all = @(@($userEntries) + @($allEntries) | Select-Object -Unique)
if ($all.Count -eq 0) {
    Say "`n  没有找到任何宽带连接。" Yellow
    Say '  接下来会打开 Windows 的「新建连接」向导，请按提示建一个 PPPoE 宽带连接：' Yellow
    Say '    宽带(PPPoE) → 输入运营商给的账号密码 → 连接名称随意（记住它）' Yellow
    Read-Host '按回车打开向导' | Out-Null
    Start-Process rasphone.exe -ArgumentList '-a' -Wait
    $userEntries = Get-PbkEntries $UserPbk
    $allEntries  = Get-PbkEntries $AllPbk
    $all = @(@($userEntries) + @($allEntries) | Select-Object -Unique)
    if ($all.Count -eq 0) { Fail '仍然没有找到宽带连接，安装终止。' }
}

$default = if ($all -contains '宽带连接') { '宽带连接' } else { $all[0] }
$name = Read-Host ("  用哪个连接？直接回车 = {0}" -f $default)
if ([string]::IsNullOrWhiteSpace($name)) { $name = $default }
if ($all -notcontains $name) { Fail "列表里没有「$name」这个连接。" }

# ---------- 1.5 升级时默认沿用旧账号密码 ----------
$oldCfgPath = Join-Path $Script:InstallDir 'config.json'
$oldKeyPath = Join-Path $Script:InstallDir 'netkeeper.key'
$keepOld = $false
$oldCfg = $null
$oldKey = $null
if ((Test-Path $oldCfgPath) -and (Test-Path $oldKeyPath)) {
    try {
        $oldCfg = [IO.File]::ReadAllText($oldCfgPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
        $oldKey = [IO.File]::ReadAllBytes($oldKeyPath)
        if ($oldCfg.User -and $oldCfg.Password -and $oldKey.Length -eq 32) { $keepOld = $true }
    } catch {
        Say ("  检测到旧配置但读不出来（{0}），将重新录入。" -f $_.Exception.Message) Yellow
    }
}
if ($keepOld) {
    Say "`n[1.5] 发现已安装的配置：账号 $($oldCfg.User)"
    $ans = Read-Host '  沿用这个账号密码？直接回车 = 沿用（输入 n 重新录入）'
    if ($ans -and $ans.Trim().ToLower() -eq 'n') { $keepOld = $false }
}

# ---------- 2. 账号密码 ----------
Say "`n[2/5] 录入宽带账号密码（只存在本机，加密保存）"
if ($keepOld) {
    $user = [string]$oldCfg.User
    $cipher = [string]$oldCfg.Password
    $key = $oldKey
    Say "  已沿用账号 $user（密码未改动）" Green
} else {
    $user = Read-Host '  宽带账号'
    if ([string]::IsNullOrWhiteSpace($user)) { Fail '账号不能为空。' }
    $sec = Read-Host '  宽带密码' -AsSecureString
    if ($sec.Length -eq 0) { Fail '密码不能为空。' }

    $key = New-Object byte[] 32
    [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($key)
    $cipher = ConvertFrom-SecureString -SecureString $sec -Key $key
}

# ---------- 3. 装到 ProgramData（普通用户不可写） ----------
Say "`n[3/5] 安装运行文件到 $($Script:InstallDir)…"
if (Test-Path $Script:InstallDir) {
    # 升级/重装：先停掉旧任务，避免文件被占用
    Unregister-ScheduledTask -TaskName 'NetKeeper-宽带自动拨号' -Confirm:$false -ErrorAction SilentlyContinue
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -and $_.CommandLine -like '*NetKeeper.ps1*' -and $_.CommandLine -like '*ProgramData*' } |
        ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force } catch { } }
    Start-Sleep -Milliseconds 500
    if (-not (Force-RemoveDir $Script:InstallDir)) {
        $hint = "删不掉旧的 $($Script:InstallDir)（权限被锁死了）。请在管理员 PowerShell 里手动执行：`n" +
                "    takeown /f `"$($Script:InstallDir)`" /r /d y`n" +
                "    icacls `"$($Script:InstallDir)`" /reset /t /c /q`n" +
                "    rmdir /s /q `"$($Script:InstallDir)`""
        Fail $hint
    }
}
New-Item -ItemType Directory -Path $Script:InstallDir -Force | Out-Null
Protect-Path $Script:InstallDir $true
# logs 目录先建好并同样收紧权限：让 SYSTEM 直接往里写，也免得它自己建出个权限不对的目录
$logDir = Join-Path $Script:InstallDir 'logs'
New-Item -ItemType Directory -Path $logDir -Force | Out-Null
Protect-Path $logDir $true

# 复制主程序时统一转成 UTF-8 with BOM。
# PowerShell 5.1 读「无 BOM 的 UTF-8」会按 ANSI/GBK 解码：中文注释和字符串先变乱码，
# 更糟的是 here-string 的 @" ... "@ 边界被吃掉，整段 C# 就被当成脚本语法，
# 报一堆「缺少 using 指令」「函数参数列表中缺少 )」——而且只在开机时才暴露。
$dstNk = Join-Path $Script:InstallDir 'NetKeeper.ps1'
$nkText = [IO.File]::ReadAllText($scriptSrc, [Text.Encoding]::UTF8)
[IO.File]::WriteAllText($dstNk, $nkText, (New-Object Text.UTF8Encoding($true)))
# 装完当场解析一遍：坏了现在就说，别等重启
$pErr = $null
[void][Management.Automation.Language.Parser]::ParseFile($dstNk, [ref]$null, [ref]$pErr)
if ($pErr -and $pErr.Count -gt 0) {
    Fail ("主程序语法检查失败（{0} 处），第一个错误：`n    {1}`n（第 {2} 行）`n源文件编码可能不对，请用 UTF-8 with BOM 保存后重试。" -f `
        $pErr.Count, $pErr[0].Message, $pErr[0].Extent.StartLineNumber)
}
$keyFile = Join-Path $Script:InstallDir 'netkeeper.key'
[IO.File]::WriteAllBytes($keyFile, $key)
Protect-Path $keyFile $false

$cfg = [ordered]@{
    ConnectionName   = $name
    User             = $user
    Password         = $cipher
    KeyFile          = 'netkeeper.key'
    CheckIntervalSec = 10
    ZombieLimit      = 2
    DialMode         = $(if ($keepOld -and $oldCfg.DialMode) { [string]$oldCfg.DialMode } else { 'auto' })
    TcpTargets       = @('223.5.5.5:53', '119.29.29.29:53', '180.76.76.76:53')
    HttpTargets      = @('http://www.msftconnecttest.com/connecttest.txt',
                         'http://connect.rom.miui.com/generate_204')
}
$cfgPath = Join-Path $Script:InstallDir 'config.json'
($cfg | ConvertTo-Json -Depth 4) | Set-Content -Path $cfgPath -Encoding UTF8
Protect-Path $cfgPath $false
Say '  已安装（密码 AES 加密，运行文件只有管理员能改）' Green

# ---------- 4. 让 SYSTEM 也能看到这个连接 ----------
Say "`n[4/5] 让 SYSTEM 账户也能拨这个连接…"
if ($allEntries -notcontains $name) {
    $sec2 = Get-PbkSection $UserPbk $name
    if (-not $sec2) { $sec2 = Get-PbkSection $AllPbk $name }
    if ($sec2) {
        if (Add-PbkSection $AllPbk $sec2) {
            Say "  已复制「$name」到「所有用户」（备份：rasphone.pbk.bak）" Green
        } else {
            Say '  复制连接定义失败，写入被拒绝。' Yellow
        }
    } else {
        Say '  未能复制连接定义；若拨号报 623，请手动重建连接并勾选「允许其他用户使用」。' Yellow
    }
} else {
    Say '  该连接已在「所有用户」里，无需复制' Green
}

# ---------- 5. 注册开机任务并启动 ----------
Say "`n[5/5] 注册开机自动拨号任务…"
$taskName = 'NetKeeper-宽带自动拨号'
$target = Join-Path $Script:InstallDir 'NetKeeper.ps1'
$arg = '-NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}"' -f $target
Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arg
$trigger = New-ScheduledTaskTrigger -AtStartup
# 立刻启动（Delay=0）：开机后网卡可能还没就绪，拨号会失败，
# 但守护进程本身会以 2/3/5/8/12/20/30 秒的节奏重试，比「先干等 10 秒」更快连上
try { $trigger.Delay = 'PT0S' } catch { Say '  （该系统的任务触发器不支持 Delay，改为立即启动）' Gray }
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -StartWhenAvailable -ExecutionTimeLimit ([TimeSpan]::Zero) `
    -RestartInterval (New-TimeSpan -Minutes 1) -RestartCount 999 `
    -MultipleInstances IgnoreNew
Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger `
    -Principal $principal -Settings $settings `
    -Description '开机自动拨号并在掉线时重拨（NetKeeper）' | Out-Null
Say "  已注册计划任务：$taskName（SYSTEM 身份，开机 10 秒后启动）" Green

Say "`n正在启动并验证…"
Start-ScheduledTask -TaskName $taskName
Start-Sleep -Seconds 8
$today = Join-Path (Join-Path $Script:InstallDir 'logs') ('keeper-{0}.log' -f (Get-Date -Format 'yyyyMMdd'))
# 这段只是"顺手看一眼"，任何失败都不该让安装失败（曾被空 DACL 的 logs 目录打断过）
$logLines = $null
try {
    if (Test-Path -LiteralPath $today -ErrorAction Stop) {
        $logLines = @(Get-Content -LiteralPath $today -Tail 10 -ErrorAction Stop)
    }
} catch {
    Say ("  读日志时被拒绝：{0}" -f $_.Exception.Message) Yellow
}
if ($logLines -and $logLines.Count -gt 0) {
    Say "`n最近的运行日志："
    $logLines | ForEach-Object { Say "  $_" }
} else {
    Say '  日志暂时读不到或还没生成（SYSTEM 启动任务需要几秒）。稍后双击「查看日志.bat」。' Yellow
}

Say ''
Say '安装完成：以后开机会自动拨号，掉线 10 秒内重拨。' Green
Say '手动重拨 → 立即重拨.bat；看日志 → 查看日志.bat；卸载 → 卸载.bat' Gray
Read-Host '按回车关闭' | Out-Null
