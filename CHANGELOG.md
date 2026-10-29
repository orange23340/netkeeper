# 更新记录

## v1.3 — 2026-10-29

砍掉拨号成功后一次没有必要的复检等待，并把每一步的耗时写进日志。

- 删除 `Invoke-Keeper` 里拨号成功后固定的 `Start-Sleep -Seconds 2` + 二次状态复查（`rasdial` 同步返回 0 即已连上）。这是开机路径上唯一「纯白等」的两秒
- 日志时间戳改毫秒（`yyyy-MM-dd HH:mm:ss.fff`）
- 日志追加两个参照量：`进程启动后 N 毫秒`（脚本自己的耗时）与 `开机后 N.N 秒`（`[Environment]::TickCount64`，免 CIM 调用）
- `rasdial.exe` 调用加 `Stopwatch`，耗时写进日志，便于区分「我的锅」和「运营商的锅」
- 计划任务命令行增加 `-NoLogo -NonInteractive`

## v1.2 — 2026-10-29

- 开机触发器延迟由 `PT10S` 改为 `PT0S`：系统启动即执行，不再空等 10 秒
- 懒编译 Win32 RAS API：默认走 `rasdial.exe`，只有 `config.json` 写 `"DialMode": "api"` 才 `Add-Type`（省掉每次开机的 C# 编译）
- 开机阶段轮询间隔 10 秒 → 3 秒，拨号失败退避改为 2 → 3 → 5 → 8 → 12 → 20 → 30 秒
- 修复：`if (-not (Ensure-RasApi()))` 这类带空括号的函数调用在 PowerShell 里是语法错误（4 处），会导致整个脚本不执行

## v1.1 — 2026-10-29

修复「开机后不拨号」——根因是判断依据错了。

- `Get-RasState` 改为以 `rasdial.exe` 输出为主（解析 `已连接 <名>` / `Connected to <名>`），RAS API 仅作回退。本机 API 的 `ActiveNames()` 不可靠
- 开机阶段（前 180 秒）只看「宽带连接在不在」，不再先等互联网通。旧逻辑等 60 秒 × 单次探测 8.4 秒，离线时实际近 4 分钟不拨号
- `Test-Internet` 加硬预算：最多 2 个 TCP（各 1.5 秒）+ 1 个 HTTP（2.5 秒）
- 僵尸连接判定加冷却：一小时内最多踢 3 次，避免把账号拨锁
- 单实例锁取不到时不再静默退出（`catch {}` 吞异常会让守护进程无声死亡），改为记 WARN 继续运行
- 入口写启动信标日志（pid / 模式 / 身份 / 目录），用于区分「任务没跑」和「跑了但失败」
- 诊断脚本 `诊断.ps1` → `Diag.ps1`：中文文件名在 `.bat` 里会被 cmd 按 GBK 解码成乱码

## v1.0 — 2026-10-29

首个可安装版本。

- 计划任务（SYSTEM / 最高权限 / 开机触发 / 失败每分钟重试 / 不自动停止）驱动守护进程
- PPPoE 双路径拨号：Win32 `RasDialW` 优先，遇 `87 / 50 / 621` 自动降级 `rasdial.exe`
- 密码 AES-256-CBC 加密存储，密钥单独成文件
- 安装目录与配置的 ACL 收紧到 SYSTEM + Administrators，关闭继承
- 断线重拨、僵尸连接检测、按天日志、单实例锁
- 六个双击入口：安装 / 卸载 / 立即重拨 / 查看日志 / 自检 / 诊断
- 安装时把连接复制进「所有用户」电话簿（SYSTEM 看不到当前用户的连接）

### 安全修正

- ACL 用 5 参构造带 `ContainerInherit, ObjectInherit`，否则程序自建的 `logs\` 子目录继承到空 DACL，连 SYSTEM 都进不去
- 安装位置从脚本所在目录改为 `C:\ProgramData\NetKeeper\`：脚本若在普通用户可写目录，配合 SYSTEM 计划任务就是一条本地提权路径
- 所有 `.ps1` 强制 UTF-8 带 BOM：PowerShell 5.1 会把无 BOM 的 UTF-8 当 GBK 读，中文注释乱码导致 here-string 边界失效，整份脚本报上百个语法错误
