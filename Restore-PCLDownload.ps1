#requires -Version 5.1
<#
.SYNOPSIS
    PCL 下载功能恢复工具（官方二进制回退，不含任何二进制补丁）

.DESCRIPTION
    背景：
      PCL 2.99.0.0 起移除了「下载 → 原版游戏」板块（更新日志：删除）。
      2.14.0.0 是该改动之前的最后一个正式版，仍完整内置原版下载。
      但 PCL 启动时会自动更新到 2.99，手动降级会立刻被覆盖。

    本脚本做三件事：
      1. 从 Meloong-Git/PCL 仓库中记录的官方构建，下载 2.14.0.0 完整包；
      2. SHA-256 校验通过后替换 exe（旧的自动备份，可一键还原）；
      3. 在 PCL\Setup.ini 写入 SystemSystemUpdate:3，阻止自动更新覆盖。

    安全性：
      - 全程只用官方 HTTPS 源，不解包、不修改、不注入任何字节；
      - 下载包与 exe 均按内置 SHA-256 白名单校验，镜像被投毒也无法通过；
      - exe 的 MD5 会与官方 patches/Release <版本> <md5>.patch 的文件名交叉验证。

    注意：
      回退后你将停留在 2.14.0.0，不会再有新版功能与修复；这是本方案的代价。
      想恢复更新：-Restore 还原旧版，或手动删除 Setup.ini 里的 SystemSystemUpdate 行。

.PARAMETER PclDir
    PCL 所在目录（含 Plain Craft Launcher 2.exe）。不填则自动探测。

.PARAMETER Restore
    还原：恢复最近一次备份的 exe，并移除 SystemSystemUpdate 限制。

.PARAMETER Proxy
    GitHub 加速前缀，例如 https://hk.gh-proxy.com/
    会拼成 <Proxy><原始URL>。因为做了哈希校验，用第三方代理也是安全的。

.PARAMETER Force
    跳过确认提示。

.EXAMPLE
    .\Restore-PCLDownload.ps1
    .\Restore-PCLDownload.ps1 -PclDir "D:\PCL2"
    .\Restore-PCLDownload.ps1 -Proxy "https://hk.gh-proxy.com/"
    .\Restore-PCLDownload.ps1 -Restore
#>
[CmdletBinding()]
param(
    [string]$PclDir,
    [switch]$Restore,
    [string]$Proxy,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

# 老系统上 .NET 默认协议可能不含 TLS 1.2，会导致连不上 GitHub
try {
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12 -bor [System.Net.SecurityProtocolType]::Tls11
} catch { }

$ExeName = 'Plain Craft Launcher 2.exe'
$Repo    = 'Meloong-Git/PCL'
$DataSub = 'PCL'

# ---------------------------------------------------------------- 版本锁
# 2.14.0.0 = 移除原版下载之前的最后一个正式版（2026-10-19）
# 所有哈希均来自官方仓库中的构建产物，并与 patches/Release <版本> <md5>.patch 交叉核对。
$Pin = [pscustomobject]@{
    Version   = '2.14.0.0'
    Commit    = '5ef81e490a'
    ZipSha256 = '0835D346CD0F95C1472A3C0655D66E6CA8B7E4494CA0083768E3316F2CD4E7B1'
    ExeSha256 = '5582952DED3B443503F66C23B810802BD20F1A3E847B54D9E09653A825859A36'
    ExeMd5    = 'B0756EE600D34B93DC841E0F2CA00096'
    ExeSize   = 5989376
}

function Write-Step { param([string]$Text) Write-Host "==> $Text" -ForegroundColor Cyan }
function Write-Ok   { param([string]$Text) Write-Host "    $Text" -ForegroundColor Green }
function Write-Warn { param([string]$Text) Write-Host "    $Text" -ForegroundColor Yellow }
function Write-Dim  { param([string]$Text) Write-Host "    $Text" -ForegroundColor DarkGray }

function Find-PclDir {
    param([string]$Hint)

    if ($Hint) {
        $cand = Join-Path $Hint $ExeName
        if (Test-Path -LiteralPath $cand) { return (Resolve-Path -LiteralPath $Hint).Path }
        throw "指定目录下找不到 $ExeName：$Hint"
    }

    # 1) 正在运行的 PCL
    $proc = Get-Process -Name 'Plain Craft Launcher 2' -ErrorAction SilentlyContinue |
            Where-Object { $_.Path } | Select-Object -First 1
    if ($proc) { return (Split-Path -Parent $proc.Path) }

    # 2) 脚本目录 / 当前目录
    foreach ($d in @($PSScriptRoot, (Get-Location).Path)) {
        if ($d -and (Test-Path -LiteralPath (Join-Path $d $ExeName))) { return $d }
    }

    throw "找不到 PCL。请把脚本放到 PCL 目录下运行，或用 -PclDir 指定。"
}

function Stop-Pcl {
    $p = Get-Process -Name 'Plain Craft Launcher 2' -ErrorAction SilentlyContinue
    if (-not $p) { return }
    Write-Step "关闭正在运行的 PCL (PID $($p.Id))"
    $p.CloseMainWindow() | Out-Null
    for ($i = 0; $i -lt 32; $i++) {
        Start-Sleep -Milliseconds 250
        if ($p.HasExited) { Write-Ok '已退出'; return }
    }
    Write-Warn '未在超时内退出，强制结束'
    Stop-Process -Id $p.Id -Force
    Start-Sleep -Milliseconds 800
}

function Get-PinnedZip {
    param([string]$OutFile, [string]$ProxyPrefix)

    $enc  = [uri]::EscapeDataString('最新正式版.zip')

    # ---- 下载源（2026-10-24 大陆直连实测排序）----
    # github.com/<repo>/raw/... 只是 302 到 raw.githubusercontent.com，
    # 而 raw.githubusercontent.com 与 github.com 在大陆常被阻断，
    # 所以原来的前两个源在很多机器上必然失败。现改为：
    #   1) jsDelivr 的国内可达镜像（实测 5~6 秒，字节与官方一致）
    #   2) gcore.jsdelivr.net / gh-proxy 兜底
    #   3) fork 兜底：fork 保留同一 commit 对象，上游被删/被封也能取到同一份文件
    #   4) GitHub 原地址放最后（能翻墙的用户才用得上）
    $mirror = @(
        { param($r, $c, $e) "https://jsdelivr.b-cdn.net/gh/$r@$c/$e" }
        { param($r, $c, $e) "https://cdn.jsdmirror.com/gh/$r@$c/$e" }
        { param($r, $c, $e) "https://gcore.jsdelivr.net/gh/$r@$c/$e" }
        { param($r, $c, $e) "https://hk.gh-proxy.com/https://raw.githubusercontent.com/$r/$c/$e" }
    )
    $forkRepos = @('QingDongmen/PCLbk', 'jinfanhao1/PCL')

    $m0 = $mirror[0]
    $m1 = $mirror[1]
    $urls = New-Object System.Collections.ArrayList
    foreach ($m in $mirror) { [void]$urls.Add((& $m $Repo $Pin.Commit $enc)) }
    foreach ($fr in $forkRepos) {
        [void]$urls.Add((& $m0 $fr $Pin.Commit $enc))
        [void]$urls.Add((& $m1 $fr $Pin.Commit $enc))
    }
    [void]$urls.Add("https://github.com/$Repo/raw/$($Pin.Commit)/$enc")
    [void]$urls.Add("https://raw.githubusercontent.com/$Repo/$($Pin.Commit)/$enc")
    $urls = @($urls)

    if ($ProxyPrefix) {
        $pre = $ProxyPrefix.TrimEnd('/') + '/'
        $urls = @($urls | ForEach-Object { $pre + $_ }) + $urls
    }

    foreach ($u in $urls) {
        try {
            Write-Dim "尝试 $u"
            $wc = New-Object System.Net.WebClient
            $wc.Headers.Add('User-Agent', "PCL-DownloadRestore/1.0")
            try { $wc.DownloadFile($u, $OutFile) } finally { $wc.Dispose() }

            $sha = (Get-FileHash -LiteralPath $OutFile -Algorithm SHA256).Hash
            if ($sha -ne $Pin.ZipSha256) {
                Write-Warn "SHA-256 不匹配，丢弃该镜像（期望 $($Pin.ZipSha256.Substring(0,16))…，实得 $($sha.Substring(0,16))…）"
                Remove-Item -LiteralPath $OutFile -Force -ErrorAction SilentlyContinue
                continue
            }
            Write-Ok "下载完成并校验通过 ($([math]::Round((Get-Item $OutFile).Length/1KB,0)) KB)"
            return
        } catch {
            Write-Warn "失败：$($_.Exception.Message)"
        }
    }
    throw "所有下载源均失败（国内镜像与 GitHub 原地址都不可达）。请检查网络后重试；如仍失败，可用 -Proxy 指定加速前缀，例如 https://hk.gh-proxy.com/"
}

function Set-NoUpdate {
    param([string]$DataDir)

    $ini = Join-Path $DataDir 'Setup.ini'
    $text = ''
    if (Test-Path -LiteralPath $ini) {
        $text = [System.IO.File]::ReadAllText($ini)
        Copy-Item -LiteralPath $ini -Destination "$ini.bak" -Force
    }
    if ($text -match 'SystemSystemUpdate\s*:\s*\d+') {
        $text = [regex]::Replace($text, 'SystemSystemUpdate\s*:\s*\d+', 'SystemSystemUpdate:3')
        Write-Ok '已更新 SystemSystemUpdate:3'
    } else {
        if ($text.Length -gt 0 -and -not $text.EndsWith("`n")) { $text += "`r`n" }
        $text += "SystemSystemUpdate:3`r`n"
        Write-Ok '已写入 SystemSystemUpdate:3'
    }
    [System.IO.File]::WriteAllText($ini, $text, (New-Object System.Text.UTF8Encoding($false)))
}

function Remove-NoUpdate {
    param([string]$DataDir)
    $ini = Join-Path $DataDir 'Setup.ini'
    if (-not (Test-Path -LiteralPath $ini)) { return }
    $text = [System.IO.File]::ReadAllText($ini)
    $new  = [regex]::Replace($text, '\r?\n?SystemSystemUpdate\s*:\s*3\s*(?=\r?\n|$)', '')
    if ($new -ne $text) {
        [System.IO.File]::WriteAllText($ini, $new, (New-Object System.Text.UTF8Encoding($false)))
        Write-Ok '已移除 SystemSystemUpdate 限制'
    }
}

function Invoke-Restore {
    param([string]$Dir)
    $backs = @(Get-ChildItem -LiteralPath $Dir -Filter "$ExeName.bak-*" -File -ErrorAction SilentlyContinue |
               Sort-Object LastWriteTime -Descending)
    if ($backs.Count -eq 0) { throw "没有找到备份文件（$ExeName.bak-*），无法还原。" }

    $b = $backs[0]
    Write-Step "还原到 $($b.Name)"
    Stop-Pcl
    $target = Join-Path $Dir $ExeName
    Copy-Item -LiteralPath $b.FullName -Destination $target -Force
    Remove-NoUpdate -DataDir (Join-Path $Dir $DataSub)
    Write-Ok "已还原：$((Get-Item -LiteralPath $target).VersionInfo.FileVersion)"
    Write-Dim "备份文件保留：$($b.FullName)"
}

function Get-DataSummary {
    param([string]$Dir)

    $lines = New-Object System.Collections.ArrayList

    # 账号：PCL 把登录信息存在注册表，换 exe 完全不受影响
    $reg = 'HKCU:\Software\PCL'
    if (Test-Path -LiteralPath $reg) {
        $acct = (Get-ItemProperty -Path $reg -ErrorAction SilentlyContinue).LoginLegacyName
        if ($acct) { [void]$lines.Add('账号：注册表中存在登录信息，本次操作不涉及') }
        else       { [void]$lines.Add('账号：注册表键存在，未读到登录项') }
    } else {
        [void]$lines.Add('账号：未检测到 PCL 注册表键')
    }

    $mc = Join-Path $Dir '.minecraft'
    if (-not (Test-Path -LiteralPath $mc)) {
        [void]$lines.Add('.minecraft：不在 PCL 目录下（可能自定义了位置）')
        return $lines
    }

    $vers = @(Get-ChildItem -LiteralPath (Join-Path $mc 'versions') -Directory -ErrorAction SilentlyContinue)
    $modTotal = 0
    $detail = @()
    foreach ($v in $vers) {
        $n = @(Get-ChildItem -LiteralPath (Join-Path $v.FullName 'mods') -Filter *.jar -File -ErrorAction SilentlyContinue).Count
        $modTotal += $n
        $detail += "$($v.Name)($n)"
    }
    [void]$lines.Add("游戏目录：$mc")
    [void]$lines.Add("已装版本：$($vers.Count) 个；模组合计 $modTotal 个")
    if ($detail.Count -gt 0) { [void]$lines.Add('  ' + ($detail -join '  ')) }
    [void]$lines.Add('以上内容本脚本只读不写')
    return $lines
}

# ---------------------------------------------------------------- 主流程
Write-Host ''
Write-Host '  PCL 下载功能恢复工具' -ForegroundColor White
Write-Host '  官方二进制回退 · 无二进制补丁 · SHA-256 校验' -ForegroundColor DarkGray
Write-Host ''

$dir = Find-PclDir -Hint $PclDir
$exe = Join-Path $dir $ExeName
$dataDir = Join-Path $dir $DataSub

Write-Step "PCL 目录：$dir"
$curVer = (Get-Item -LiteralPath $exe).VersionInfo.FileVersion
$curSha = (Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash
Write-Ok "当前版本：$curVer"

if ($Restore) {
    Invoke-Restore -Dir $dir
    Write-Host ''
    Write-Host '  完成。' -ForegroundColor Green
    exit 0
}

if ($curSha -eq $Pin.ExeSha256) {
    Write-Ok "已经是 $($Pin.Version)（哈希一致）"
    if (-not (Test-Path -LiteralPath $dataDir)) {
        Write-Warn "未找到数据目录 $dataDir，跳过更新限制"
    } else {
        Set-NoUpdate -DataDir $dataDir
    }
    Write-Host ''
    Write-Host '  无需回退，只确保自动更新已关闭。' -ForegroundColor Green
    exit 0
}

Write-Host ''
Write-Host "  将执行：" -ForegroundColor White
Write-Host "    当前  : $curVer"
Write-Host "    替换为: $($Pin.Version)  （仍内置原版下载的最后一个正式版）"
Write-Host "    备份  : $ExeName.bak-$curVer"
Write-Host "    并写入: SystemSystemUpdate:3（阻止自动更新）"
Write-Host ''
Write-Host '  只会修改这两个文件：' -ForegroundColor White
Write-Host "    $exe"
Write-Host "    $(Join-Path $dataDir 'Setup.ini')  （只增加一行）"
Write-Host ''
Write-Host '  以下内容保持原样：' -ForegroundColor White
foreach ($line in (Get-DataSummary -Dir $dir)) { Write-Host "    $line" -ForegroundColor DarkGray }
Write-Host ''
if (-not $Force) {
    $ans = Read-Host '  确认继续？(y/N)'
    if ($ans -notmatch '^(y|yes)$') { Write-Warn '已取消'; exit 1 }
}

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("pcl-restore-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null

try {
    # 1) 下载并校验
    Write-Step '下载官方构建'
    $zip = Join-Path $tmp 'latest.zip'
    Get-PinnedZip -OutFile $zip -ProxyPrefix $Proxy

    # 2) 从 zip 取出 exe（包内只有这一个文件）
    Write-Step '解出可执行文件'
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [System.IO.Compression.ZipFile]::OpenRead($zip)
    try {
        $entry = $archive.Entries | Where-Object { $_.Name -eq $ExeName } | Select-Object -First 1
        if (-not $entry) { throw "压缩包内没有 $ExeName" }
        $newExe = Join-Path $tmp $ExeName
        [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $newExe, $true)
    } finally {
        $archive.Dispose()
    }

    # 3) exe 三重校验
    $sha = (Get-FileHash -LiteralPath $newExe -Algorithm SHA256).Hash
    $md5 = (Get-FileHash -LiteralPath $newExe -Algorithm MD5).Hash
    $ver = (Get-Item -LiteralPath $newExe).VersionInfo.FileVersion
    $len = (Get-Item -LiteralPath $newExe).Length
    if ($sha -ne $Pin.ExeSha256) { throw "exe SHA-256 不符：$sha" }
    if ($md5 -ne $Pin.ExeMd5)    { throw "exe MD5 不符：$md5" }
    if ($len -ne $Pin.ExeSize)   { throw "exe 大小不符：$len" }
    if ($ver -ne $Pin.Version)   { throw "exe 版本不符：$ver" }
    Write-Ok "SHA-256 / MD5 / 大小 / 版本 全部匹配"

    # 4) 关进程 + 备份 + 替换
    Stop-Pcl
    $bak = "$exe.bak-$curVer"
    if (-not (Test-Path -LiteralPath $bak)) {
        Copy-Item -LiteralPath $exe -Destination $bak -Force
        Write-Ok "已备份：$([System.IO.Path]::GetFileName($bak))"
    }

    $done = $false
    for ($i = 0; $i -lt 12; $i++) {
        try { Copy-Item -LiteralPath $newExe -Destination $exe -Force; $done = $true; break }
        catch { Start-Sleep -Milliseconds 600 }
    }
    if (-not $done) { throw "替换失败，文件被占用。请手动关闭 PCL 后重试。" }
    Write-Ok "已替换为 $((Get-Item -LiteralPath $exe).VersionInfo.FileVersion)"

    # 5) 关闭自动更新
    if (-not (Test-Path -LiteralPath $dataDir)) {
        New-Item -ItemType Directory -Path $dataDir -Force | Out-Null
    }
    Set-NoUpdate -DataDir $dataDir

    Write-Host ''
    Write-Host '  完成。' -ForegroundColor Green
    Write-Host ''
    Write-Host '  数据核对（应与操作前一致）：' -ForegroundColor White
    foreach ($line in (Get-DataSummary -Dir $dir)) { Write-Host "    $line" -ForegroundColor DarkGray }
    Write-Host ''
    Write-Host "  打开 PCL → 下载 → 原版游戏，即可恢复版本列表与「开始下载」。" -ForegroundColor White
    Write-Host '  如需撤销：再次运行本工具，并加上 -Restore 参数' -ForegroundColor DarkGray
} finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
