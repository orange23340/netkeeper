<#
  Pbk.ps1 — 安装/卸载共用的小工具
  * rasphone.pbk（电话簿）读写：可能是 UTF-8 或 UTF-16，换行可能是 CRLF / CR / LF —— 全部兼容；
    写回时必须沿用原文件编码，否则会把整个电话簿写坏；改动前一律备份
  * Force-RemoveDir：删目录，常规删不掉（被我们自己的收紧权限锁成空 DACL）就先夺所有权再删
#>

# 删目录：先常规删；失败就 takeown + icacls 修权限再删。返回 $true 表示删干净了。
# 注意：空 DACL 的目录连 Test-Path 都会抛「拒绝访问」，所以"存在性判断"必须容错，
# 否则会把"没权限"误当"已删除"直接返回。
function Test-PathSafe([string]$p) {
    try { return (Test-Path -LiteralPath $p -ErrorAction Stop) } catch { return $true }   # 拿不到 = 当它还在
}
function Force-RemoveDir([string]$dir) {
    if (-not (Test-PathSafe $dir)) { return $true }
    try { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction Stop; return $true } catch { }
    # 逐层夺权：先本层和 logs 子目录（空 DACL 时连枚举都不让），再整棵树
    foreach ($target in @($dir, (Join-Path $dir 'logs'))) {
        if (-not (Test-PathSafe $target)) { continue }
        try { & takeown.exe /f $target /d y 2>&1 | Out-Null } catch { }
        try { & icacls.exe $target /reset /c /q 2>&1 | Out-Null } catch { }
        try { & icacls.exe $target /grant '*S-1-5-32-544:(OI)(CI)F' /c /q 2>&1 | Out-Null } catch { }
    }
    try { & takeown.exe /f $dir /r /d y 2>&1 | Out-Null } catch { }
    try { & icacls.exe $dir /reset /t /c /q 2>&1 | Out-Null } catch { }
    try { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction Stop; return $true } catch { }
    return (-not (Test-PathSafe $dir))
}

# 判断编码并读出正文（去掉 UTF-16 残留的 NUL）
function Get-PbkInfo([string]$Path) {
    if (-not (Test-Path $Path)) { return $null }
    $bytes = [IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -eq 0) { return [pscustomobject]@{ Path = $Path; IsUtf16 = $false; Text = '' } }
    $utf8 = [Text.Encoding]::UTF8.GetString($bytes)
    $utf16 = [Text.Encoding]::Unicode.GetString($bytes)
    $isUtf16 = $false
    if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) { $isUtf16 = $true }
    elseif (($utf16.Split('[')).Count -gt ($utf8.Split('[')).Count) { $isUtf16 = $true }
    $text = if ($isUtf16) { $utf16 } else { $utf8 }
    # 去掉 NUL 与 BOM 字符：GetString 会把 BOM 解成 U+FEFF，而 .NET 的 Trim() 不把它当空白，
    # 于是首行变成 "\uFEFF[连接名]"，正则永不命中（UTF-16 电话簿实测踩到）。
    $text = ($text -replace "`0", '') -replace ([string][char]0xFEFF), ''
    return [pscustomobject]@{ Path = $Path; IsUtf16 = $isUtf16; Text = $text }
}

function Read-Pbk([string]$Path) {
    $i = Get-PbkInfo $Path
    if ($i) { return $i.Text }
    return $null
}

function Split-PbkLines([string]$Text) { return ($Text -split "`r`n|`r|`n") }

# 返回所有 [连接名]
function Get-PbkEntries([string]$Path) {
    $text = Read-Pbk $Path
    if (-not $text) { return @() }
    $names = @()
    foreach ($line in (Split-PbkLines $text)) {
        $t = $line.Trim()
        if ($t -match '^\[(.+)\]$') { $names += $Matches[1] }
    }
    return $names
}

# 取一整段（[名字] 到下一个 [之前）
function Get-PbkSection([string]$Path, [string]$Name) {
    $text = Read-Pbk $Path
    if (-not $text) { return $null }
    $out = New-Object System.Collections.Generic.List[string]
    $in = $false
    foreach ($line in (Split-PbkLines $text)) {
        $t = $line.Trim()
        if ($t -match '^\[(.+)\]$') {
            if ($in) { break }
            if ($Matches[1] -eq $Name) { $in = $true; $out.Add($line); continue }
        }
        if ($in) { $out.Add($line) }
    }
    if ($out.Count -eq 0) { return $null }
    return ($out -join "`r`n")
}

function Save-Pbk([string]$Path, [string]$Text, [bool]$IsUtf16) {
    if ($IsUtf16) { $enc = New-Object Text.UnicodeEncoding($false, $true) }
    else { $enc = New-Object Text.UTF8Encoding($false) }
    [IO.File]::WriteAllText($Path, $Text, $enc)
}

# 把一段追加进电话簿（目标不存在则新建）
function Add-PbkSection([string]$Path, [string]$Section) {
    $dir = Split-Path $Path -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $info = Get-PbkInfo $Path
    $isUtf16 = $false
    $text = ''
    if ($info) {
        $isUtf16 = $info.IsUtf16
        $text = $info.Text
        Copy-Item $Path "$Path.bak" -Force
    }
    $new = $text.TrimEnd() + "`r`n`r`n" + $Section + "`r`n"
    try { Save-Pbk $Path $new $isUtf16 } catch { return $false }
    return $true
}

# 删掉一整段（保留其它内容与原编码）；找不到返回 $false
function Remove-PbkSection([string]$Path, [string]$Name) {
    $info = Get-PbkInfo $Path
    if (-not $info) { return $false }
    $lines = Split-PbkLines $info.Text
    $out = New-Object System.Collections.Generic.List[string]
    $found = $false
    $skip = $false
    foreach ($line in $lines) {
        if ($line.Trim() -match '^\[(.+)\]$') {
            $skip = ($Matches[1] -eq $Name)
            if ($skip) { $found = $true }
        }
        if (-not $skip) { $out.Add($line) }
    }
    if (-not $found) { return $false }
    Copy-Item $Path "$Path.bak-$(Get-Date -Format yyyyMMddHHmmss)" -Force
    Save-Pbk $Path (($out -join "`r`n").TrimEnd() + "`r`n") $info.IsUtf16
    return $true
}
