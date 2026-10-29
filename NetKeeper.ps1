<#
  NetKeeper 1.1 — PPPoE 宽带自动拨号守护
  - 计划任务以 SYSTEM 身份开机启动（不需要登录桌面）
  - 拨号默认走 Win32 RAS API（密码不进命令行）；该 API 在本机报 87 时自动改用 rasdial.exe
  - 通网检测：TCP 探测 + HTTP 兜底；断线自动重拨
  - 连上但没网（僵尸连接）→ 挂断重拨，且带冷却，避免无限互踢
  - 单实例用独占锁文件（跨账户可靠，进程崩溃会自动释放）
  - 密码为 AES 加密文件，密钥只允许 SYSTEM/Administrators 读取
  - 日志 logs\keeper-yyyyMMdd.log，保留 7 天
#>
[CmdletBinding()]
param(
    [string]$ConfigPath,   # 默认 = 脚本同目录 config.json（在函数体外算，-File 调用时 $PSScriptRoot 才可靠）
    [switch]$Once,         # 手动测试：检查一轮就退出
    [switch]$Selftest      # 自检：验证 RAS 互操作与错误码，不读凭据、不改系统
)

$ErrorActionPreference = 'Stop'
$Script:StartStamp = Get-Date
$Script:Root = $PSScriptRoot
if (-not $Script:Root) { $Script:Root = Split-Path -Parent $MyInvocation.MyCommand.Definition }
if (-not $ConfigPath) { $ConfigPath = Join-Path $Script:Root 'config.json' }
$Script:LogDir = Join-Path $Script:Root 'logs'
$Script:LogReady = $false
$Script:Cfg    = $null
# 默认走 rasdial.exe：省掉编译 C# 的几百毫秒，开机更快；要 API 就在 config 里写 "DialMode": "api"
$Script:DialMode = 'exe'

# ---------- 日志 ----------
function Write-Log {
    param([string]$Msg, [string]$Level = 'INFO')
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'), $Level, $Msg
    try {
        if (-not $Script:LogReady) {
            if (-not (Test-Path -LiteralPath $Script:LogDir -ErrorAction Stop)) {
                New-Item -ItemType Directory -Path $Script:LogDir -Force -ErrorAction Stop | Out-Null
            }
            $Script:LogReady = $true
        }
        $file = Join-Path $Script:LogDir ('keeper-{0}.log' -f (Get-Date -Format 'yyyyMMdd'))
        Add-Content -LiteralPath $file -Value $line -Encoding UTF8 -ErrorAction Stop
    } catch { }   # 日志写不进去也不能影响拨号
    try {
        if ($Level -eq 'ERROR') { Write-Host $line -ForegroundColor Red }
        elseif ($Level -eq 'WARN') { Write-Host $line -ForegroundColor Yellow }
        else { Write-Host $line }
    } catch { }
}
function Clear-OldLogs {
    param([int]$Days = 7)
    if (-not (Test-Path $Script:LogDir)) { return }
    Get-ChildItem $Script:LogDir -Filter 'keeper-*.log' -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-$Days) } |
        Remove-Item -Force -ErrorAction SilentlyContinue
}

# ---------- 配置与凭据 ----------
function Load-Config {
    if (-not (Test-Path $ConfigPath)) { throw "找不到配置文件：$ConfigPath" }
    $c = Get-Content -Path $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not $c.ConnectionName) { throw '配置里缺少 ConnectionName（宽带连接名）' }
    if (-not $c.User) { throw '配置里缺少 User（宽带账号）' }
    # 缺省值兜底，避免配置写漏了导致「永远判定断网 → 无限重拨」
    if (-not $c.TcpTargets) { $c | Add-Member -NotePropertyName TcpTargets -NotePropertyValue @('223.5.5.5:53', '119.29.29.29:53') -Force }
    if ($null -eq $c.HttpTargets) { $c | Add-Member -NotePropertyName HttpTargets -NotePropertyValue @('http://www.msftconnecttest.com/connecttest.txt') -Force }
    if (-not $c.CheckIntervalSec) { $c | Add-Member -NotePropertyName CheckIntervalSec -NotePropertyValue 10 -Force }
    if (-not $c.ZombieLimit) { $c | Add-Member -NotePropertyName ZombieLimit -NotePropertyValue 2 -Force }
    $Script:Cfg = $c
    return $c
}
function Get-PlainPassword {
    $keyFile = Join-Path $Script:Root $Script:Cfg.KeyFile
    if (-not (Test-Path $keyFile)) { throw "找不到密钥文件：$keyFile" }
    $key = [System.IO.File]::ReadAllBytes($keyFile)
    $sec = $Script:Cfg.Password | ConvertTo-SecureString -Key $key
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

# ---------- RAS（Win32 API，密码不进命令行） ----------
# 编译 C# 要 200~600 毫秒，开机抢那几百毫秒不值得：默认走 rasdial.exe，
# 只有配置里明确写 DialMode=api 才编译（懒加载）。
function Ensure-RasApi {
    if ('NetKeeperRas' -as [type]) { return $true }
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Collections.Generic;

public static class NetKeeperRas
{
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct RASCONN
    {
        public int dwSize;
        public IntPtr hrasconn;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 257)] public string szEntryName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 129)] public string szDeviceType;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 129)] public string szDeviceName;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct RASDIALPARAMS
    {
        public int dwSize;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 257)] public string szEntryName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 129)] public string szPhoneNumber;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 129)] public string szCallbackNumber;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 257)] public string szUserName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 257)] public string szPassword;
        // szDomain 是 DNLEN+1 = 16；写 17 会让结构体尺寸不对，RasDial 直接返回 87（参数错误）
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 16)]  public string szDomain;
        public int dwSubEntry;
        public IntPtr dwCallbackId;
        public int dwIfIndex;
    }

    [DllImport("rasapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern int RasEnumConnections([In, Out] RASCONN[] lprasconn, ref int lpcb, ref int lpcConnections);

    [DllImport("rasapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern int RasDial(IntPtr dialExtensions, string phoneBookPath,
        ref RASDIALPARAMS dialParams, int flags, IntPtr callback, IntPtr callbackId);

    [DllImport("rasapi32.dll", SetLastError = true)]
    static extern int RasHangUp(IntPtr hrasconn);

    static RASCONN[] Enumerate(out int count)
    {
        int size = Marshal.SizeOf(typeof(RASCONN));
        int bufSize = size * 16;
        count = 0;
        RASCONN[] buf = new RASCONN[16];
        for (int i = 0; i < buf.Length; i++) buf[i].dwSize = size;
        int rc = RasEnumConnections(buf, ref bufSize, ref count);
        if (rc != 0) { count = 0; return new RASCONN[0]; }
        return buf;
    }

    public static string[] ActiveNames()
    {
        int count;
        RASCONN[] buf = Enumerate(out count);
        List<string> names = new List<string>();
        for (int i = 0; i < count; i++) names.Add(buf[i].szEntryName);
        return names.ToArray();
    }

    public static bool IsActive(string entry)
    {
        int count;
        RASCONN[] buf = Enumerate(out count);
        for (int i = 0; i < count; i++) if (buf[i].szEntryName == entry) return true;
        return false;
    }

    // 同步拨号：callback 为 NULL 时 RasDial 阻塞到连上或失败，返回 0 表示成功
    public static int Dial(string phoneBook, string entry, string user, string pass)
    {
        RASDIALPARAMS p = new RASDIALPARAMS();
        p.dwSize = Marshal.SizeOf(typeof(RASDIALPARAMS));
        p.szEntryName = entry;
        p.szPhoneNumber = "";
        p.szCallbackNumber = "";
        p.szUserName = user;
        p.szPassword = pass;
        p.szDomain = "";
        p.dwSubEntry = 0;   // 单链路连接必须为 0；写 1 会指向不存在的子项
        p.dwCallbackId = IntPtr.Zero;
        p.dwIfIndex = 0;
        return RasDial(IntPtr.Zero, phoneBook, ref p, 0, IntPtr.Zero, IntPtr.Zero);
    }

    public static int HangUp(string entry)
    {
        int count;
        RASCONN[] buf = Enumerate(out count);
        int rc = 0;
        for (int i = 0; i < count; i++)
            if (buf[i].szEntryName == entry) rc = RasHangUp(buf[i].hrasconn);
        return rc;
    }

    public static string DefaultPhoneBook()
    {
        string all = System.IO.Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData),
            @"Microsoft\Network\Connections\Pbk\rasphone.pbk");
        if (System.IO.File.Exists(all)) return all;
        return null;
    }
}
'@
    return $true
}
# 电话簿路径用纯 PowerShell 算，避免为了它去编译 C#
function Get-DefaultPhoneBook {
    $all = Join-Path $env:ProgramData 'Microsoft\Network\Connections\Pbk\rasphone.pbk'
    if (Test-Path $all) { return $all }
    $up = Join-Path $env:APPDATA 'Microsoft\Network\Connections\Pbk\rasphone.pbk'
    if (Test-Path $up) { return $up }
    return $null
}
$Script:PhoneBook = Get-DefaultPhoneBook

function Get-RasState {
    param([string]$Name)
    # 先问 rasdial（它按系统语言输出「已连接 / Connected to」，是最可靠的一份事实），
    # 再退到 RAS API。API 在本机有 87 的毛病，不能单靠它。
    try {
        $out = & "$env:WINDIR\System32\rasdial.exe" 2>&1
        $txt = (($out | ForEach-Object { $_.ToString() }) -join "`n")
        if ($txt -match ('(?m)^\s*(?:已连接|Connected to)\s+' + [regex]::Escape($Name) + '\s*$')) { return 'connected' }
        if ($txt.Trim().Length -gt 0) { return 'idle' }
    } catch { }
    # 只有 rasdial 完全没输出时才动用 API（编译一次要几百毫秒，别在开机路径上花）
    if (-not (Ensure-RasApi)) { return 'unknown' }
    try {
        if ([NetKeeperRas]::IsActive($Name)) { return 'connected' }
        return 'idle'
    } catch { return 'unknown' }
}

# ---------- 通网检测 ----------
function Test-TcpPort {
    param([string]$HostName, [int]$Port, [int]$TimeoutMs = 1800)
    $c = New-Object System.Net.Sockets.TcpClient
    try {
        $ar = $c.BeginConnect($HostName, $Port, $null, $null)
        if (-not $ar.AsyncWaitHandle.WaitOne($TimeoutMs, $false)) { return $false }
        $c.EndConnect($ar)
        return $true
    } catch { return $false } finally { try { $c.Close() } catch { } }
}
function Test-Http {
    param([string]$Url, [int]$TimeoutMs = 3000)
    try {
        $req = [System.Net.HttpWebRequest]::Create($Url)
        $req.Timeout = $TimeoutMs
        $req.ReadWriteTimeout = $TimeoutMs
        $req.Proxy = $null
        $req.UserAgent = 'NetKeeper/1.1'
        $req.KeepAlive = $false
        $resp = $req.GetResponse()
        $code = [int]$resp.StatusCode
        $resp.Close()
        return ($code -ge 200 -and $code -lt 400)
    } catch { return $false }
}
function Test-Internet {
    # 探测要有硬预算：离线时每个目标都要等满超时，不封顶会让一轮循环拖到 8 秒以上，
    # 开机阶段尤其致命。这里最多测 2 个 TCP + 1 个 HTTP（约 3~5 秒）。
    $tcp = @($Script:Cfg.TcpTargets | Where-Object { $_ } | Select-Object -First 2)
    foreach ($t in $tcp) {
        $parts = $t.Split(':')
        if ($parts.Count -eq 2) {
            if (Test-TcpPort -HostName $parts[0] -Port ([int]$parts[1]) -TimeoutMs 1500) { return $true }
        }
    }
    $u = @($Script:Cfg.HttpTargets | Where-Object { $_ } | Select-Object -First 1)
    foreach ($x in $u) {
        if (Test-Http -Url $x -TimeoutMs 2500) { return $true }
    }
    return $false
}

# ---------- 拨号 ----------
function Format-RasError {
    param([int]$Code)
    switch ($Code) {
        0   { return '成功' }
        601 { return '端口已打开（601）' }
        623 { return '找不到该连接（623）——连接名写错，或它只存在于别的用户下' }
        651 { return '网卡/光猫无响应（651）' }
        678 { return '对方无应答（678）——线路或光猫问题' }
        691 { return '账号或密码错误（691）' }
        692 { return '硬件故障（692）' }
        720 { return 'PPP 协商失败（720）——通常是网卡驱动或线路问题' }
        756 { return '同名连接已在拨号中（756）' }
        781 { return '证书/PPP 参数错误（781）' }
        868 { return 'DNS 无应答（868）' }
        default { return ('未知错误（{0}）' -f $Code) }
    }
}
function Invoke-DialExe {
    # 兜底：rasdial.exe。缺点：密码会出现在子进程命令行里（仅管理员/审计日志可见）
    param([string]$Name, [string]$User, [string]$Pass)
    $exe = Join-Path $env:WINDIR 'System32\rasdial.exe'
    if (-not (Test-Path $exe)) { Write-Log '找不到 rasdial.exe' 'ERROR'; return -1 }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $out = & $exe $Name $User $Pass 2>&1
    $rc = $LASTEXITCODE
    $sw.Stop()
    if ($out) { Write-Log ("rasdial 输出（耗时 {0:N0} 毫秒）：{1}" -f $sw.Elapsed.TotalMilliseconds, (($out | Out-String).Trim())) }
    return $rc
}
function Invoke-Dial {
    param([string]$Name, [string]$User, [string]$Pass)
    Write-Log ("拨号中：{0}（账号 {1}）" -f $Name, $User)

    if ($Script:DialMode -eq 'api' -and (Ensure-RasApi)) {
        $code = -1
        try { $code = [NetKeeperRas]::Dial($Script:PhoneBook, $Name, $User, $Pass) }
        catch { Write-Log ("调用 RAS API 异常：{0}" -f $_.Exception.Message) 'WARN' }
        if ($code -eq 0) { Write-Log '拨号成功（RAS API）'; return $true }
        # 87/50/621 属于「这套 API 在当前系统上用不了」，换 rasdial.exe 兜底
        if ($code -in 87, 50, 621, -1) {
            Write-Log ("RAS API 返回 {0}，改用 rasdial.exe 兜底（本次运行后续都走兜底）" -f $code) 'WARN'
            $Script:DialMode = 'exe'
        } else {
            Write-Log ("拨号失败：{0}" -f (Format-RasError $code)) 'WARN'
            return $false
        }
    }

    $rc = Invoke-DialExe -Name $Name -User $User -Pass $Pass
    if ($rc -eq 0) { Write-Log '拨号成功（rasdial）'; return $true }
    Write-Log ("拨号失败：{0}" -f (Format-RasError $rc)) 'WARN'
    return $false
}
function Invoke-Hangup {
    param([string]$Name)
    # 先用 rasdial 挂断（不依赖 API 编译），失败再用 API
    try {
        $exe = Join-Path $env:WINDIR 'System32\rasdial.exe'
        $null = & $exe $Name /disconnect 2>&1
        if ($LASTEXITCODE -eq 0) { Write-Log "已挂断：$Name"; return }
    } catch { }
    try {
        if (Ensure-RasApi) { [void][NetKeeperRas]::HangUp($Name); Write-Log "已挂断：$Name" }
    } catch { Write-Log ("挂断失败：{0}" -f $_.Exception.Message) 'WARN' }
}

# ---------- 主循环 ----------
function Invoke-Keeper {
    $cfg = Load-Config
    $name = $cfg.ConnectionName
    $user = $cfg.User
    $pass = Get-PlainPassword
    $interval = 10; if ($cfg.CheckIntervalSec) { $interval = [int]$cfg.CheckIntervalSec }
    $zombieLimit = 2; if ($cfg.ZombieLimit) { $zombieLimit = [int]$cfg.ZombieLimit }
    if ($cfg.DialMode -eq 'api') { $Script:DialMode = 'api' } else { $Script:DialMode = 'exe' }
    if (-not $Script:PhoneBook) { $Script:DialMode = 'exe' }

    Write-Log ('NetKeeper 启动｜连接：{0}｜账号：{1}｜间隔：{2}s｜进程启动后 {3:N0} 毫秒｜开机后 {4:N1} 秒' -f $name, $user, $interval, ((Get-Date) - $Script:StartStamp).TotalMilliseconds, ([Environment]::TickCount64 / 1000))

    # 开机阶段：只看「宽带连接在不在」，不在就立刻拨，不再空等探测。
    # 旧版开局先空等最多 60 秒探测互联网，而离线时每轮探测要 8 秒，
    # 等于开局干等 4 分钟都不拨；这期间你若手动拨上了，它只写一句
    # 「网络已经是通的」就永远不拨 —— 这正是「开机不拨号」的直接原因。
    $t0 = Get-Date
    $bootPhase = $true
    $failStreak = 0
    $zombie = 0
    $zombieStamps = New-Object System.Collections.ArrayList
    $cycle = 0
    $backoff = 2

    while ($true) {
        $cycle++
        try {
            $elapsed = ((Get-Date) - $t0).TotalSeconds
            if ($bootPhase -and $elapsed -gt 180) {
                $bootPhase = $false
                Write-Log ('开机阶段结束（已运行 {0:N0} 秒），转入常规守候' -f $elapsed)
            }
            # 开机阶段用 3 秒的快节奏，尽快把连接拉起来
            $step = if ($bootPhase) { 3 } else { $interval }

            $state = Get-RasState -Name $name

            # ---------- 情况 1：宽带连接不在 ----------
            if ($state -ne 'connected') {
                $shouldDial = $bootPhase
                if (-not $shouldDial) {
                    # 开机阶段之后，只有真没网才硬拨，免得和别的可用通路抢
                    $shouldDial = -not (Test-Internet)
                }
                if (-not $shouldDial) {
                    if ($cycle % 360 -eq 0) { Clear-OldLogs 7 }
                    Start-Sleep -Seconds $step
                    continue
                }

                Write-Log ('宽带连接未建立（状态：{0}），开始拨号｜进程启动后 {1:N0} 毫秒｜开机后 {2:N1} 秒' -f $state, ((Get-Date) - $Script:StartStamp).TotalMilliseconds, ([Environment]::TickCount64 / 1000))
                # rasdial 是同步的：它返回 0 就等于已经连上，不必再 sleep 2 秒去复检（那 2 秒是白等）
                if (Invoke-Dial -Name $name -User $user -Pass $pass) {
                    Write-Log ('拨号成功，宽带连接已建立｜进程启动后 {0:N0} 毫秒｜开机后 {1:N1} 秒' -f ((Get-Date) - $Script:StartStamp).TotalMilliseconds, ([Environment]::TickCount64 / 1000))
                    $failStreak = 0; $backoff = 2; $zombie = 0
                } else {
                    $failStreak++
                    Write-Log ('拨号失败（连续第 {0} 次），{1} 秒后重试' -f $failStreak, $backoff) 'WARN'
                    Start-Sleep -Seconds $backoff
                    $backoff = [Math]::Min(30, [int]($backoff * 1.6))
                    continue
                }
                Start-Sleep -Seconds $step
                continue
            }

            # ---------- 情况 2：连接在，但可能没网 ----------
            if (Test-Internet) {
                if ($failStreak -gt 0) { Write-Log ('网络正常（此前连续失败 {0} 次）' -f $failStreak) }
                $failStreak = 0; $zombie = 0; $backoff = 2
                if ($cycle % 360 -eq 0) { Clear-OldLogs 7 }
                Start-Sleep -Seconds $step
                continue
            }

            $failStreak++
            $zombie++
            Write-Log ('连接在但没网（第 {0} 次探测失败，僵尸计数 {1}/{2}）' -f $failStreak, $zombie, $zombieLimit) 'WARN'

            if ($zombie -lt $zombieLimit) {
                Start-Sleep -Seconds ([Math]::Max(4, $step))
                continue
            }

            # 冷却：10 分钟内最多踢 3 次，避免和运营商之间无限互踢
            $now = Get-Date
            $recent = @($zombieStamps | Where-Object { ($now - $_).TotalSeconds -le 600 })
            $zombieStamps = New-Object System.Collections.ArrayList
            foreach ($s in $recent) { [void]$zombieStamps.Add($s) }
            if ($zombieStamps.Count -ge 3) {
                Write-Log '10 分钟内已挂断重拨 3 次，暂停 5 分钟后再说' 'WARN'
                Start-Sleep -Seconds 300
                $zombieStamps.Clear()
                $zombie = 0
                continue
            }
            [void]$zombieStamps.Add($now)
            Write-Log '连接在但没网（僵尸连接），挂断重拨' 'WARN'
            Invoke-Hangup -Name $name
            Start-Sleep -Seconds 2
            [void](Invoke-Dial -Name $name -User $user -Pass $pass)
            $zombie = 0
            Start-Sleep -Seconds 4
        } catch {
            Write-Log ("主循环异常：{0}" -f $_.Exception.Message) 'ERROR'
            Start-Sleep -Seconds 15
        }
    }
}

# ---------- 入口 ----------
# 单实例用「独占锁文件」，不用 Global\ 互斥量：
# 互斥量由 SYSTEM 建、管理员再去建时，会因对象 DACL 不含 WRITE_OWNER 抛
# UnauthorizedAccessException（实测“对路径 Global\NetKeeper_Dialer 的访问被拒绝”）。
# 锁文件走的是目录 ACL（管理员天然有权限），进程崩了也会被系统自动释放。
#
# 返回值必须区分三种情况：拿到 / 被别的进程占着 / 压根建不出来。
# 早先的写法把后两种都当成「已有实例在跑 → 退出」，结果是：只要锁文件建不出来
# （目录权限不对、磁盘只读……），守护进程就静默退出，开机自然不拨号。
function Enter-InstanceLock([int]$TimeoutSec = 0) {
    $p = Join-Path $Script:LogDir 'netkeeper.lock'
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ($true) {
        try {
            $h = [IO.File]::Open($p, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
            return @{ Result = 'ok'; Handle = $h }
        } catch [System.IO.IOException] {
            # 0x80070020 = 共享冲突（文件被占用）→ 才算是「另一个实例在跑」
            if ($_.Exception.HResult -ne [int]-2147024864) {
                return @{ Result = 'error'; Message = $_.Exception.Message }
            }
        } catch {
            return @{ Result = 'error'; Message = $_.Exception.Message }
        }
        if ((Get-Date) -ge $deadline) { return @{ Result = 'held' } }
        Start-Sleep -Milliseconds 300
    }
}

$mode = if ($Selftest) { 'selftest' } elseif ($Once) { 'once' } else { 'keeper' }
# 开机后第一行日志：用来区分「任务没跑」和「跑了但失败」
Write-Log ('===== 启动 pid={0} 模式={1} 身份={2} 目录={3} =====' -f $PID, $mode,
    $(try { [Security.Principal.WindowsIdentity]::GetCurrent().Name } catch { '?' }), $Script:Root)

$created = $true
$lock = $null
$lockNote = ''
if (-not $Selftest) {
    $r = Enter-InstanceLock -TimeoutSec $(if ($Once) { 3 } else { 0 })
    if ($r.Result -eq 'ok') {
        $lock = $r.Handle
    } elseif ($r.Result -eq 'held') {
        $created = $false
        # 手动拨号是用户主动发起的，抢不到锁也照做，只提醒一句
        if ($Once) { $lockNote = '守护进程正在运行，手动拨号仍然继续' }
    } else {
        # 建不出锁文件：不能因此就不拨号，降级运行
        $lockNote = ('单实例锁不可用（{0}），本次跳过锁保护继续运行' -f $r.Message)
    }
}
if (-not $created -and -not $Once) {
    Write-Log '已有一个 NetKeeper 实例在运行，本次退出' 'WARN'
    exit 0
}
if ($lockNote) { Write-Log $lockNote 'WARN' }
try {
    if ($Selftest) {
        Write-Host '--- NetKeeper 自检 ---' -ForegroundColor Cyan
        Write-Host ("PowerShell 版本 : {0}" -f $PSVersionTable.PSVersion)
        Write-Host ("电话簿          : {0}" -f $(if ($Script:PhoneBook) { $Script:PhoneBook } else { '（没找到 rasphone.pbk）' }))
        $names = @()
        try {
            if (Ensure-RasApi) { $names = [NetKeeperRas]::ActiveNames() }
        } catch { Write-Host ("RAS 枚举异常：{0}" -f $_.Exception.Message) -ForegroundColor Red }
        Write-Host ("当前活动的 RAS 连接：{0}" -f $(if ($names.Count) { $names -join '、' } else { '（无）' }))
        Write-Host '拨号错误码映射抽查（用不存在的连接名，不会真的连出去）：'
        $code = -1
        try {
            if (Ensure-RasApi) { $code = [NetKeeperRas]::Dial($Script:PhoneBook, 'Z_TEST_NOT_EXIST', 'nobody', 'nothing') }
        } catch {
            Write-Host ("Dial 抛异常：{0}" -f $_.Exception.Message) -ForegroundColor Red
        }
        Write-Host ("  返回码 {0} → {1}" -f $code, (Format-RasError $code))
        $exePath = Join-Path $env:WINDIR 'System32\rasdial.exe'
        Write-Host ("rasdial.exe     : {0}" -f $(if (Test-Path $exePath) { $exePath } else { '（缺失）' }))
        if (Test-Path $exePath) {
            $null = & $exePath 'Z_TEST_NOT_EXIST' 'nobody' 'nothing' 2>&1
            $rc = $LASTEXITCODE
            Write-Host ("  rasdial 兜底返回 {0} → {1}" -f $rc, (Format-RasError $rc))
        }
        $mode = if ($code -in 87, 50, 621, -1) { 'rasdial.exe 兜底' } else { 'Win32 RAS API' }
        Write-Host ("本机将用      : {0}" -f $mode) -ForegroundColor Yellow
        $probe = Test-TcpPort -HostName '223.5.5.5' -Port 53 -TimeoutMs 2000
        Write-Host ("TCP 探测 223.5.5.5:53 → {0}" -f $(if ($probe) { '通' } else { '不通' }))
        # 连接状态识别（这是「开机要不要拨号」的判据，必须可靠）
        $realName = '宽带连接'
        try {
            if (Test-Path (Join-Path $Script:Root 'config.json')) { $realName = (Load-Config).ConnectionName }
        } catch { }
        try {
            Write-Host ("状态识别 真连接 : {0} → {1}" -f $realName, (Get-RasState -Name $realName))
            Write-Host ("状态识别 假连接 : Z_NOPE → {0}" -f (Get-RasState -Name 'Z_NOPE'))
        } catch { Write-Host ("状态识别异常：{0}" -f $_.Exception.Message) -ForegroundColor Red }
        # 探测预算（离线时一轮探测多久，决定掉线后多快能发现）
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $null = Test-TcpPort -HostName '10.255.255.1' -Port 53 -TimeoutMs 1500
        $null = Test-TcpPort -HostName '10.255.255.2' -Port 53 -TimeoutMs 1500
        $sw.Stop()
        Write-Host ("离线探测耗时    : {0:N1} 秒（2 个黑洞地址）" -f $sw.Elapsed.TotalSeconds)
        Write-Host '自检结束（没有读密码、没有改系统）' -ForegroundColor Green
    }
    elseif ($Once) {
        $c = Load-Config
        $online = Test-Internet
        $state = Get-RasState -Name $c.ConnectionName
        Write-Log ("网络：{0}｜RAS 连接：{1}｜电话簿：{2}" -f $(if ($online) { '通' } else { '断' }), $state, $Script:PhoneBook)
        if (-not $online) {
            $ok = Invoke-Dial -Name $c.ConnectionName -User $c.User -Pass (Get-PlainPassword)
            Start-Sleep -Seconds 3
            Write-Log ("结果：拨号{0}｜网络{1}" -f $(if ($ok) { '成功' } else { '失败' }), $(if (Test-Internet) { '通' } else { '断' }))
        }
    } else {
        Invoke-Keeper
    }
} catch {
    Write-Log ("致命错误：{0}" -f $_.Exception.Message) 'ERROR'
    Write-Log ($_.ScriptStackTrace) 'ERROR'
    exit 1
} finally {
    try { if ($lock) { $lock.Dispose() } } catch { }
}
