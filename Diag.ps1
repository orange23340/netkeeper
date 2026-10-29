# NetKeeper 诊断：把「开机为什么没拨上」需要的信息一次性收集出来
# 只读：不拨号、不改配置、不动计划任务
$ErrorActionPreference = 'Continue'
$Script:Root = $PSScriptRoot
if (-not $Script:Root) { $Script:Root = Split-Path -Parent $MyInvocation.MyCommand.Definition }
$InstallDir = Join-Path $env:ProgramData 'NetKeeper'
$TaskName = 'NetKeeper-宽带自动拨号'
$outFile = Join-Path ([Environment]::GetFolderPath('Desktop')) 'NetKeeper诊断.txt'
$lines = New-Object System.Collections.Generic.List[string]

function Add-Line([string]$s = '') { $lines.Add($s); Write-Host $s }
function Add-Head([string]$s) { Add-Line ''; Add-Line ('=' * 60); Add-Line $s; Add-Line ('=' * 60) }
# 三态探测：'yes' / 'no' / 'denied'。直接 Test-Path 遇到无权限路径会抛异常，
# 把「没权限」误报成「文件不存在」，会把人带偏。
function Probe([string]$p) {
    try { if (Test-Path -LiteralPath $p -ErrorAction Stop) { return 'yes' } else { return 'no' } }
    catch { return 'denied' }
}

Add-Line 'NetKeeper 诊断报告'
Add-Line ('生成时间：' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))

$id = [Security.Principal.WindowsIdentity]::GetCurrent()
$isAdmin = (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
Add-Line ('当前用户：' + $id.Name + '（' + $(if ($isAdmin) { '管理员' } else { '非管理员 ← 部分信息读不到，请用 诊断.bat 提权运行' }) + '）')

# ---------- 1. 安装文件 ----------
Add-Head '1. 安装目录与主程序'
$pDir = Probe $InstallDir
if ($pDir -eq 'denied') {
    Add-Line ('安装目录：' + $InstallDir + ' 存在，但当前身份无权查看')
    Add-Line '  ← 必须用 诊断.bat 提权运行，否则下面的配置/日志/文件全部读不到'
} elseif ($pDir -eq 'no') {
    Add-Line ('安装目录不存在：' + $InstallDir + ' ← 没装上')
} else {
    Add-Line ('安装目录：' + $InstallDir + ' 存在')
    try {
        Get-ChildItem $InstallDir -Force -ErrorAction Stop |
            ForEach-Object { Add-Line ('  ' + $_.Name + '  ' + $_.Length + ' 字节  ' + $_.LastWriteTime) }
    } catch { Add-Line ('  列目录失败：' + $_.Exception.Message) }

    $nk = Join-Path $InstallDir 'NetKeeper.ps1'
    $pNk = Probe $nk
    if ($pNk -eq 'no') {
        Add-Line '  主程序 NetKeeper.ps1 不存在 ← 安装没完成'
    } elseif ($pNk -eq 'denied') {
        Add-Line '  主程序 NetKeeper.ps1 存在但读不到（无权限）'
    } else {
        try {
            $b = [IO.File]::ReadAllBytes($nk)
            $hasBom = ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF)
            Add-Line ('  主程序 BOM：' + $(if ($hasBom) { '有（正常）' } else { '无 ← 会导致语法全崩，请重跑 安装.bat' }))
            $err = $null
            [void][Management.Automation.Language.Parser]::ParseFile($nk, [ref]$null, [ref]$err)
            if ($err -and $err.Count) {
                Add-Line ('  主程序语法：失败 ' + $err.Count + ' 处')
                Add-Line ('    第一条：' + $err[0].Message + '（第 ' + $err[0].Extent.StartLineNumber + ' 行）')
            } else {
                Add-Line '  主程序语法：通过'
            }
        } catch { Add-Line ('  检查主程序失败：' + $_.Exception.Message) }
    }

    # 配置（不打印密码）
    $cfgPath = Join-Path $InstallDir 'config.json'
    $pCfg = Probe $cfgPath
    if ($pCfg -eq 'no') {
        Add-Line '  config.json 不存在 ← 安装没完成'
    } elseif ($pCfg -eq 'denied') {
        Add-Line '  config.json 存在但读不到（无权限）'
    } else {
        try {
            $c = [IO.File]::ReadAllText($cfgPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
            Add-Line ('  配置：连接名=' + $c.ConnectionName + '｜账号=' + $c.User + '｜DialMode=' + $c.DialMode + '｜间隔=' + $c.CheckIntervalSec + 's')
        } catch { Add-Line ('  配置读不出来：' + $_.Exception.Message) }
    }
}

# ---------- 2. 计划任务 ----------
Add-Head '2. 计划任务状态（关键：上次运行时间 / 上次结果）'
try {
    $t = Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop
    $i = $t | Get-ScheduledTaskInfo
    Add-Line ('任务状态：' + $t.State)
    Add-Line ('上次运行：' + $i.LastRunTime + '   上次结果：0x{0:X}' -f $i.LastTaskResult)
    Add-Line ('下次运行：' + $i.NextRunTime)
    foreach ($tr in $t.Triggers) { Add-Line ('触发器：' + $tr.CimClass.CimClassName + '  Delay=' + $tr.Delay) }
    Add-Line ('执行身份：' + $t.Principal.UserId + ' / ' + $t.Principal.RunLevel)
    Add-Line ('动作：' + ($t.Actions | ForEach-Object { $_.Execute + ' ' + $_.Arguments }) )
    Add-Line ('上次结果 0x0 = 成功；0x1 = 脚本返回非 0；0x41301 = 正在运行；0x41303 = 从未运行')
} catch {
    Add-Line ('读不到任务：' + $_.Exception.Message)
    try {
        $q = & schtasks.exe /query /tn $TaskName /v /fo LIST 2>&1
        Add-Line ($q -join "`r`n")
    } catch { Add-Line ('schtasks 也失败：' + $_.Exception.Message) }
}

# ---------- 3. 日志 ----------
Add-Head '3. 运行日志（最近 40 行）'
$logDir = Join-Path $InstallDir 'logs'
$pLog = Probe $logDir
if ($pLog -eq 'denied') {
    Add-Line ('日志目录存在但读不到（无权限）：' + $logDir)
} elseif ($pLog -eq 'no') {
    Add-Line ('日志目录不存在：' + $logDir + '（安装没完成，或权限被改坏了）')
} else {
    try {
        $logs = Get-ChildItem $logDir -Filter 'keeper-*.log' -ErrorAction Stop | Sort-Object LastWriteTime -Descending
        if ($logs.Count -eq 0) { Add-Line '日志目录是空的 ← 进程可能根本没启动，或启动即崩（崩在写日志之前）' }
        foreach ($lf in ($logs | Select-Object -First 2)) {
            Add-Line ('--- ' + $lf.Name + '（' + $lf.Length + ' 字节，' + $lf.LastWriteTime + '）---')
            Get-Content $lf.FullName -Tail 40 -Encoding UTF8 | ForEach-Object { Add-Line ('  ' + $_) }
        }
    } catch { Add-Line ('读日志失败：' + $_.Exception.Message) }
}

# ---------- 4. 电话簿里有哪些连接 ----------
Add-Head '4. 电话簿里的连接（SYSTEM 账户能不能看到它）'
$allPbk = Join-Path $env:ProgramData 'Microsoft\Network\Connections\Pbk\rasphone.pbk'
$userPbk = Join-Path $env:APPDATA 'Microsoft\Network\Connections\Pbk\rasphone.pbk'
function Show-Entries([string]$p, [string]$label) {
    $s = Probe $p
    if ($s -eq 'no') { Add-Line ('  ' + $label + '：文件不存在（' + $p + '）'); return }
    if ($s -eq 'denied') { Add-Line ('  ' + $label + '：存在但读不到（无权限）'); return }
    try {
        $txt = [IO.File]::ReadAllText($p, [Text.Encoding]::UTF8) -replace ([string][char]0xFEFF), ''
        $names = @([regex]::Matches($txt, '(?m)^\[(.+)\]\s*$') | ForEach-Object { $_.Groups[1].Value -replace ('\\' + [char]0xFEFF), '' })
        $names = $names | Where-Object { $_ -and $_ -notmatch '^(windows|&|\\)' -and $_ -notmatch '\.(pbk|xml)$' }
        Add-Line ('  ' + $label + '：' + $(if ($names.Count) { $names -join '、' } else { '（空）' }))
    } catch { Add-Line ('  ' + $label + ' 读取失败：' + $_.Exception.Message) }
}
Show-Entries $userPbk '当前用户 pbk'
Show-Entries $allPbk  '所有用户 pbk'

# ---------- 5. 当前 RAS 状态 ----------
Add-Head '5. 当前 RAS 连接状态（rasdial 无参数 = 只列状态，不拨号）'
try {
    $r = & "$env:WINDIR\System32\rasdial.exe" 2>&1
    Add-Line ('  ' + (($r -join ' ').Trim()))
} catch { Add-Line ('  rasdial 执行失败：' + $_.Exception.Message) }

# ---------- 6. 网络探测 ----------
Add-Head '6. 网络连通性'
foreach ($t in @(@('223.5.5.5', 53), @('119.29.29.29', 53), @('180.76.76.76', 53))) {
    $ok = $false
    try {
        $c = New-Object Net.Sockets.TcpClient
        $ar = $c.BeginConnect($t[0], $t[1], $null, $null)
        if ($ar.AsyncWaitHandle.WaitOne(2000)) { $c.EndConnect($ar); $ok = $c.Connected }
        $c.Close()
    } catch { }
    Add-Line ('  TCP ' + $t[0] + ':' + $t[1] + ' → ' + $(if ($ok) { '通' } else { '不通' }))
}

# ---------- 7. 网卡 ----------
Add-Head '7. 网络适配器（宽带连接是否处于"已断开"）'
try {
    Get-NetAdapter -ErrorAction Stop | Where-Object { $_.InterfaceDescription -notmatch 'Loopback' } |
        ForEach-Object { Add-Line ('  ' + $_.Name + '｜' + $_.InterfaceDescription + '｜' + $_.Status + '｜' + $_.LinkSpeed) }
} catch { Add-Line ('  读网卡失败：' + $_.Exception.Message) }

# ---------- 写出 ----------
Add-Line ''
Add-Line ('（报告结束）')
try {
    [IO.File]::WriteAllText($outFile, ($lines -join "`r`n"), (New-Object Text.UTF8Encoding($true)))
    Write-Host ''
    Write-Host ('报告已保存：' + $outFile) -ForegroundColor Green
    Start-Process notepad.exe $outFile
} catch {
    Write-Host ('保存报告失败：' + $_.Exception.Message) -ForegroundColor Red
}
