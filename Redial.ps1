# 立即拨一次（手动排查用）
$ErrorActionPreference = 'Continue'
$Script:Root = $PSScriptRoot
if (-not $Script:Root) { $Script:Root = Split-Path -Parent $MyInvocation.MyCommand.Definition }
$InstallDir = Join-Path $env:ProgramData 'NetKeeper'

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}
if (-not (Test-Admin)) {
    Write-Host '需要管理员权限，正在请求提权…' -ForegroundColor Yellow
    try {
        Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-NoExit', '-File', ('"{0}"' -f $PSCommandPath))
    } catch {
        Write-Host '提权被取消。' -ForegroundColor Red
        Read-Host '按回车关闭' | Out-Null
    }
    exit
}

$installed = Join-Path $InstallDir 'NetKeeper.ps1'
$local = Join-Path $Script:Root 'NetKeeper.ps1'
if (Test-Path $installed) { $target = $installed }
elseif (Test-Path $local) { $target = $local; Write-Host '提示：还没安装，用当前目录的副本测试。' -ForegroundColor Yellow }
else {
    Write-Host '没找到 NetKeeper.ps1，请先运行安装.bat。' -ForegroundColor Red
    Read-Host '按回车关闭' | Out-Null; exit 1
}

# 读连接名（config.json 只有管理员能读，所以必须已提权到这）
$conn = '宽带连接'
$cfgFile = Join-Path $InstallDir 'config.json'
if (Test-Path $cfgFile) {
    try {
        $cfg = [IO.File]::ReadAllText($cfgFile, [Text.Encoding]::UTF8) | ConvertFrom-Json
        if ($cfg.Connection) { $conn = [string]$cfg.Connection }
    } catch { Write-Host '（读配置失败，按默认连接名处理）' -ForegroundColor DarkYellow }
}

Write-Host ''
Write-Host "这会先断开「$conn」，几秒后重新拨号 —— 期间断网。" -ForegroundColor Yellow
$ans = Read-Host '继续？(Y/n)'
if ($ans -and $ans.Trim().ToLower() -ne 'y') { exit }

Write-Host ''
Write-Host '断开当前连接…' -ForegroundColor Cyan
$out = & "$env:WINDIR\System32\rasdial.exe" $conn /disconnect 2>&1
Write-Host ('  ' + ($out -join ' ')) -ForegroundColor Gray
Start-Sleep -Seconds 2

Write-Host '重新检查并拨号…' -ForegroundColor Cyan
& $target -Once
Write-Host ''
Read-Host '按回车关闭' | Out-Null
