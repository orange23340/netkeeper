# 开发用：检查脚本里有没有「调用了但没定义」的命令名（上次 Add-SectionToPbk 就是这类错）
$ErrorActionPreference = 'Stop'
$files = @('NetKeeper.ps1', 'Install.ps1', 'Uninstall.ps1', 'Redial.ps1', 'Pbk.ps1') |
    ForEach-Object { Join-Path $PSScriptRoot $_ }
$bad = 0
$defined = @{}
foreach ($f in $files) {
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($f, [ref]$tokens, [ref]$errors)
    $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) |
        ForEach-Object { $defined[$_.Name.ToLowerInvariant()] = $true }
}
foreach ($f in $files) {
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($f, [ref]$tokens, [ref]$errors)
    if ($errors.Count) { Write-Host ("[语法] {0}：{1}" -f (Split-Path $f -Leaf), ($errors[0].Message)) -ForegroundColor Red; $bad++; continue }
    $missing = @{}
    foreach ($c in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)) {
        $name = $c.GetCommandName()
        if (-not $name) { continue }
        if ($name -match '[\\/.]') { continue }
        if ($defined.ContainsKey($name.ToLowerInvariant())) { continue }
        if (Get-Command -Name $name -ErrorAction SilentlyContinue) { continue }
        $missing[$name] = $true
    }
    if ($missing.Count -eq 0) { Write-Host ("[OK] {0}" -f (Split-Path $f -Leaf)) -ForegroundColor Green }
    else { $bad++; Write-Host ("[未定义] {0} → {1}" -f (Split-Path $f -Leaf), (($missing.Keys | Sort-Object) -join ', ')) -ForegroundColor Red }
}
if ($bad) { exit 1 }
Write-Host '全部脚本的命令调用都能解析' -ForegroundColor Green
