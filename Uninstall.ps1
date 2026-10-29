<#
  NetKeeper 卸载器
  - 结束守护进程、注销开机任务
  - 可选：删除「所有用户」里复制的那份连接定义
  - 可选：删除安装目录（含加密密码、密钥与日志）
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Continue'
$Script:Root = $PSScriptRoot
if (-not $Script:Root) { $Script:Root = Split-Path -Parent $MyInvocation.MyCommand.Definition }
$Script:InstallDir = Join-Path $env:ProgramData 'NetKeeper'
$taskName = 'NetKeeper-宽带自动拨号'

# 电话簿读写用共用模块
. (Join-Path $Script:Root 'Pbk.ps1')


function Say($m, $c = 'Gray') { Write-Host $m -ForegroundColor $c }
function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

Say '' ; Say 'NetKeeper 卸载' Cyan ; Say ''

if (-not (Test-Admin)) {
    Say '  需要管理员权限，正在请求提权…' Yellow
    try {
        Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-NoExit', '-File', ('"{0}"' -f $PSCommandPath))
    } catch { Say '  提权被取消。' Red; Read-Host '按回车关闭' | Out-Null }
    exit
}

# 1. 停进程（只结束命令行里带 NetKeeper.ps1 的 powershell，别误伤其它窗口）
Say '结束守护进程…'
$killed = 0
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -and $_.CommandLine -like '*NetKeeper.ps1*' } |
    ForEach-Object {
        try { Stop-Process -Id $_.ProcessId -Force; $killed++; Say ("  已结束 PID {0}" -f $_.ProcessId) } catch { }
    }
if ($killed -eq 0) { Say '  （没有在运行的守护进程）' }

# 2. 注销任务
Say '注销开机任务…'
$t = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if ($t) { Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue; Say '  完成' }
else { Say '  （本来就没有这个任务）' }

# 3. 可选：删除「所有用户」里的连接定义
$cfgPath = Join-Path $Script:InstallDir 'config.json'
$connName = $null
if (Test-Path $cfgPath) {
    try { $connName = (Get-Content $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json).ConnectionName } catch { }
}
if ($connName) {
    $ans = Read-Host ("是否从「所有用户」删除连接定义「{0}」？(y/N)" -f $connName)
    if ($ans -eq 'y') {
        $allPbk = Join-Path $env:ProgramData 'Microsoft\Network\Connections\Pbk\rasphone.pbk'
        if (Test-Path $allPbk) {
            if (Remove-PbkSection $allPbk $connName) { Say '  已删除该连接定义' }
            else { Say '  （电话簿里没找到这段，可能已经删过了）' Yellow }
        }
    }
}

# 4. 可选：删掉安装目录
$ans = Read-Host '是否删除安装目录（含加密密码、密钥与日志）？(y/N)'
if ($ans -eq 'y') {
    if (Force-RemoveDir $Script:InstallDir) { Say '  已删除' Green }
    else { Say '  删除失败，可能有进程占用；重启后再试，或手动 takeown/icacls 后删。' Yellow }
}

Say ''
Say '卸载完成。' Green
Read-Host '按回车关闭' | Out-Null
