<#
.SYNOPSIS
    ZELUX 镜像烧写到 SD 卡（Windows，PowerShell 5.1+）

.DESCRIPTION
    两种做法，按机器上装了什么自动选：
      1) Etcher / Rufus 已安装 → 帮你校验 sha256，再把这些工具的窗口拉起来，全程点三次鼠标；
      2) 都没有 → -Method raw 直接写物理磁盘（自带进度 + 回读校验），不需要装任何东西。

    全程**不需要你格式化任何分区**。Windows 弹"需要格式化才能使用"时点取消——
    那是因为它看不懂 Linux 的分区，格式化会把刚烧好的系统毁掉。

.PARAMETER Image
    镜像文件。balenaEtcher 支持 .img.xz；-Method raw 只支持 .img（先解压）。

.PARAMETER Drive
    目标盘：物理磁盘号（2）或 "\\.\PHYSICALDRIVE2"。不给就列出来让你挑。

.PARAMETER Method
    auto（默认）/ etcher / rufus / raw

.PARAMETER Yes
    跳过输入盘号确认（脚本里用，人别用）

.PARAMETER NoVerify
    跳过回读校验（不推荐）

.EXAMPLE
    .\flash-windows.ps1 -Image .\zelux-duck-1.0.0-zero3w.img.xz

.EXAMPLE
    .\flash-windows.ps1 -Image D:\img\zelux.img -Drive 2 -Method raw
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)][string]$Image,
    [Parameter(Position = 1)][string]$Drive = "",
    [ValidateSet("auto", "etcher", "rufus", "raw")][string]$Method = "auto",
    [switch]$Yes,
    [switch]$NoVerify,
    [switch]$ListOnly
)

$ErrorActionPreference = "Stop"
$BlockSize = 4MB

function Write-Step($msg) { Write-Host ""; Write-Host "== $msg" -ForegroundColor Cyan }
function Write-Ok($msg)   { Write-Host "   $msg" -ForegroundColor Green }
function Write-Warn2($msg){ Write-Host "   ! $msg" -ForegroundColor Yellow }
function Fail($msg) {
    Write-Host ""
    Write-Host "xx $msg" -ForegroundColor Red
    exit 1
}

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# ---------------------------------------------------------------- 0. 前置
if ($env:OS -ne "Windows_NT") { Fail "这个脚本只能在 Windows 上跑。" }
if (-not (Test-Path -LiteralPath $Image)) { Fail "找不到镜像：$Image" }
$Image = (Resolve-Path -LiteralPath $Image).Path
$ImageItem = Get-Item -LiteralPath $Image
Write-Host "ZELUX 烧写工具" -ForegroundColor Magenta
Write-Host "镜像：$($ImageItem.FullName)"
Write-Host ("大小：{0:N0} MB" -f ($ImageItem.Length / 1MB))

# ---------------------------------------------------------------- 1. sha256
Write-Step "1/5 校验镜像 sha256"
$shaFile = "$Image.sha256"
if (Test-Path -LiteralPath $shaFile) {
    $want = ((Get-Content -LiteralPath $shaFile -TotalCount 1) -split '\s+')[0].Trim().ToLower()
    $got = (Get-FileHash -LiteralPath $Image -Algorithm SHA256).Hash.ToLower()
    if ($want -ne $got) {
        Fail "sha256 不一致：`n     期望 $want`n     实际 $got`n   镜像可能下载不完整，重新下载（别烧坏包）。"
    }
    Write-Ok "sha256 OK（$($got.Substring(0,16))…）"
} else {
    Write-Warn2 "没有 $([IO.Path]::GetFileName($shaFile))，跳过校验。发布页一般有配套 .sha256，能下就下。"
}

# ---------------------------------------------------------------- 2. 选盘
Write-Step "2/5 选择目标 SD 卡"
$disks = @(Get-Disk | Where-Object {
        $_.BusType -in @("USB", "SD", "MMC") -and -not $_.IsBoot -and -not $_.IsSystem
    } | Sort-Object Number)

if ($disks.Count -eq 0) {
    Fail "没找到可移动磁盘。插好 SD 卡（≥16 GB、A2）、换一个 USB 口、确认读卡器是好的，然后再跑一次。"
}

$disks | Select-Object Number, FriendlyName,
    @{N = "容量GB"; E = { [math]::Round($_.Size / 1GB, 1) } }, BusType, IsReadOnly |
    Format-Table -AutoSize | Out-String | Write-Host

if ($ListOnly) { exit 0 }

$diskNumber = $null
if ($Drive -ne "") {
    if ($Drive -match '(\d+)$') { $diskNumber = [int]$Matches[1] }
    else { Fail "-Drive 只认物理磁盘号（比如 2 或 \\.\PHYSICALDRIVE2）" }
} else {
    $answer = Read-Host "输入要写入的磁盘号（输入 q 取消）"
    if ($answer -eq "q") { Fail "已取消" }
    if ($answer -notmatch '^\d+$') { Fail "要填数字磁盘号，收到：$answer" }
    $diskNumber = [int]$answer
}

$disk = Get-Disk -Number $diskNumber -ErrorAction SilentlyContinue
if ($null -eq $disk) { Fail "没有 $diskNumber 号磁盘" }
if ($disk.IsBoot -or $disk.IsSystem) { Fail "$diskNumber 号是系统盘，绝对不能写。拔一张卡来。" }
if ($disk.IsReadOnly) { Fail "$diskNumber 号是只读的（写保护开关打开了？）" }

# 容量：.img 能直接比大小；.xz 解压后多大算不出来，交给 Etcher 判断
$needBytes = 0
if ($Image -notmatch '\.xz$') { $needBytes = $ImageItem.Length }
if ($needBytes -gt 0 -and $disk.Size -lt $needBytes) {
    Fail ("{0} 号盘只有 {1:N1} GB，镜像要 {2:N1} GB。换 ≥16 GB 的卡。" -f $diskNumber, ($disk.Size/1GB), ($needBytes/1GB))
}
Write-Ok ("目标：{0} 号  {1}  {2:N1} GB" -f $disk.Number, $disk.FriendlyName, ($disk.Size/1GB))

# ---------------------------------------------------------------- 3. 选方法
Write-Step "3/5 选择烧写方式"
$etcher = @(
    "$env:ProgramFiles\balenaEtcher\balenaEtcher.exe",
    "${env:ProgramFiles(x86)}\balenaEtcher\balenaEtcher.exe",
    "$env:LOCALAPPDATA\Programs\balenaEtcher\balenaEtcher.exe"
) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
$rufus = @(
    "$env:ProgramFiles\Rufus\rufus.exe",
    "${env:ProgramFiles(x86)}\Rufus\rufus.exe"
) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1

if ($Method -eq "auto") {
    if ($etcher) { $Method = "etcher" }
    elseif ($rufus) { $Method = "rufus" }
    else { $Method = "raw" }
}
Write-Ok "方式：$Method"

# ---------------------------------------------------------------- 4. 烧写
if ($Method -eq "etcher" -or $Method -eq "rufus") {
    Write-Step "4/5 交给 $Method 写盘"
    if ($Method -eq "etcher") {
        Write-Host @"
   接下来只需要在 Etcher 里点三次：
     1. Flash from file  → 选  $Image
     2. Select target    → 选  $diskNumber 号盘（$($disk.FriendlyName)）
     3. Flash!           → 等它写完并自动校验

   Etcher 会自己做"写后校验"，比 dd 更稳；.img.xz 可以直接选，不用解压。
"@
        if (-not (Test-Admin)) { Write-Warn2 "Etcher 会自己申请管理员权限，UAC 弹窗请点「是」" }
        Start-Process -FilePath $etcher
    } else {
        Write-Host @"
   接下来在 Rufus 里：
     1. 设备   → $diskNumber 号盘（$($disk.FriendlyName)）
     2. 选择   → $Image
     3. 开始   → 选"以 DD 镜像模式写入"（不要选 ISO 模式！Rufus 默认可能建议 ISO）
     4. 弹窗警告会被清空 → 确认
"@
        Start-Process -FilePath $rufus
    }
    Write-Host ""
    Write-Host "   写完想核对一遍？拔卡重插后运行：" -ForegroundColor DarkGray
    Write-Host "     .\flash-windows.ps1 -Image $Image -Drive $diskNumber -Method raw -NoVerify" -ForegroundColor DarkGray
    Write-Host "   （只做校验不写盘的模式没有实现：校验要读整盘 3 GB，Etcher 已经做过一次了）" -ForegroundColor DarkGray
    exit 0
}

# ---- raw：真的自己写 ----
if ($Image -match '\.xz$') {
    Write-Host "-Method raw 只支持 .img（Windows 没有内置 xz 解压）。" -ForegroundColor Red
    Write-Host "两条路选一条："
    Write-Host "  a) 装 balenaEtcher，用 .img.xz 直接烧（推荐）："
    Write-Host "     .\flash-windows.ps1 -Image $Image -Method etcher"
    Write-Host "  b) 先解压成 .img：装 7-Zip 右键『提取』，或在 WSL 里 xz -dk $([IO.Path]::GetFileName($Image))"
    exit 1
}
if (-not (Test-Admin)) {
    Fail "raw 写盘需要管理员权限：右键 PowerShell → 以管理员身份运行，再执行一次。"
}

if (-not $Yes) {
    Write-Host ""
    Write-Host ("!! {0} 号盘（{1}）上的所有数据会被清空，不可恢复。" -f $diskNumber, $disk.FriendlyName) -ForegroundColor Red
    $confirm = Read-Host "确认请输入磁盘号 $diskNumber"
    if ($confirm -ne "$diskNumber") { Fail "已取消" }
}

Write-Step "4/5 写入物理磁盘 $diskNumber"
$devicePath = "\\.\PHYSICALDRIVE$diskNumber"

# 先把磁盘置为 offline：Windows 不再挂载它的分区，我们才能拿到独占写句柄
$wasOffline = $disk.IsOffline
if (-not $wasOffline) {
    Write-Ok "把磁盘临时置为 offline（Windows 就不会再挂着它的分区）"
    Set-Disk -Number $diskNumber -IsOffline $true
}

$src = $null; $dst = $null
try {
    $src = [IO.File]::OpenRead($Image)
    $dst = New-Object IO.FileStream($devicePath, [IO.FileMode]::Open, [IO.FileAccess]::Write, [IO.FileShare]::None, $BlockSize, $false)
    $buf = New-Object byte[] $BlockSize
    $total = $src.Length
    $done = 0L
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while (($read = $src.Read($buf, 0, $buf.Length)) -gt 0) {
        # 最后一块要补到 512 字节对齐，否则物理磁盘会拒绝这次写
        if ($read % 512 -ne 0) {
            $pad = 512 - ($read % 512)
            [Array]::Clear($buf, $read, $pad)
            $read += $pad
        }
        $dst.Write($buf, 0, $read)
        $done += $read
        if ($total -gt 0) {
            $pct = [int](100 * $done / $total)
        } else { $pct = 0 }
        $mb = [math]::Round($done / 1MB, 1)
        Write-Progress -Activity "写入 SD 卡" -Status "$mb MB / $([math]::Round($total/1MB,0)) MB" -PercentComplete $pct
    }
    $dst.Flush($true)
    $sw.Stop()
    Write-Progress -Activity "写入 SD 卡" -Completed
    Write-Ok ("写入完成，用时 {0:N1} 秒" -f $sw.Elapsed.TotalSeconds)
}
catch {
    Fail "写入失败：$($_.Exception.Message)`n   换张卡 / 换个 USB 口 / 关掉所有资源管理器窗口再试。"
}
finally {
    if ($dst) { $dst.Dispose() }
    if ($src) { $src.Dispose() }
    if (-not $wasOffline) {
        # 恢复上线：不然拔插之后 Windows 也看不见这张卡
        try { Set-Disk -Number $diskNumber -IsOffline $false } catch { Write-Warn2 "恢复磁盘上线失败，重新插拔一次即可" }
    }
}

# ---------------------------------------------------------------- 5. 回读校验
if (-not $NoVerify) {
    Write-Step "5/5 回读校验"
    Write-Ok "把刚写进去的字节读出来再算一遍 sha256（约 1–2 分钟）"
    $expected = (Get-FileHash -LiteralPath $Image -Algorithm SHA256).Hash.ToLower()
    $sha = [Security.Cryptography.SHA256]::Create()
    $stream = $null
    try {
        $stream = New-Object IO.FileStream($devicePath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite, $BlockSize, $false)
        $remain = $ImageItem.Length
        $buf = New-Object byte[] $BlockSize
        while ($remain -gt 0) {
            $want = [int][Math]::Min([int64]$BlockSize, $remain)
            $read = $stream.Read($buf, 0, $want)
            if ($read -le 0) { break }
            $sha.TransformBlock($buf, 0, $read, $null, 0) | Out-Null
            $remain -= $read
            Write-Progress -Activity "回读校验" -Status ("剩余 {0:N0} MB" -f ($remain / 1MB)) `
                -PercentComplete ([int](100 * (1 - $remain / $ImageItem.Length)))
        }
        $sha.TransformFinalBlock((New-Object byte[] 0), 0, 0) | Out-Null
        Write-Progress -Activity "回读校验" -Completed
    }
    catch {
        Write-Warn2 "回读失败：$($_.Exception.Message)（卡可能已被 Windows 重新挂载，拔插后手动核对）"
        $sha = $null
    }
    finally {
        if ($stream) { $stream.Dispose() }
    }

    if ($null -ne $sha) {
        $actual = ([BitConverter]::ToString($sha.Hash) -replace '-', '').ToLower()
        if ($actual -eq $expected) {
            Write-Ok "校验通过（$($actual.Substring(0,16))…）"
        } else {
            Fail "校验失败！`n     期望 $expected`n     实际 $actual`n   卡质量不行 / 读卡器不稳。换一张正品 A2 卡重烧。"
        }
    }
} else {
    Write-Warn2 "已跳过回读校验（-NoVerify）"
}

# ---------------------------------------------------------------- 收尾
Write-Host ""
Write-Host "================= 烧写完成 =================" -ForegroundColor Green
Write-Host "1. 卡插进 Radxa Zero 3W，接 5V/3A 电源（Type-C）"
Write-Host "2. 首次开机 2–3 分钟（扩容 + 装依赖），LED 常亮/慢闪都正常"
Write-Host "3. 手机连 WiFi：ZELUX-Duck / zeluxduck"
Write-Host "4. 浏览器打开：http://192.168.4.1:8000"
Write-Host "5. 默认口令 zelux（登录后在「设置 → 密码」里改）"
Write-Host ""
Write-Host "注意：Windows 可能弹「需要格式化 E: 才能使用」——点取消。" -ForegroundColor Yellow
Write-Host "      它只是看不懂 Linux 分区，格式化就把刚烧的系统删了。" -ForegroundColor Yellow
Write-Host "============================================" -ForegroundColor Green
